#!/usr/bin/env bash
#
# Launch an external agent with DevIDE Terminal + Preview MCP injected at runtime.
# Works from any cwd — does not require living inside the dev_ide checkout.
#
# Usage:
#   source .devbox-agent.env
#   bash scripts/launch-devide-agent.sh grok
#   bash scripts/launch-devide-agent.sh codex
#   bash scripts/launch-devide-agent.sh claude
#   bash scripts/launch-devide-agent.sh opencode
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: launch-devide-agent.sh <runtime> [runtime args...]

Runtimes:
  grok      GROK_HOME → isolated grok/config.toml
  codex     CODEX_HOME → isolated codex/config.toml
  claude    project .mcp.json in DEVIDE_CHECKOUT (materialized)
  opencode  OPENCODE_CONFIG → isolated opencode.json

Requires: source .devbox-agent.env (or exported DEV_IDE_API_TOKEN + workspace vars)
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

RUNTIME="$1"
shift

if [[ -f "${ROOT}/.devbox-agent.env" ]] && [[ -z "${DEV_IDE_API_TOKEN:-}" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/.devbox-agent.env"
fi

eval "$(bash "${ROOT}/scripts/materialize-agent-mcp.sh" --export)"

case "$RUNTIME" in
  grok)
    export GROK_HOME="${DEVIDE_AGENT_MCP_HOME}/grok"
    exec grok "$@"
    ;;
  codex)
    export CODEX_HOME="${DEVIDE_AGENT_MCP_HOME}/codex"
    exec codex "$@"
    ;;
  opencode)
    export OPENCODE_CONFIG="${DEVIDE_AGENT_MCP_HOME}/opencode.json"
    exec opencode "$@"
    ;;
  claude)
    if [[ ! -f "${DEVIDE_CHECKOUT}/.mcp.json" ]]; then
      echo "error: missing ${DEVIDE_CHECKOUT}/.mcp.json — run materialize-agent-mcp.sh" >&2
      exit 1
    fi
    # Claude discovers .mcp.json by walking up from cwd; start from checkout.
    cd "${DEVIDE_CHECKOUT}"
    exec claude "$@"
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
