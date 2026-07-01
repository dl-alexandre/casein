#!/usr/bin/env bash
#
# Repair DevIDE tmux session environment for the current or named session.
#
# Fixes stale session env from earlier MCP work:
#   - DEV_IDE_API_TOKEN stored with literal shell quotes
#   - provider homes redirecting auth to empty staging
#   - PATH left as a literal "${PATH}" string
#
# Usage:
#   bash scripts/lib/repair-tmux-env.sh                 # current tmux session
#   bash scripts/lib/repair-tmux-env.sh <session_name>  # explicit session
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
LOCAL_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
CANONICAL_SCRIPTS="${DEVIDE_SCRIPTS_ROOT:-${ROOT}/scripts}"
# shellcheck source=agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"

log() { printf '>>> %s\n' "$*" >&2; }

TOKEN="${DEV_IDE_API_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
fi

if [[ -z "$TOKEN" ]]; then
  echo "error: DEV_IDE_API_TOKEN missing (export it or set ${ENV_FILE})" >&2
  exit 1
fi

declare -A WORKSPACE_IDS=()
while IFS=$'\t' read -r name id; do
  [[ -n "$name" && -n "$id" ]] || continue
  WORKSPACE_IDS["$name"]="$id"
done < <(
  curl -fsS -H "authorization: Bearer ${TOKEN}" "${LOCAL_URL}/api/workspaces" 2>/dev/null |
    python3 -c "
import json, sys
for ws in json.load(sys.stdin):
    name = ws.get('name') or ''
    ws_id = ws.get('id') or ''
    if name and ws_id:
        print(f\"{name}\t{ws_id}\")
" 2>/dev/null || true
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

discover_tidewave_mcp_url() {
  local workspace_name="$1"
  local workspace_id="$2"
  local url=""

  if [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
    url="$(
      DEVIDE_WORKSPACE_NAME="${workspace_name}" \
        DEVIDE_WORKSPACE_ID="${workspace_id}" \
        bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
    )"
  fi

  if [[ -z "$url" ]] && [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
    url="$(bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true)"
  fi

  printf '%s' "$url"
}

materialize_workspace() {
  local workspace_name="$1"
  local workspace_id="$2"
  local session="${3:-}"
  local checkout scripts tidewave_url query_suffix

  checkout="$(default_checkout "$workspace_name")"
  scripts="$(scripts_for_checkout "$checkout")"
  tidewave_url="$(discover_tidewave_mcp_url "$workspace_name" "$workspace_id")"
  query_suffix="workspace_id=${workspace_id}"
  if [[ -n "$session" ]]; then
    query_suffix="${query_suffix}&tmux_session=${session}"
  fi

  DEV_IDE_API_TOKEN="${TOKEN}" \
    DEVIDE_WORKSPACE_NAME="${workspace_name}" \
    DEVIDE_WORKSPACE_ID="${workspace_id}" \
    DEVIDE_TMUX_SESSION="${session}" \
    DEVIDE_TERMINAL_MCP_URL="${LOCAL_URL}/api/terminals/mcp?${query_suffix}" \
    DEVIDE_PREVIEW_MCP_URL="${LOCAL_URL}/api/preview/mcp?${query_suffix}" \
    DEVIDE_TIDEWAVE_MCP_URL="${tidewave_url}" \
    DEVIDE_CHECKOUT="${checkout}" \
    DEVIDE_SCRIPTS="${scripts}" \
    bash "${ROOT}/scripts/materialize-agent-mcp.sh" >/dev/null
}

set_provider_auth_profiles() {
  local session="$1"
  local workspace_name="$2"
  local key value

  tmux set-environment -t "$session" -u CLAUDE_CONFIG_DIR 2>/dev/null || true
  tmux set-environment -t "$session" -u CODEX_HOME 2>/dev/null || true

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" && -n "$value" ]] || continue
    tmux set-environment -t "$session" "$key" "$value"
  done < <(
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --pairs "$workspace_name" claude
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --pairs "$workspace_name" codex
  )
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

  local tidewave_url
  tidewave_url="$(discover_tidewave_mcp_url "$workspace_name" "$workspace_id")"

  materialize_workspace "$workspace_name" "$workspace_id" "$session"

  tmux set-environment -t "$session" -u GROK_HOME 2>/dev/null || true
  tmux set-environment -t "$session" -u OPENCODE_CONFIG 2>/dev/null || true
  set_provider_auth_profiles "$session" "$workspace_name"

  tmux set-environment -t "$session" DEV_IDE_API_TOKEN "$TOKEN"
  tmux set-environment -t "$session" DEVIDE_WORKSPACE_ID "$workspace_id"
  tmux set-environment -t "$session" DEVIDE_WORKSPACE_NAME "$workspace_name"
  tmux set-environment -t "$session" DEVIDE_TMUX_SESSION "$session"
  tmux set-environment -t "$session" DEVIDE_TERMINAL_MCP_URL "${LOCAL_URL}/api/terminals/mcp?workspace_id=${workspace_id}&tmux_session=${session}"
  tmux set-environment -t "$session" DEVIDE_PREVIEW_MCP_URL "${LOCAL_URL}/api/preview/mcp?workspace_id=${workspace_id}&tmux_session=${session}"
  if [[ -n "$tidewave_url" ]]; then
    tmux set-environment -t "$session" DEVIDE_TIDEWAVE_MCP_URL "$tidewave_url"
  else
    tmux set-environment -t "$session" -u DEVIDE_TIDEWAVE_MCP_URL 2>/dev/null || true
  fi
  tmux set-environment -t "$session" DEVIDE_CHECKOUT "$checkout"
  tmux set-environment -t "$session" DEVIDE_AGENT_MCP_HOME "$staging"
  tmux set-environment -t "$session" DEVIDE_SCRIPTS "$scripts"
  tmux set-environment -t "$session" DEVIDE_AGENT_ENV_FILE "$env_sh"
  tmux set-environment -t "$session" PATH "${HOME}/.local/bin:${PATH}"

  log "repaired ${session} (${workspace_name})"
}

resolve_session() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#{session_name}' 2>/dev/null || true
    return 0
  fi

  return 1
}

session="$(resolve_session "${1:-}" || true)"
if [[ -z "$session" ]]; then
  echo "error: no tmux session to repair (pass session name or run inside tmux)" >&2
  exit 1
fi

repair_session "$session"
