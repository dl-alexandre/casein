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

usage() {
  cat <<'EOF'
Usage: launch-devide-agent.sh <runtime> [runtime args...]

Creates a dedicated git worktree when launched from the primary checkout (see
docs/development-workflow.md). Set DEVIDE_AGENT_SKIP_WORKTREE=1 to opt out.

Runtimes:
  grok      injects per-workspace MCP via project .mcp.json
  codex     injects per-workspace MCP via launch-time config overrides
  claude    injects per-workspace MCP via --mcp-config (keeps ~/.claude credentials)
  opencode  injects per-workspace MCP via project .opencode/opencode.json
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
eval "$(bash "${ROOT}/scripts/materialize-agent-mcp.sh" --export 2>/dev/null || true)"
agent_env_export_runtime_paths
bash "${ROOT}/scripts/lib/repair-tmux-env.sh" 2>/dev/null || true
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py"

# Never redirect agent homes to MCP staging. Preserve only explicit DevIDE
# workspace auth profiles under ~/.devide/agent-auth.
unset GROK_HOME OPENCODE_CONFIG
if [[ -n "${CODEX_HOME:-}" ]] &&
  { ! agent_auth_profile_under_root "$CODEX_HOME" || [[ ! -d "$CODEX_HOME" ]]; }; then
  unset CODEX_HOME
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] &&
  { ! agent_auth_profile_under_root "$CLAUDE_CONFIG_DIR" || [[ ! -d "$CLAUDE_CONFIG_DIR" ]]; }; then
  unset CLAUDE_CONFIG_DIR
fi

sync_project_mcp_config() {
  local runtime="$1"
  local checkout="${DEVIDE_CHECKOUT:-}"
  local staging="${DEVIDE_AGENT_MCP_HOME:-}"

  [[ -n "$checkout" && -d "$checkout" && -n "$staging" ]] || return 0

  if [[ "${DEVIDE_WORKTREE:-0}" != "1" ]]; then
    case "$runtime" in
      grok|opencode)
        echo "warn: skipping project MCP injection for ${runtime} outside an agent worktree" >&2
        return 0
        ;;
    esac
  fi

  case "$runtime" in
    grok)
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

sync_project_mcp_config "$RUNTIME"

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
  local slug terminal_key preview_key tidewave_key
  slug="$(workspace_slug)"
  terminal_key="devide-terminal-${slug}"
  preview_key="devide-preview-${slug}"
  tidewave_key="devide-tidewave-${slug}"

  printf '%s\0' \
    -c "mcp_servers.\"${terminal_key}\".url=\"${DEVIDE_TERMINAL_MCP_URL}\"" \
    -c "mcp_servers.\"${terminal_key}\".enabled=true" \
    -c "mcp_servers.\"${terminal_key}\".bearer_token_env_var=\"DEV_IDE_API_TOKEN\"" \
    -c "mcp_servers.\"${preview_key}\".url=\"${DEVIDE_PREVIEW_MCP_URL}\"" \
    -c "mcp_servers.\"${preview_key}\".enabled=true" \
    -c "mcp_servers.\"${preview_key}\".bearer_token_env_var=\"DEV_IDE_API_TOKEN\""

  if [[ -n "${DEVIDE_TIDEWAVE_MCP_URL:-}" ]]; then
    printf '%s\0' \
      -c "mcp_servers.\"${tidewave_key}\".url=\"${DEVIDE_TIDEWAVE_MCP_URL}\"" \
      -c "mcp_servers.\"${tidewave_key}\".enabled=true"
  fi
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
    exec "$(runtime_bin grok)" "$@"
    ;;
  codex)
    codex_args=()
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_mcp_config_args)
    exec "$(runtime_bin codex)" "${codex_args[@]}" "$@"
    ;;
  opencode)
    exec "$(runtime_bin opencode)" "$@"
    ;;
  claude)
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
    # servers (e.g. fff) and layers the workspace's terminal/preview on top.
    # DEV_IDE_API_TOKEN is already exported by agent_env_resolve above, so the
    # ${DEV_IDE_API_TOKEN} placeholder in the config resolves.
    exec "$(runtime_bin claude)" --mcp-config "$mcp_json" "$@"
    ;;
  agent)
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
