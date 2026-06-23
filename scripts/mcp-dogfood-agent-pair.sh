#!/usr/bin/env bash
# MCP side-by-side dogfood: apply agent_pair, then agent-pane send/capture.
# Writes raw JSON-RPC transcript lines to SCRATCH/mcp-raw-transcript.jsonl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/grok-goal-1bbe809758a7/implementer}"
ENV_FILE="${DEVBOX_AGENT_ENV:-${ROOT}/.devbox-agent.env}"

mkdir -p "$SCRATCH"
TRANSCRIPT="${SCRATCH}/mcp-raw-transcript.jsonl"
: >"$TRANSCRIPT"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
TOKEN="${DEV_IDE_API_TOKEN:-}"
WS_ID="${DEVIDE_WORKSPACE_ID:-}"
ADMIN_TOKEN="${DEV_IDE_ADMIN_API_TOKEN:-$TOKEN}"

if [[ -z "$TOKEN" || -z "$WS_ID" ]]; then
  echo "ERROR: DEV_IDE_API_TOKEN and DEVIDE_WORKSPACE_ID required" >&2
  exit 1
fi

# shellcheck source=scripts/devide-curl.sh
source "${ROOT}/scripts/devide-curl.sh"

auth_header=( -H "authorization: Bearer $TOKEN" -H "content-type: application/json" )
admin_header=( -H "authorization: Bearer $ADMIN_TOKEN" -H "content-type: application/json" )

rpc_raw() {
  local id="$1"
  local params="$2"
  devide_curl -fsS -X POST "$DEVIDE_URL/api/terminals/mcp" \
    "${auth_header[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"tools/call\",\"params\":${params}}"
}

save_step() {
  local label="$1"
  shift
  printf '%s\n' "$*" | python3 -c "
import json, sys
label = sys.argv[1]
raw = sys.stdin.read()
payload = json.loads(raw)
print(json.dumps({'step': label, 'response': payload}))
" "$label" >>"$TRANSCRIPT"
  printf '%s\n' "$*"
}

pick_session() {
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
outer = data.get("result") or {}
structured = outer.get("structuredContent") or {}
sessions = structured.get("sessions") or []
for row in sessions:
    name = row.get("session") or ""
    if name:
        print(name)
        raise SystemExit(0)
raise SystemExit("no sessions")
'
}

MARKER="agent-pair-dogfood-$(date +%s)"
echo "==> MCP dogfood (agent_pair) marker=$MARKER"

list_json="$(save_step list_sessions "$(rpc_raw 1 "{\"name\":\"terminal_list_sessions\",\"arguments\":{\"workspace_id\":\"$WS_ID\"}}")")"
SESSION="$(printf '%s' "$list_json" | pick_session)"
echo "==> session: $SESSION"

echo "==> apply agent_pair template (REST)"
apply_out="$(
  devide_curl -fsS -X POST \
    "${DEVIDE_URL}/api/workspaces/${WS_ID}/templates/agent_pair/apply?session=${SESSION}" \
    "${admin_header[@]}"
)"
printf '%s\n' "$apply_out" | python3 -c "
import json, sys
print(json.dumps({'step': 'apply_agent_pair', 'response': json.loads(sys.stdin.read())}))
" >>"$TRANSCRIPT"

AGENT_PANE="$(printf '%s' "$apply_out" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('refs', {}).get('pane:work:agent', ''))
")"
echo "==> agent pane from template refs: $AGENT_PANE"

topo_json="$(save_step topology "$(rpc_raw 2 "{\"name\":\"terminal_topology\",\"arguments\":{\"workspace_id\":\"$WS_ID\",\"session\":\"$SESSION\"}}")")"

agent_json="$(save_step agent_pane "$(rpc_raw 3 "{\"name\":\"terminal_agent_pane\",\"arguments\":{\"workspace_id\":\"$WS_ID\",\"session\":\"$SESSION\"}}")")"

MCP_AGENT_PANE="$(printf '%s' "$agent_json" | python3 -c "
import json, sys
outer = json.loads(sys.stdin.read())
structured = (outer.get('result') or {}).get('structuredContent') or {}
print(structured.get('pane', ''))
")"
echo "==> terminal_agent_pane: $MCP_AGENT_PANE (reason: agent_pair_marker expected)"

send_json="$(save_step send_agent_command "$(rpc_raw 4 "{\"name\":\"terminal_send_agent_command\",\"arguments\":{\"workspace_id\":\"$WS_ID\",\"session\":\"$SESSION\",\"command\":\"printf '%s\\\\n' $MARKER\"}}")")"

sleep 2

capture_json="$(save_step capture_agent "$(rpc_raw 5 "{\"name\":\"terminal_capture_agent\",\"arguments\":{\"workspace_id\":\"$WS_ID\",\"session\":\"$SESSION\",\"ansi\":false}}")")"

printf '%s' "$capture_json" | python3 -c "
import json, sys
marker = '$MARKER'
outer = json.loads(sys.stdin.read())
structured = (outer.get('result') or {}).get('structuredContent') or {}
text = structured.get('output') or ''
if marker not in text:
    raise SystemExit(f'marker {marker!r} not in capture_agent output')
print('OK: marker in terminal_capture_agent')
print('MARKER:', marker)
print('AGENT_PANE:', structured.get('target', '$MCP_AGENT_PANE'))
"

printf '%s\n' "$MARKER" >"${SCRATCH}/mcp-dogfood-marker.txt"
echo "==> transcript: $TRANSCRIPT"
echo "EXIT:0"