#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${WORKSPACE_ID:-${DEVIDE_WORKSPACE_ID:-dev_ide}}"
WORKSPACE_NAME="${DEVIDE_WORKSPACE_NAME:-}"
CI_MODE=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: verify_agent_pairing.sh [--ci]

Verifies Terminal + Preview MCP endpoints for agent pairing.

Environment:
  DEVIDE_URL          Base URL (default http://localhost:4000)
  CASEIN_API_TOKEN   Bearer token (required)
  WORKSPACE_ID        Workspace UUID or name (default dev_ide)
  VERIFY_ROUNDTRIP=1  Also send a harmless echo in the first session (optional)

  --ci                Strict mode: warnings fail the script (for deploy gates)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

warn() {
  WARNINGS=$((WARNINGS + 1))
  echo "WARN: $*" >&2
  if [[ "$CI_MODE" -eq 1 ]]; then
    echo "ERROR: --ci treats warnings as failures" >&2
    exit 1
  fi
}

# Non-fatal advisory: prints but never fails --ci. For optional/degraded
# capabilities that do not make a deploy unhealthy — notably checks that are
# checkout-relative (this script runs from the checkout, where priv/scripts has
# no node_modules) while the real artifact lives in the deployed release tree.
note() {
  echo "NOTE: $*" >&2
}

echo "==> Casein agent pairing verification"
echo "    URL:         $DEVIDE_URL"
echo "    workspace:   $WORKSPACE_ID"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: CASEIN_API_TOKEN is not set" >&2
  exit 1
fi

if ! bash -c 'code="$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "'"${DEVIDE_URL}"'/" 2>/dev/null || echo 000)"; [[ "${code}" != "000" && -n "${code}" ]]'; then
  if [[ -x "${ROOT}/scripts/ensure-casein-loopback-proxy.sh" ]]; then
    echo "==> loopback ${DEVIDE_URL} down — starting casein-loopback proxy"
    bash "${ROOT}/scripts/ensure-casein-loopback-proxy.sh"
  fi
fi

# shellcheck source=scripts/casein-curl.sh
source "${ROOT}/scripts/casein-curl.sh"

auth_header=( -H "authorization: Bearer $TOKEN" -H "content-type: application/json" )

rpc() {
  local id="$1"
  local method="$2"
  local params="${3-}"
  if [[ -z "$params" ]]; then
    params="{}"
  fi
  devide_curl -fsS -X POST "$DEVIDE_URL/api/terminals/mcp" \
    "${auth_header[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":${params}}"
}

preview_rpc() {
  local id="$1"
  local method="$2"
  local params="${3-}"
  if [[ -z "$params" ]]; then
    params="{}"
  fi
  devide_curl -fsS -X POST "$DEVIDE_URL/api/preview/mcp" \
    "${auth_header[@]}" \
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
if structured is not None:
    print(json.dumps(structured))
else:
    print(json.dumps(result))
'
}

list_sessions_for() {
  local ws_id="$1"
  rpc 3 tools/call "{\"name\":\"terminal_list_sessions\",\"arguments\":{\"workspace_id\":\"$ws_id\"}}" \
    | parse_tool_result
}

pick_session_name() {
  local workspace_key="${1:-}"
  PICK_WORKSPACE_KEY="$workspace_key" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
sessions = data.get("sessions") or []
key = os.environ.get("PICK_WORKSPACE_KEY", "")
if key:
    prefix = f"devide_{key}_"
    for row in sessions:
        name = row.get("session") or row.get("name") or ""
        if name.startswith(prefix):
            print(name)
            raise SystemExit(0)
if sessions:
    first = sessions[0]
    print(first.get("session") or first.get("name") or "")
else:
    print("")
'
}

echo "==> terminal MCP initialize"
rpc 1 initialize '{"protocolVersion":"2025-03-26"}' | grep -q '"protocolVersion"'

echo "==> terminal MCP tools/list"
rpc 2 tools/list | grep -q terminal_list_sessions

echo "==> terminal MCP list sessions for workspace $WORKSPACE_ID"
active_workspace_id="$WORKSPACE_ID"
list_json="$(list_sessions_for "$WORKSPACE_ID")"

session_name="$(
  PICK_WORKSPACE_KEY="${WORKSPACE_NAME:-$WORKSPACE_ID}" \
    printf '%s' "$list_json" | pick_session_name "${WORKSPACE_NAME:-$WORKSPACE_ID}"
)"

if [[ -z "$session_name" ]]; then
  echo "==> no tmux sessions for workspace $WORKSPACE_ID — topology/capture skipped (open workspace UI first)"
else
  echo "==> terminal MCP topology ($session_name)"
  topo_json="$(
    rpc 4 tools/call "{\"name\":\"terminal_topology\",\"arguments\":{\"workspace_id\":\"$active_workspace_id\",\"session\":\"$session_name\"}}" \
      | parse_tool_result
  )"
  printf '%s' "$topo_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
panes = data.get("panes") or []
if not panes:
    for window in data.get("windows") or []:
        panes.extend(window.get("pane_list") or [])
if not panes:
    raise SystemExit("topology missing panes")
'

  pane_id="$(
    printf '%s' "$topo_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
panes = data.get("panes") or []
if not panes:
    for window in data.get("windows") or []:
        panes.extend(window.get("pane_list") or [])
for pane in panes:
    pid = pane.get("id")
    if pid:
        print(pid)
        raise SystemExit(0)
raise SystemExit("no pane id in topology")
'
  )"

  echo "==> terminal MCP capture ($session_name $pane_id)"
  rpc 5 tools/call "{\"name\":\"terminal_capture\",\"arguments\":{\"workspace_id\":\"$active_workspace_id\",\"session\":\"$session_name\",\"pane\":\"$pane_id\",\"lines\":20,\"ansi\":false}}" \
    | parse_tool_result >/dev/null

  if [[ "${VERIFY_ROUNDTRIP:-}" == "1" ]]; then
    marker="devide-verify-$(date +%s)"
    echo "==> terminal MCP roundtrip echo ($marker)"
    rpc 6 tools/call "{\"name\":\"terminal_send_command\",\"arguments\":{\"workspace_id\":\"$active_workspace_id\",\"session\":\"$session_name\",\"pane\":\"$pane_id\",\"command\":\"printf '%s\\\\n' $marker\"}}" \
      | parse_tool_result >/dev/null
    capture_out="$(
      rpc 7 tools/call "{\"name\":\"terminal_capture\",\"arguments\":{\"workspace_id\":\"$active_workspace_id\",\"session\":\"$session_name\",\"pane\":\"$pane_id\",\"lines\":30,\"ansi\":false}}" \
        | parse_tool_result
    )"
    printf '%s' "$capture_out" | python3 -c "
import json, sys
marker = '$marker'
data = json.load(sys.stdin)
text = data.get('output') or ''
if marker not in text:
    raise SystemExit(f'roundtrip marker {marker!r} not found in capture')
"
  fi
fi

echo "==> preview MCP initialize"
preview_rpc 10 initialize '{"protocolVersion":"2025-03-26"}' | grep -q '"protocolVersion"'

echo "==> preview MCP tools/list"
preview_rpc 11 tools/list | grep -q preview_open
preview_rpc 11 tools/list | grep -q preview_open_app
preview_rpc 11 tools/list | grep -q preview_surfaces
preview_rpc 11 tools/list | grep -q preview_navigate
preview_rpc 11 tools/list | grep -q preview_open_localhost

if [[ -f priv/scripts/preview_playwright.mjs ]]; then
  if [[ -d priv/scripts/node_modules/playwright ]]; then
    echo "==> Playwright helper: installed"
  else
    # Checkout-relative: the deployed release installs Playwright into its own
    # priv/scripts (deploy-devbox-release.sh). A missing copy *here* in the
    # checkout does not mean preview screenshot/click is broken on the release,
    # so this is advisory, not a deploy-failing condition.
    note "Playwright npm deps not in this checkout (the deployed release installs its own); preview screenshot/click run from the release tree"
  fi
else
  warn "preview_playwright.mjs not found"
fi

if [[ "$WARNINGS" -gt 0 && "$CI_MODE" -eq 0 ]]; then
  echo "OK: agent pairing endpoints reachable ($WARNINGS warning(s))"
else
  echo "OK: agent pairing endpoints reachable"
fi
