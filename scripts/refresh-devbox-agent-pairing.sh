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

WORKSPACES_JSON="$(
  curl -fsS -H "authorization: Bearer ${TOKEN}" "${LOCAL_URL}/api/workspaces"
)"

WORKSPACE_ID="$(
  WORKSPACES_JSON="$WORKSPACES_JSON" WORKSPACE_NAME="$WORKSPACE_NAME" python3 -c "
import json, os
name = os.environ['WORKSPACE_NAME']
for w in json.loads(os.environ['WORKSPACES_JSON']):
    if w.get('name') == name:
        print(w['id'])
        break
"
)"

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "error: workspace ${WORKSPACE_NAME} not found" >&2
  exit 1
fi

default_checkout() {
  local workspace_name="$1"
  case "$workspace_name" in
    dalexandre-devide | dev_ide) printf '%s\n' "${ROOT}" ;;
    *)
      if [[ -d "/data/workspaces/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/${workspace_name}"
      elif [[ -d "/data/workspaces/dalexandre/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/dalexandre/${workspace_name}"
      else
        printf '%s\n' "/data/workspaces/${workspace_name}"
      fi
      ;;
  esac
}

scripts_for_checkout() {
  local checkout="$1"
  if [[ -f "${checkout}/scripts/devide" ]]; then
    printf '%s\n' "${checkout}/scripts"
  else
    printf '%s\n' "${ROOT}/scripts"
  fi
}

materialize_all_workspaces() {
  local prefix="${DEVIDE_WORKSPACE_PREFIX:-dalexandre}"

  WORKSPACES_JSON="$WORKSPACES_JSON" PREFIX="$prefix" python3 -c "
import json, os

prefix = os.environ.get('PREFIX', '')
for ws in json.loads(os.environ['WORKSPACES_JSON']):
    name = ws.get('name') or ''
    ws_id = ws.get('id') or ''
    if not name or not ws_id:
        continue
    if prefix and not name.startswith(prefix):
        continue
    print(f\"{name}\t{ws_id}\")
" | while IFS=$'\t' read -r ws_name ws_id; do
    [[ -n "$ws_name" && -n "$ws_id" ]] || continue
    checkout="$(default_checkout "$ws_name")"
    scripts="$(scripts_for_checkout "$checkout")"
    log "materializing MCP for ${ws_name}"
    DEV_IDE_API_TOKEN="${TOKEN}" \
      DEVIDE_WORKSPACE_NAME="${ws_name}" \
      DEVIDE_WORKSPACE_ID="${ws_id}" \
      DEVIDE_TERMINAL_MCP_URL="${LOCAL_URL}/api/terminals/mcp?workspace_id=${ws_id}" \
      DEVIDE_PREVIEW_MCP_URL="${LOCAL_URL}/api/preview/mcp?workspace_id=${ws_id}" \
      DEVIDE_CHECKOUT="${checkout}" \
      DEVIDE_SCRIPTS="${scripts}" \
      bash scripts/materialize-agent-mcp.sh >/dev/null
  done
}

TIDEWAVE_MCP_URL=""
if [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
  TIDEWAVE_MCP_URL="$(
    DEVIDE_WORKSPACE_NAME="${WORKSPACE_NAME}" \
      DEVIDE_WORKSPACE_ID="${WORKSPACE_ID}" \
      bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
  )"
fi
if [[ -z "$TIDEWAVE_MCP_URL" ]] && [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
  TIDEWAVE_MCP_URL="$(bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true)"
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
$( [[ -n "$TIDEWAVE_MCP_URL" ]] && printf "export DEVIDE_TIDEWAVE_MCP_URL='%s'\n" "$TIDEWAVE_MCP_URL" )
export DEVIDE_CHECKOUT='${ROOT}'
export DEVIDE_SCRIPTS='${ROOT}/scripts'
export DEVIDE_AGENT_MCP_HOME="\${HOME}/.devide/agent-mcp/${WORKSPACE_NAME}"
EOF
chmod 600 "$AGENT_ENV"

log "wrote ${AGENT_ENV}"

ROOT="$ROOT" LOCAL_URL="$LOCAL_URL" TOKEN="$TOKEN" materialize_all_workspaces

source "${AGENT_ENV}"
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py"

bash scripts/install-agent-shims.sh
bash scripts/refresh-tmux-pane-env.sh --workspace-prefix dalexandre

DEVIDE_URL="$LOCAL_URL" DEV_IDE_API_TOKEN="$TOKEN" \
  WORKSPACE_ID="$WORKSPACE_ID" DEVIDE_WORKSPACE_NAME="$WORKSPACE_NAME" \
  bash scripts/verify_agent_pairing.sh

log "done"