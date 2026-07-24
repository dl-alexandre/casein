#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAIN_SOCKET="${DEVIDE_CURRENT_SOCK:-/run/casein/current.sock}"
DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${WORKSPACE_ID:-${DEVIDE_WORKSPACE_ID:-}}"
TMUX_SESSION="${TMUX_SESSION:-${DEVIDE_TMUX_SESSION:-}}"
PREVIEW_OPEN="${VERIFY_PREVIEW_OPEN:-0}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

log "main socket health (${MAIN_SOCKET})"
main_status="$(
  curl -sS --max-time 5 --unix-socket "$MAIN_SOCKET" http://localhost/ \
    -o /dev/null \
    -w '%{http_code}'
)"

if [[ "$main_status" == "000" ]]; then
  echo "ERROR: main socket did not return an HTTP response" >&2
  exit 1
fi

log "main socket returned HTTP ${main_status}"

if [[ -x scripts/preview-router.sh ]]; then
  log "preview router status"
  scripts/preview-router.sh status
else
  warn "scripts/preview-router.sh not found"
fi

if [[ -x scripts/preview-env.sh ]]; then
  log "preview registry"
  scripts/preview-env.sh ls

  log "preview registry gc"
  scripts/preview-env.sh gc

  if [[ -x scripts/preview-router.sh ]]; then
    log "preview router reload"
    scripts/preview-router.sh reload
  fi
else
  warn "scripts/preview-env.sh not found"
fi

if [[ -z "$TOKEN" || -z "$WORKSPACE_ID" ]]; then
  log "MCP preview smoke skipped (set CASEIN_API_TOKEN and WORKSPACE_ID)"
  exit 0
fi

# shellcheck source=scripts/devide-curl.sh
source "${ROOT}/scripts/devide-curl.sh"

preview_rpc() {
  local id="$1"
  local method="$2"
  local params="${3-}"
  if [[ -z "$params" ]]; then
    params="{}"
  fi
  devide_curl -fsS -X POST "$DEVIDE_URL/api/preview/mcp" \
    -H "authorization: Bearer $TOKEN" \
    -H "content-type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":${params}}"
}

parse_tool_result() {
  python3 -c '
import json, sys
payload = json.load(sys.stdin)
if "error" in payload:
    raise SystemExit(json.dumps(payload["error"]))
result = payload.get("result") or {}
if result.get("isError"):
    text = ""
    for block in result.get("content") or []:
        text += block.get("text", "")
    raise SystemExit(text or "tool error")
structured = result.get("structuredContent")
print(json.dumps(structured if structured is not None else result))
'
}

log "preview MCP tools/list"
preview_rpc 1 tools/list | grep -q preview_surfaces
preview_rpc 2 tools/list | grep -q preview_open_here
preview_rpc 3 tools/list | grep -q preview_ensure_server_here

log "preview MCP surfaces"
preview_rpc 4 tools/call "{\"name\":\"preview_surfaces\",\"arguments\":{\"workspace_id\":\"$WORKSPACE_ID\"}}" \
  | parse_tool_result >/dev/null

if [[ "$PREVIEW_OPEN" != "1" ]]; then
  log "scoped preview open skipped (set VERIFY_PREVIEW_OPEN=1 and TMUX_SESSION)"
  exit 0
fi

if [[ -z "$TMUX_SESSION" ]]; then
  echo "ERROR: VERIFY_PREVIEW_OPEN=1 requires TMUX_SESSION or DEVIDE_TMUX_SESSION" >&2
  exit 1
fi

log "runtime preview server ensure (${TMUX_SESSION})"
preview_rpc 5 tools/call "{\"name\":\"preview_ensure_server_here\",\"arguments\":{\"workspace_id\":\"$WORKSPACE_ID\",\"tmux_session\":\"$TMUX_SESSION\"}}" \
  | parse_tool_result >/dev/null

log "runtime preview open here (${TMUX_SESSION})"
open_payload="$(
  preview_rpc 6 tools/call "{\"name\":\"preview_open_here\",\"arguments\":{\"workspace_id\":\"$WORKSPACE_ID\",\"tmux_session\":\"$TMUX_SESSION\"}}" \
    | parse_tool_result
)"

printf '%s' "$open_payload" | python3 -c '
import json, sys
data = json.load(sys.stdin)
placement = data.get("placement") or {}
if placement.get("placement") != "beside_agent":
    raise SystemExit(f"preview not placed beside agent: {placement}")
if data.get("preview_open_state") == "not_visible":
    print("WARN: preview opened but browser visibility is not confirmed", file=sys.stderr)
'

log "preview boundary smoke complete"
