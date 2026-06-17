#!/usr/bin/env bash
#
# Repair DevIDE tmux session environment for agent panes.
#
# Fixes stale session env from earlier MCP work:
#   - DEV_IDE_API_TOKEN stored with literal shell quotes
#   - GROK_HOME / CODEX_HOME / OPENCODE_CONFIG redirecting auth to empty staging
#   - PATH left as a literal "${PATH}" string
#
# Usage:
#   bash scripts/refresh-tmux-pane-env.sh              # all devide_* sessions
#   bash scripts/refresh-tmux-pane-env.sh <session>    # one session
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
LOCAL_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
CANONICAL_SCRIPTS="${DEVIDE_SCRIPTS_ROOT:-${ROOT}/scripts}"

log() { printf '>>> %s\n' "$*"; }

TOKEN="$(sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "$ENV_FILE" | tail -n 1)"
if [[ -z "$TOKEN" ]]; then
  echo "error: DEV_IDE_API_TOKEN missing from ${ENV_FILE}" >&2
  exit 1
fi

declare -A WORKSPACE_IDS=()
while IFS=$'\t' read -r name id; do
  [[ -n "$name" && -n "$id" ]] || continue
  WORKSPACE_IDS["$name"]="$id"
done < <(
  curl -fsS -H "authorization: Bearer ${TOKEN}" "${LOCAL_URL}/api/workspaces" |
    python3 -c "
import json, sys
for ws in json.load(sys.stdin):
    name = ws.get('name') or ''
    ws_id = ws.get('id') or ''
    if name and ws_id:
        print(f\"{name}\t{ws_id}\")
"
)

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
    printf '%s\n' "${CANONICAL_SCRIPTS}"
  fi
}

materialize_workspace() {
  local workspace_name="$1"
  local workspace_id="$2"
  local checkout scripts staging

  checkout="$(default_checkout "$workspace_name")"
  scripts="$(scripts_for_checkout "$checkout")"
  staging="${HOME}/.devide/agent-mcp/${workspace_name}"

  DEV_IDE_API_TOKEN="${TOKEN}" \
    DEVIDE_WORKSPACE_NAME="${workspace_name}" \
    DEVIDE_WORKSPACE_ID="${workspace_id}" \
    DEVIDE_TERMINAL_MCP_URL="${LOCAL_URL}/api/terminals/mcp?workspace_id=${workspace_id}" \
    DEVIDE_PREVIEW_MCP_URL="${LOCAL_URL}/api/preview/mcp?workspace_id=${workspace_id}" \
    DEVIDE_CHECKOUT="${checkout}" \
    DEVIDE_SCRIPTS="${scripts}" \
    bash "${ROOT}/scripts/materialize-agent-mcp.sh" >/dev/null
}

repair_session() {
  local session="$1"
  local workspace_name workspace_id checkout scripts staging env_sh

  if [[ ! "$session" =~ ^devide_([^_]+)_ ]]; then
    log "skip ${session} (not a devide workspace session)"
    return 0
  fi

  workspace_name="${BASH_REMATCH[1]}"
  workspace_id="${WORKSPACE_IDS[$workspace_name]:-}"

  if [[ -z "$workspace_id" ]]; then
    log "skip ${session} (unknown workspace ${workspace_name})"
    return 0
  fi

  checkout="$(default_checkout "$workspace_name")"
  scripts="$(scripts_for_checkout "$checkout")"
  staging="${HOME}/.devide/agent-mcp/${workspace_name}"
  env_sh="${staging}/env.sh"

  materialize_workspace "$workspace_name" "$workspace_id"

  tmux set-environment -t "$session" -u GROK_HOME 2>/dev/null || true
  tmux set-environment -t "$session" -u CODEX_HOME 2>/dev/null || true
  tmux set-environment -t "$session" -u OPENCODE_CONFIG 2>/dev/null || true

  tmux set-environment -t "$session" DEV_IDE_API_TOKEN "$TOKEN"
  tmux set-environment -t "$session" DEVIDE_WORKSPACE_ID "$workspace_id"
  tmux set-environment -t "$session" DEVIDE_WORKSPACE_NAME "$workspace_name"
  tmux set-environment -t "$session" DEVIDE_TERMINAL_MCP_URL "${LOCAL_URL}/api/terminals/mcp?workspace_id=${workspace_id}"
  tmux set-environment -t "$session" DEVIDE_PREVIEW_MCP_URL "${LOCAL_URL}/api/preview/mcp?workspace_id=${workspace_id}"
  tmux set-environment -t "$session" DEVIDE_CHECKOUT "$checkout"
  tmux set-environment -t "$session" DEVIDE_AGENT_MCP_HOME "$staging"
  tmux set-environment -t "$session" DEVIDE_SCRIPTS "$scripts"
  tmux set-environment -t "$session" DEVIDE_AGENT_ENV_FILE "$env_sh"
  tmux set-environment -t "$session" PATH "${HOME}/.local/bin:${PATH}"

  log "repaired ${session} (${workspace_name})"
}

if [[ $# -gt 0 ]]; then
  for session in "$@"; do
    repair_session "$session"
  done
else
  mapfile -t sessions < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^devide_' || true)
  if [[ ${#sessions[@]} -eq 0 ]]; then
    log "no devide tmux sessions found"
    exit 0
  fi
  for session in "${sessions[@]}"; do
    repair_session "$session"
  done
fi

log "done"