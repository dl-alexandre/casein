#!/usr/bin/env bash
#
# Refresh .devbox-agent.env and materialized MCP configs without redeploying.
# Ensures loopback :4000 works (socat proxy when using canary Unix sockets).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
WORKSPACE_NAME="${DEV_IDE_WORKSPACE_NAME:-dalexandre-devide}"
AGENT_ENV="${ROOT}/.devbox-agent.env"

log() { printf '>>> %s\n' "$*"; }

TOKEN="$(sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "$ENV_FILE" | tail -n 1)"
if [[ -z "$TOKEN" ]]; then
  echo "error: DEV_IDE_API_TOKEN missing from $ENV_FILE" >&2
  exit 1
fi

bash scripts/ensure-devide-loopback-proxy.sh

LOCAL_URL="http://127.0.0.1:4000"
PUBLIC_URL="https://devide.devbox.milcgroup.com"

WORKSPACE_ID="$(
  curl -fsS -H "authorization: Bearer ${TOKEN}" "${LOCAL_URL}/api/workspaces" |
    WORKSPACE_NAME="$WORKSPACE_NAME" python3 -c "
import json, sys, os
name = os.environ['WORKSPACE_NAME']
for w in json.load(sys.stdin):
    if w.get('name') == name:
        print(w['id'])
        break
"
)"

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "error: workspace ${WORKSPACE_NAME} not found" >&2
  exit 1
fi

cat >"$AGENT_ENV" <<EOF
# DevIDE devbox agent pairing — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source before starting an external agent:  source .devbox-agent.env

export DEV_IDE_API_TOKEN='${TOKEN}'
export DEVIDE_URL='${LOCAL_URL}'
export DEVIDE_PUBLIC_URL='${PUBLIC_URL}'
export DEVIDE_WORKSPACE_ID='${WORKSPACE_ID}'
export DEVIDE_WORKSPACE_NAME='${WORKSPACE_NAME}'
export DEVIDE_TERMINAL_MCP_URL='${LOCAL_URL}/api/terminals/mcp?workspace_id=${WORKSPACE_ID}'
export DEVIDE_PREVIEW_MCP_URL='${LOCAL_URL}/api/preview/mcp?workspace_id=${WORKSPACE_ID}'
export DEVIDE_CHECKOUT='${ROOT}'
export DEVIDE_AGENT_MCP_HOME="\${HOME}/.devide/agent-mcp/${WORKSPACE_NAME}"
EOF
chmod 600 "$AGENT_ENV"

log "wrote ${AGENT_ENV}"
source "${AGENT_ENV}"
bash scripts/materialize-agent-mcp.sh

DEVIDE_URL="$LOCAL_URL" DEV_IDE_API_TOKEN="$TOKEN" \
  WORKSPACE_ID="$WORKSPACE_ID" DEVIDE_WORKSPACE_NAME="$WORKSPACE_NAME" \
  bash scripts/verify_agent_pairing.sh

log "done"