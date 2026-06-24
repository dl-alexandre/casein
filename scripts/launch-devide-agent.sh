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

usage() {
  cat <<'EOF'
Usage: launch-devide-agent.sh <runtime> [runtime args...]

Creates a dedicated git worktree when launched from the primary checkout (see
docs/development-workflow.md). Set DEVIDE_AGENT_SKIP_WORKTREE=1 to opt out.

Runtimes:
  grok      merges MCP into ~/.grok/config.toml (keeps auth.json)
  codex     merges MCP into ~/.codex/config.toml (keeps auth.json)
  claude    injects per-workspace MCP via --mcp-config (keeps ~/.claude credentials)
  opencode  merges MCP into ~/.config/opencode/opencode.json
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

# Never redirect agent homes to staging — that drops auth.json / credentials.
unset GROK_HOME CODEX_HOME OPENCODE_CONFIG

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

case "$RUNTIME" in
  grok)
    exec "$(runtime_bin grok)" "$@"
    ;;
  codex)
    exec "$(runtime_bin codex)" "$@"
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