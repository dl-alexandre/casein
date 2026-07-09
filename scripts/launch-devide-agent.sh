#!/usr/bin/env bash
#
# Launch an external agent with DevIDE Terminal + Preview MCP injected at runtime.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"
# shellcheck source=lib/agent-worktree.sh
source "${ROOT}/scripts/lib/agent-worktree.sh"
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"
# shellcheck source=lib/agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=lib/sidechat.sh
source "${ROOT}/scripts/lib/sidechat.sh"
# shellcheck source=lib/agent-skills.sh
source "${ROOT}/scripts/lib/agent-skills.sh"

usage() {
  cat <<'EOF'
Usage: launch-devide-agent.sh <runtime> [runtime args...]

Creates a dedicated git worktree when launched from the primary checkout (see
docs/development-workflow.md). Set DEVIDE_AGENT_SKIP_WORKTREE=1 to opt out.

Runtimes:
  grok      injects per-workspace MCP via project .mcp.json
  codex     injects per-workspace MCP via launch-time config overrides
  claude    injects per-workspace MCP via --mcp-config (keeps ~/.claude credentials)
            pass --sidechat <target> for a read-only advisor (target: %pane,
            session:pane, or agent)
  opencode  injects per-workspace MCP via project .opencode/opencode.json
            (paired primary checkout OR agent worktree) and stages host
            skills (delegate-to-grok, preview-ui-walk, workspace-agent-pair)
            into ~/.config/opencode/skills + project .opencode/skills
  agent     MCP env + real agent binary
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

RUNTIME="$1"
shift

agent_env_resolve
agent_worktree_ensure "$RUNTIME" "${DEVIDE_AGENT_TASK:-adhoc}"

warn_degraded_step() {
  local label="$1"
  local detail="${2:-}"

  echo "warn: ${label} failed — agent continues in degraded mode" >&2
  if [[ -n "$detail" ]]; then
    printf '%s\n' "${detail:0:1200}" >&2
  fi
}

run_materialize_export() {
  local out err exports detail
  out="$(mktemp)"
  err="$(mktemp)"

  if bash "${ROOT}/scripts/materialize-agent-mcp.sh" --export >"$out" 2>"$err"; then
    exports="$(<"$out")"
    if [[ -n "$exports" ]] && ! eval "$exports"; then
      warn_degraded_step "materialize-agent-mcp.sh --export eval" \
        "materializer emitted shell exports that could not be evaluated; stdout redacted because it may contain tokens"
    fi
  else
    detail="$(<"$err")"
    if [[ -s "$out" ]]; then
      detail="${detail}"$'\n'"materialize-agent-mcp.sh wrote $(wc -c <"$out") bytes to stdout; redacted because it may contain tokens"
    fi
    warn_degraded_step "materialize-agent-mcp.sh --export" "$detail"
  fi

  rm -f "$out" "$err"
}

run_repair_tmux_env() {
  local out err detail
  local args=()

  if [[ -n "${DEVIDE_TMUX_SESSION:-}" ]]; then
    args+=("${DEVIDE_TMUX_SESSION}")
  elif [[ -z "${TMUX:-}" ]]; then
    return 0
  fi

  out="$(mktemp)"
  err="$(mktemp)"

  if ! bash "${ROOT}/scripts/lib/repair-tmux-env.sh" "${args[@]}" >"$out" 2>"$err"; then
    detail="$(<"$err")"
    if [[ -s "$out" ]]; then
      detail="${detail}"$'\n'"$(<"$out")"
    fi
    warn_degraded_step "repair-tmux-env.sh" "$detail"
  fi

  rm -f "$out" "$err"
}

run_materialize_export
agent_env_export_runtime_paths
run_repair_tmux_env
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py"

# Never redirect agent homes to MCP staging. Preserve only explicit DevIDE
# owner auth profiles under ~/.devide/agent-auth: signed-in profiles, plus
# empty profiles of registered owners (those fail closed — the provider CLI
# runs its own sign-in inside the profile instead of using the host global
# login). Anything else falls back to the host global provider auth.
enforce_owner_auth() {
  local runtime="$1"
  local key current dir
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  current="${!key:-}"

  if [[ -n "$current" ]] && ! agent_auth_profile_under_root "$current"; then
    unset "$key"
    current=""
  fi

  # The workspace-derived profile is canonical when this launch belongs to a
  # workspace; agent_auth_profile_active_dir already applies the registered
  # owner fail-closed rule.
  if [[ -n "${DEVIDE_WORKSPACE_NAME:-}" ]]; then
    if dir="$(agent_auth_profile_active_dir "$DEVIDE_WORKSPACE_NAME" "$runtime")"; then
      export "$key=$dir"
      if ! agent_auth_profile_signed_in "$dir" "$runtime"; then
        echo "devide: owner auth is fail-closed for this workspace; ${runtime} uses ${dir} — complete the sign-in it prompts for (the host global login is not shared)" >&2
      fi
      return 0
    fi
  fi

  if [[ -n "$current" ]] && ! agent_auth_profile_signed_in "$current" "$runtime"; then
    unset "$key"
  fi
}

unset GROK_HOME OPENCODE_CONFIG
enforce_owner_auth codex
enforce_owner_auth claude

sync_project_mcp_config() {
  local runtime="$1"
  local checkout="${DEVIDE_CHECKOUT:-}"
  local staging="${DEVIDE_AGENT_MCP_HOME:-}"

  [[ -n "$checkout" && -d "$checkout" && -n "$staging" ]] || return 0

  # Grok writes a project .mcp.json that can collide across shared primary
  # checkouts — keep that path worktree-only. OpenCode has no per-launch MCP
  # flag alternative (unlike Codex/Claude), so inject whenever this launch is
  # paired to a workspace staging tree (primary checkout or worktree).
  if [[ "${DEVIDE_WORKTREE:-0}" != "1" ]]; then
    case "$runtime" in
      grok|agent)
        echo "warn: skipping project MCP injection for ${runtime} outside an agent worktree" >&2
        return 0
        ;;
      opencode)
        if [[ -z "${DEVIDE_WORKSPACE_NAME:-}" || -z "${DEVIDE_WORKSPACE_ID:-}" ]]; then
          echo "warn: skipping OpenCode MCP injection — workspace not paired (no DEVIDE_WORKSPACE_*)" >&2
          return 0
        fi
        ;;
    esac
  fi

  case "$runtime" in
    grok|agent)
      if [[ -f "${staging}/.mcp.json" ]]; then
        cp "${staging}/.mcp.json" "${checkout}/.mcp.json"
        chmod 600 "${checkout}/.mcp.json"
      fi
      ;;
    opencode)
      if [[ -f "${staging}/opencode.json" ]]; then
        mkdir -p "${checkout}/.opencode"
        cp "${staging}/opencode.json" "${checkout}/.opencode/opencode.json"
        chmod 600 "${checkout}/.opencode/opencode.json"
      fi
      ;;
  esac
}

# Stage DevIDE-infra skills for OpenCode. OpenCode also auto-loads
# ~/.claude/skills, but project .opencode/skills and ~/.config/opencode/skills
# are the first-class paths (and project skills are often gitignored).
opencode_install_skills() {
  local checkout="${DEVIDE_CHECKOUT:-}"
  local src="${ROOT}/.claude/skills"

  agent_skills_install "$src" "${HOME}/.config/opencode"
  if [[ -n "$checkout" && -d "$checkout" ]]; then
    mkdir -p "${checkout}/.opencode" 2>/dev/null || true
    agent_skills_install "$src" "${checkout}/.opencode"
  fi
}

sync_project_mcp_config "$RUNTIME"
if [[ "$RUNTIME" == "opencode" ]]; then
  opencode_install_skills
fi

if [[ -n "${DEVIDE_CHECKOUT:-}" && -d "${DEVIDE_CHECKOUT}" ]]; then
  cd "${DEVIDE_CHECKOUT}"
fi

runtime_bin() {
  local name="$1"
  local bin
  bin="$(real_agent_bin "$name")"
  if [[ -z "$bin" ]]; then
    echo "error: could not find executable for ${name} (run scripts/install-agent-shims.sh)" >&2
    exit 1
  fi
  printf '%s\n' "$bin"
}

workspace_slug() {
  DEVIDE_WORKSPACE_NAME="${DEVIDE_WORKSPACE_NAME:-workspace}" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ.get('DEVIDE_WORKSPACE_NAME', 'workspace')).strip('-').lower()
print(slug or 'workspace')
"
}

codex_mcp_config_args() {
  local slug terminal_key preview_key artifact_key tidewave_key
  slug="$(workspace_slug)"
  terminal_key="devide-terminal-${slug}"
  preview_key="devide-preview-${slug}"
  artifact_key="devide-artifact-${slug}"
  tidewave_key="devide-tidewave-${slug}"

  printf '%s\0' \
    -c "mcp_servers.${terminal_key}.url=\"${DEVIDE_TERMINAL_MCP_URL}\"" \
    -c "mcp_servers.${terminal_key}.enabled=true" \
    -c "mcp_servers.${terminal_key}.bearer_token_env_var=\"DEV_IDE_API_TOKEN\"" \
    -c "mcp_servers.${preview_key}.url=\"${DEVIDE_PREVIEW_MCP_URL}\"" \
    -c "mcp_servers.${preview_key}.enabled=true" \
    -c "mcp_servers.${preview_key}.bearer_token_env_var=\"DEV_IDE_API_TOKEN\"" \
    -c "mcp_servers.${artifact_key}.url=\"${DEVIDE_ARTIFACT_MCP_URL}\"" \
    -c "mcp_servers.${artifact_key}.enabled=true" \
    -c "mcp_servers.${artifact_key}.bearer_token_env_var=\"DEV_IDE_API_TOKEN\""

  if [[ -n "${DEVIDE_TIDEWAVE_MCP_URL:-}" ]]; then
    printf '%s\0' \
      -c "mcp_servers.${tidewave_key}.url=\"${DEVIDE_TIDEWAVE_MCP_URL}\"" \
      -c "mcp_servers.${tidewave_key}.enabled=true"
  fi
}

codex_arg_sets_execution_policy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dangerously-bypass-approvals-and-sandbox)
        return 0
        ;;
      --sandbox | --sandbox=* | -s | -s=* | -s?*)
        return 0
        ;;
      --ask-for-approval | --ask-for-approval=* | -a | -a=* | -a?*)
        return 0
        ;;
    esac
  done

  return 1
}

# --- Semantic agent-state reporting (Grok hooks + Codex notify) -------------
# Claude gets its state hooks via a materialized --settings file below. Grok
# loads global hook files from ~/.grok/hooks (always trusted; the hook command
# is env-guarded so unpaired grok sessions no-op silently). Codex has no hook
# files but supports a `notify` program config; DevIDE injects it per-launch.
# Both honor the same opt-out as Claude: DEVIDE_AGENT_STATE_HOOKS=0.

grok_install_state_hook() {
  [[ "${DEVIDE_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0
  local src="${ROOT}/scripts/agent-hooks/grok-devide-agent-state.json"
  local hooks_dir="${GROK_HOME:-${HOME}/.grok}/hooks"
  local dst="${hooks_dir}/devide-agent-state.json"
  [[ -f "$src" ]] || return 0
  mkdir -p "$hooks_dir" 2>/dev/null || return 0
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    cp "$src" "$dst" 2>/dev/null || true
  fi
}

codex_arg_sets_notify() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      notify=*)
        return 0
        ;;
    esac
  done

  return 1
}

codex_state_notify_args() {
  [[ "${DEVIDE_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0

  if codex_arg_sets_notify "$@"; then
    return 0
  fi

  local script="${DEVIDE_AGENT_MCP_HOME:-${DEVIDE_SCRIPTS:-${ROOT}/scripts}}/devide-codex-notify.sh"
  [[ -x "$script" ]] || return 0

  printf '%s\0' -c "notify=[\"${script}\"]"
}

codex_default_args() {
  case "${DEVIDE_CODEX_DEFAULT_YOLO:-1}" in
    0 | false | FALSE | no | NO | off | OFF)
      return 0
      ;;
  esac

  if codex_arg_sets_execution_policy "$@"; then
    return 0
  fi

  printf '%s\0' --dangerously-bypass-approvals-and-sandbox
}

claude_arg_sets_permission_policy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dangerously-skip-permissions)
        return 0
        ;;
      --permission-mode | --permission-mode=*)
        return 0
        ;;
    esac
  done

  return 1
}

claude_default_args() {
  case "${DEVIDE_CLAUDE_DEFAULT_YOLO:-1}" in
    0 | false | FALSE | no | NO | off | OFF)
      return 0
      ;;
  esac

  if claude_arg_sets_permission_policy "$@"; then
    return 0
  fi

  printf '%s\0' --dangerously-skip-permissions
}

case "$RUNTIME" in
  grok)
    # Grok treats project .mcp.json as a Cursor-compatible MCP source. Keep that
    # enabled in agent worktrees, but disable compatibility MCP scans when we
    # deliberately skipped project injection in the primary checkout.
    if [[ "${DEVIDE_WORKTREE:-0}" != "1" ]]; then
      export GROK_CURSOR_MCPS_ENABLED=false
      export GROK_CLAUDE_MCPS_ENABLED=false
    fi
    grok_install_state_hook
    exec "$(runtime_bin grok)" "$@"
    ;;
  codex)
    codex_args=()
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_mcp_config_args)
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_state_notify_args "$@")
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_default_args "$@")
    exec "$(runtime_bin codex)" "${codex_args[@]}" "$@"
    ;;
  opencode)
    exec "$(runtime_bin opencode)" "$@"
    ;;
  claude)
    sidechat_target=""
    claude_user_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --sidechat)
          sidechat_target="${2:-}"
          shift 2
          ;;
        *)
          claude_user_args+=("$1")
          shift
          ;;
      esac
    done
    set -- "${claude_user_args[@]}"

    # Stage DevIDE-infra skills (e.g. delegate-to-grok) into this launch's Claude
    # config home so agents in non-dev_ide workspaces still have them. enforce_owner_auth
    # above sets CLAUDE_CONFIG_DIR when the workspace uses an owner profile; otherwise
    # Claude reads the host global ~/.claude. Opt out with DEVIDE_AGENT_SKILLS=0.
    agent_skills_install "${ROOT}/.claude/skills" "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

    # Source MCP from this workspace's isolated staging tree (one per workspace),
    # like GROK_HOME/CODEX_HOME do — never from a shared-checkout project file,
    # which collides/accumulates across workspaces. Prefer staging; fall back to
    # the checkout only if staging is missing.
    mcp_json="${DEVIDE_AGENT_MCP_HOME}/.mcp.json"
    if [[ ! -f "$mcp_json" && -f "${DEVIDE_CHECKOUT}/.mcp.json" ]]; then
      mcp_json="${DEVIDE_CHECKOUT}/.mcp.json"
    fi
    if [[ ! -f "$mcp_json" ]]; then
      echo "error: missing .mcp.json in ${DEVIDE_AGENT_MCP_HOME} or ${DEVIDE_CHECKOUT}" >&2
      exit 1
    fi
    if [[ -d "${DEVIDE_CHECKOUT}" ]]; then
      cd "${DEVIDE_CHECKOUT}"
    else
      cd "$(dirname "$mcp_json")"
    fi
    # --mcp-config is additive (no --strict): keeps the operator's global MCP
    # servers (e.g. fff) and layers the workspace's terminal/preview/artifact on top.
    # DEV_IDE_API_TOKEN is already exported by agent_env_resolve above, so the
    # ${DEV_IDE_API_TOKEN} placeholder in the config resolves.
    claude_args=(--mcp-config "$mcp_json")

    if [[ -n "$sidechat_target" ]]; then
      sidechat_resolve_target "$sidechat_target"
      sidechat_prompt="${DEVIDE_AGENT_MCP_HOME}/claude-sidechat-prompt.txt"
      sidechat_write_prompt "$sidechat_prompt"
      sidechat_settings="${DEVIDE_AGENT_MCP_HOME}/claude-sidechat-settings.json"
      if [[ ! -f "$sidechat_settings" ]]; then
        echo "error: missing ${sidechat_settings} — run scripts/materialize-agent-mcp.sh" >&2
        exit 1
      fi
      claude_args+=(--settings "$sidechat_settings")
      claude_args+=(--append-system-prompt "$(<"$sidechat_prompt")")
    else
      # Semantic agent-state hooks (opt out with DEVIDE_AGENT_STATE_HOOKS=0). The
      # settings file is materialized next to .mcp.json and, like --mcp-config, is
      # additive with the operator's global settings.
      hooks_settings="${DEVIDE_AGENT_MCP_HOME}/claude-hooks-settings.json"
      if [[ "${DEVIDE_AGENT_STATE_HOOKS:-1}" != "0" && -f "$hooks_settings" ]]; then
        claude_args+=(--settings "$hooks_settings")
      fi
      while IFS= read -r -d '' arg; do
        claude_args+=("$arg")
      done < <(claude_default_args "$@")
    fi

    exec "$(runtime_bin claude)" "${claude_args[@]}" "$@"
    ;;
  agent)
    if [[ "${DEVIDE_WORKTREE:-0}" != "1" ]]; then
      export GROK_CURSOR_MCPS_ENABLED=false
      export GROK_CLAUDE_MCPS_ENABLED=false
    fi
    exec "$(runtime_bin agent)" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown runtime: $RUNTIME" >&2
    usage >&2
    exit 1
    ;;
esac
