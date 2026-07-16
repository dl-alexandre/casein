#!/usr/bin/env bash
#
# Launch an external agent with DevIDE Terminal + Preview MCP injected at runtime.
#
set -euo pipefail
umask 077

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
  grok      injects an immutable capability bundle into a private leader session
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

# Child processes spawned by the managed agent can use this to distinguish a
# real DevIDE launch from an ordinary shell that merely sourced pairing env.
export DEVIDE_AGENT_LAUNCH_CONTEXT="$RUNTIME"

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
      if [[ "$RUNTIME" == "grok" ]]; then
        rm -f "$out" "$err"
        echo "error: managed Grok requires valid materialized capability exports" >&2
        return 1
      else
        warn_degraded_step "materialize-agent-mcp.sh --export eval" \
          "materializer emitted shell exports that could not be evaluated; stdout redacted because it may contain tokens"
      fi
    fi
  else
    detail="$(<"$err")"
    if [[ -s "$out" ]]; then
      detail="${detail}"$'\n'"materialize-agent-mcp.sh wrote $(wc -c <"$out") bytes to stdout; redacted because it may contain tokens"
    fi
    if [[ "$RUNTIME" == "grok" ]]; then
      rm -f "$out" "$err"
      echo "error: managed Grok capability materialization failed" >&2
      printf '%s\n' "${detail:0:1200}" >&2
      return 1
    else
      warn_degraded_step "materialize-agent-mcp.sh --export" "$detail"
    fi
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

if [[ "$RUNTIME" == "grok" ]]; then
  unset DEVIDE_GROK_BUNDLE_DIR DEVIDE_GROK_BUNDLE_DIGEST
  unset DEVIDE_GROK_LEADER_ROOT DEVIDE_GROK_LEADER_SOCKET
fi
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

  # OpenCode has no per-launch MCP flag alternative (unlike Codex/Claude/Grok),
  # so inject whenever this launch is paired to a workspace staging tree.
  if [[ "${DEVIDE_WORKTREE:-0}" != "1" ]]; then
    case "$runtime" in
      agent)
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
    agent)
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

# --- Semantic agent-state reporting (Grok bootstrap + Codex notify) ----------
# Claude gets its state hooks via a materialized --settings file below. Grok
# loads a global SessionStart bootstrap hook so DevIDE learns the session ID and
# can attach ACP with the session-scoped capability bundle. The bundle owns the
# remaining lifecycle hooks. Codex injects a per-launch `notify` program.
# Both honor the same opt-out as Claude: DEVIDE_AGENT_STATE_HOOKS=0.

grok_install_state_hook() {
  [[ "${DEVIDE_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0
  local src="${ROOT}/scripts/agent-hooks/grok-devide-agent-bootstrap.json"
  local hooks_dir="${GROK_HOME:-${HOME}/.grok}/hooks"
  local dst="${hooks_dir}/devide-agent-state.json"
  local script_src="${ROOT}/scripts/devide-agent-state.sh"
  local script_dst="${hooks_dir}/devide-agent-state.sh"
  [[ -f "$src" ]] || return 0
  mkdir -p "$hooks_dir" 2>/dev/null || return 0
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    cp "$src" "$dst" 2>/dev/null || true
  fi
  if [[ -f "$script_src" ]] && ! cmp -s "$script_src" "$script_dst" 2>/dev/null; then
    cp "$script_src" "$script_dst" 2>/dev/null || true
    chmod 700 "$script_dst" 2>/dev/null || true
  fi
}

grok_validate_managed_context() {
  local socket="${DEVIDE_GROK_LEADER_SOCKET:-}"
  local root="${DEVIDE_GROK_LEADER_ROOT:-}"
  local bundle="${DEVIDE_GROK_BUNDLE_DIR:-}"
  local digest="${DEVIDE_GROK_BUNDLE_DIGEST:-}"
  local socket_real root_real

  if [[ -z "$socket" || -z "$root" || -z "$bundle" || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: managed Grok launch is missing its private leader or capability bundle metadata" >&2
    return 1
  fi

  if [[ ! "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    echo "error: managed Grok launch requires an exact tmux pane id" >&2
    return 1
  fi

  socket_real="$(realpath -m "$socket")"
  root_real="$(realpath -m "$root")"
  if [[ "$(dirname "$socket_real")" != "$root_real" ]] ||
     [[ ! "$(basename "$socket_real")" =~ ^[0-9a-f]{24}\.sock$ ]]; then
    echo "error: refusing Grok leader socket outside the private leader root" >&2
    return 1
  fi

  if ! python3 "${ROOT}/scripts/lib/grok-capability-bundle.py" verify \
      "$bundle" --digest "$digest" >/dev/null; then
    echo "error: refusing invalid or mutable Grok capability bundle" >&2
    return 1
  fi
}

grok_capability_api_base() {
  local base="${DEVIDE_API_BASE_URL:-${DEVIDE_URL:-}}"
  if [[ -z "$base" ]]; then
    base="${DEVIDE_TERMINAL_MCP_URL%%/api/terminals/mcp*}"
  fi
  [[ -n "$base" ]] || return 1
  printf '%s\n' "${base%/}"
}

grok_parse_capability_response() {
  local response_file="$1"
  python3 - "$response_file" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
token = data.get("token")
capability_id = data.get("capability_id")
if not isinstance(token, str) or not token.startswith("grokcap_"):
    raise SystemExit(1)
if not isinstance(capability_id, str) or not capability_id:
    raise SystemExit(1)
terminal = (data.get("allowed_tools") or data.get("effective_tools") or {}).get("terminal", [])
write_enabled = "terminal_send_agent_command" in terminal
print(token)
print(capability_id)
print("true" if write_enabled else "false")
PY
}

grok_current_capability() {
  local token="$1" base="$2" response parsed
  response="$(mktemp)"
  if ! curl --max-time 5 -fsS -o "$response" \
      -H "authorization: Bearer ${token}" \
      "${base}/api/agent-capabilities/current" 2>/dev/null; then
    rm -f "$response"
    return 1
  fi
  # The current endpoint intentionally never returns the raw token. Reuse the
  # cached bearer only when every launch-bound claim still matches this exact
  # workspace, tmux session, leader, bundle, and checkout.
  parsed="$({ CAP_TOKEN="$token" python3 - "$response" <<'PY'
import hashlib, json, os, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
capability_id = data.get("capability_id")
if not isinstance(capability_id, str) or not capability_id:
    raise SystemExit(1)
checkout = os.path.realpath(os.environ["DEVIDE_CHECKOUT"])
expected = {
    "workspace_id": os.environ["DEVIDE_WORKSPACE_ID"],
    "runtime": "grok",
    "tmux_session_id": os.environ["DEVIDE_TMUX_SESSION"],
    "pane_id": os.environ["TMUX_PANE"],
    "leader_id": os.path.basename(os.environ["DEVIDE_GROK_LEADER_SOCKET"]).removesuffix(".sock"),
    "bundle_digest": os.environ["DEVIDE_GROK_BUNDLE_DIGEST"],
    "checkout_digest": hashlib.sha256(checkout.encode()).hexdigest(),
}
if any(data.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
terminal = (data.get("effective_tools") or {}).get("terminal", [])
print(os.environ["CAP_TOKEN"])
print(capability_id)
print("true" if "terminal_send_agent_command" in terminal else "false")
PY
  } 2>/dev/null)" || { rm -f "$response"; return 1; }
  rm -f "$response"
  printf '%s\n' "$parsed"
}

grok_issue_capability() {
  local bootstrap_token="$1" base="$2" response request parsed
  response="$(mktemp)"
  request="$(
    DEVIDE_WORKSPACE_ID="$DEVIDE_WORKSPACE_ID" \
      DEVIDE_TMUX_SESSION="$DEVIDE_TMUX_SESSION" \
      TMUX_PANE="$TMUX_PANE" \
      DEVIDE_GROK_LEADER_SOCKET="$DEVIDE_GROK_LEADER_SOCKET" \
      DEVIDE_GROK_BUNDLE_DIGEST="$DEVIDE_GROK_BUNDLE_DIGEST" \
      DEVIDE_CHECKOUT="$DEVIDE_CHECKOUT" \
      python3 - <<'PY'
import hashlib, json, os
checkout = os.path.realpath(os.environ["DEVIDE_CHECKOUT"])
print(json.dumps({
    "tmux_session_id": os.environ["DEVIDE_TMUX_SESSION"],
    "pane_id": os.environ["TMUX_PANE"],
    "leader_id": os.path.basename(os.environ["DEVIDE_GROK_LEADER_SOCKET"]).removesuffix(".sock"),
    "bundle_digest": os.environ["DEVIDE_GROK_BUNDLE_DIGEST"],
    "checkout_digest": hashlib.sha256(checkout.encode()).hexdigest(),
}))
PY
  )"

  if ! curl --max-time 8 -fsS -o "$response" -X POST \
      "${base}/api/workspaces/${DEVIDE_WORKSPACE_ID}/grok-agent-capabilities" \
      -H "authorization: Bearer ${bootstrap_token}" \
      -H "content-type: application/json" \
      -d "$request" 2>/dev/null; then
    rm -f "$response"
    return 1
  fi
  parsed="$(grok_parse_capability_response "$response")" || { rm -f "$response"; return 1; }
  rm -f "$response"
  printf '%s\n' "$parsed"
}

grok_install_sandbox_profile() {
  local profile="$1" base="$2" capability_file="$3"
  local grok_sandbox_file="${GROK_HOME:-${HOME}/.grok}/sandbox.toml"
  local tmux_dir="${TMUX%%,*}"
  local bootstrap_file="${DEVIDE_AGENT_BOOTSTRAP_FILE:-}"

  python3 "${ROOT}/scripts/lib/grok-sandbox-profile.py" install "$profile" "$base" \
    "$capability_file" \
    "$(dirname "$capability_file")/*.capability" \
    "$grok_sandbox_file" \
    "${DEVIDE_AGENT_MCP_HOME:-}" \
    "$bootstrap_file" \
    "${HOME}/.devide/agent-mcp" \
    "${HOME}/.devide/grok-leaders/*.capability" \
    "${HOME}/.devide/workspace-api-tokens.json" \
    "${HOME}/.devide/agent-auth" \
    "${HOME}/.ssh" \
    "${HOME}/.gnupg" \
    "${HOME}/.aws" \
    "${HOME}/.azure" \
    "${HOME}/.kube" \
    "${HOME}/.docker" \
    "${HOME}/.codex" \
    "${HOME}/.claude" \
    "${HOME}/.local/share/opencode" \
    "${HOME}/.local/share/keyrings" \
    "${HOME}/.config/gh*" \
    "${HOME}/.config/gcloud" \
    "${HOME}/.config/git/credentials" \
    "${HOME}/.terraform.d" \
    "${HOME}/.git-credentials" \
    "${HOME}/.netrc" \
    "${HOME}/.npmrc" \
    "${HOME}/.pypirc" \
    "${HOME}/.grok/auth.json" \
    "${HOME}/.grok/mcp_credentials.json" \
    "/etc/devide/devide.env" \
    "$tmux_dir" \
    "/proc/*/environ" \
    "/data/workspaces/*/.devbox-agent.env" \
    "/data/workspaces/*/*/.devbox-agent.env" >/dev/null
}

grok_configure_capability() {
  local grok_bin="$1" base bootstrap_token socket leader_id capability_file
  local parsed token capability_id write_enabled profile sandbox_base tmp
  base="$(grok_capability_api_base)" || {
    echo "error: managed Grok capability issuer URL is unavailable" >&2
    return 1
  }
  bootstrap_token="${DEV_IDE_API_TOKEN:-}"
  socket="$(realpath -m "$DEVIDE_GROK_LEADER_SOCKET")"
  leader_id="$(basename "$socket" .sock)"
  capability_file="$(dirname "$socket")/${leader_id}.capability"

  if [[ -S "$socket" && -r "$capability_file" ]] &&
     "$grok_bin" --leader-socket "$socket" leader info --json >/dev/null 2>&1; then
    token="$(<"$capability_file")"
    if parsed="$(grok_current_capability "$token" "$base")"; then
      mapfile -t fields <<<"$parsed"
      token="${fields[0]:-}"
      capability_id="${fields[1]:-}"
      write_enabled="${fields[2]:-false}"
    fi
  fi

  if [[ -z "${capability_id:-}" ]]; then
    if [[ -S "$socket" ]]; then
      "$grok_bin" --leader-socket "$socket" leader kill >/dev/null 2>&1 || true
      rm -f "$socket"
    fi
    parsed="$(grok_issue_capability "$bootstrap_token" "$base")" || {
      echo "error: managed Grok capability exchange failed" >&2
      return 1
    }
    mapfile -t fields <<<"$parsed"
    token="${fields[0]:-}"
    capability_id="${fields[1]:-}"
    write_enabled="${fields[2]:-false}"
    tmp="$(mktemp "${capability_file}.XXXXXX")"
    printf '%s' "$token" >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$capability_file"
  fi

  if [[ "$write_enabled" == "true" ]]; then
    sandbox_base="strict"
  else
    sandbox_base="read-only"
  fi
  profile="devide-${leader_id}-${capability_id//-/}-${sandbox_base}"
  profile="${profile:0:95}"
  grok_install_sandbox_profile "$profile" "$sandbox_base" "$capability_file" || {
    echo "error: failed to install managed Grok sandbox profile" >&2
    return 1
  }

  export DEV_IDE_API_TOKEN="$token"
  export DEVIDE_GROK_SANDBOX_PROFILE="$profile"
  export DEVIDE_GROK_PERMISSION_MODE="default"
  unset DEV_IDE_ADMIN_API_TOKEN DEV_IDE_WORKSPACE_API_TOKENS
  unset DEVIDE_AGENT_ENV_FILE DEVIDE_AGENT_BOOTSTRAP_FILE DEVIDE_AGENT_MCP_HOME
}

grok_prepare_private_leader() {
  local grok_bin="$1" sandbox_profile="$2" permission_mode="$3"
  local socket="${DEVIDE_GROK_LEADER_SOCKET:-}"
  local root="${DEVIDE_GROK_LEADER_ROOT:-}"
  local bundle="${DEVIDE_GROK_BUNDLE_DIR:-}"
  local digest="${DEVIDE_GROK_BUNDLE_DIGEST:-}"
  local socket_real root_real log leader_pid="" runtime_file expected_signature current_signature tmp

  socket_real="$(realpath -m "$socket")"
  root_real="$(realpath -m "$root")"

  mkdir -p "$root_real"
  chmod 700 "$root_real"
  runtime_file="${socket_real%.sock}.runtime"
  expected_signature="${sandbox_profile}:${permission_mode}"

  if "$grok_bin" --leader-socket "$socket_real" leader info --json >/dev/null 2>&1; then
    current_signature=""
    if [[ -f "$runtime_file" ]]; then
      current_signature="$(<"$runtime_file")"
    fi
    if [[ "$current_signature" == "$expected_signature" ]]; then
      return 0
    fi

    "$grok_bin" --leader-socket "$socket_real" leader kill >/dev/null 2>&1 || true
  fi

  # The socket is under our validated private root and failed a leader probe,
  # so it is stale rather than an arbitrary user path.
  rm -f "$socket_real"
  rm -f "$runtime_file"
  log="$(mktemp)"
  nohup "$grok_bin" --sandbox "$sandbox_profile" --permission-mode "$permission_mode" \
    --leader-socket "$socket_real" agent leader \
    --no-exit-on-disconnect --relay-on-demand --no-auto-update \
    </dev/null >/dev/null 2>"$log" &
  leader_pid=$!

  for _attempt in $(seq 1 100); do
    if [[ -S "$socket_real" ]] &&
       "$grok_bin" --leader-socket "$socket_real" leader info --json >/dev/null 2>&1; then
      tmp="$(mktemp "${runtime_file}.XXXXXX")"
      printf '%s' "$expected_signature" >"$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$runtime_file"
      rm -f "$log"
      return 0
    fi
    if ! kill -0 "$leader_pid" 2>/dev/null && [[ ! -S "$socket_real" ]]; then
      break
    fi
    sleep 0.05
  done

  kill "$leader_pid" 2>/dev/null || true
  rm -f "$log"
  echo "error: private Grok leader did not become ready at ${socket_real}" >&2
  return 1
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
    export GROK_CURSOR_MCPS_ENABLED=false
    export GROK_CLAUDE_MCPS_ENABLED=false
    grok_install_state_hook
    grok_bin="$(runtime_bin grok)"
    grok_validate_managed_context
    grok_socket="$(realpath -m "${DEVIDE_GROK_LEADER_SOCKET:-}")"
    grok_user_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --leader-socket)
          [[ $# -ge 2 ]] || { echo "error: --leader-socket requires a path" >&2; exit 2; }
          if [[ "$(realpath -m "$2")" != "$grok_socket" ]]; then
            echo "error: managed Grok must use DevIDE's private leader socket" >&2
            exit 2
          fi
          shift 2
          ;;
        --leader-socket=*)
          if [[ "$(realpath -m "${1#*=}")" != "$grok_socket" ]]; then
            echo "error: managed Grok must use DevIDE's private leader socket" >&2
            exit 2
          fi
          shift
          ;;
        --sandbox | --sandbox=* | --permission-mode | --permission-mode=* | --always-approve | --cwd | --cwd=* | --worktree | --worktree=*)
          echo "error: managed Grok launch owns sandbox, permission, cwd, and worktree policy" >&2
          exit 2
          ;;
        *)
          grok_user_args+=("$1")
          shift
          ;;
      esac
    done
    grok_configure_capability "$grok_bin"
    grok_prepare_private_leader "$grok_bin" "$DEVIDE_GROK_SANDBOX_PROFILE" "$DEVIDE_GROK_PERMISSION_MODE"
    exec "$grok_bin" --sandbox "$DEVIDE_GROK_SANDBOX_PROFILE" \
      --permission-mode "$DEVIDE_GROK_PERMISSION_MODE" \
      --leader-socket "$grok_socket" "${grok_user_args[@]}"
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
