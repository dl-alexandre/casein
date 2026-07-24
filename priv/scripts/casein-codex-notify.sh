#!/usr/bin/env bash
# casein-codex-notify.sh — Codex `notify` hook that reports turn completion to
# DevIDE's terminal MCP endpoint.
#
# Injected by the DevIDE launcher as a per-launch config override
# (`-c notify=["…/casein-codex-notify.sh"]`). Codex invokes the program with a
# JSON payload as the last argument; the only documented type is
# "agent-turn-complete", which maps to the semantic state `done` with the
# turn's last assistant message attached. Codex has no turn-start notify event;
# the `working` edge comes from DevIDE itself when terminal_send_agent_command
# dispatches into the pane.
#
# Fire-and-forget like casein-agent-state.sh: missing environment, unmapped
# payloads, and network failures all exit 0 so Codex is never blocked.

set -u

trap 'exit 0' ERR

TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${DEVIDE_WORKSPACE_ID:-}"
MCP_URL="${DEVIDE_TERMINAL_MCP_URL:-}"
PANE="${TMUX_PANE:-}"

[[ -n "$TOKEN" && -n "$WORKSPACE_ID" && -n "$MCP_URL" && -n "$PANE" ]] || exit 0

# Codex passes the notification JSON as the final argv entry.
[[ $# -ge 1 ]] || exit 0
NOTIFICATION="${!#}"

arguments="$(
  CODEX_NOTIFICATION="$NOTIFICATION" \
    DEVIDE_WORKSPACE_ID="$WORKSPACE_ID" \
    AGENT_PANE="$PANE" \
    python3 - <<'PY' 2>/dev/null || true
import json, os

try:
    data = json.loads(os.environ.get("CODEX_NOTIFICATION") or "{}")
except Exception:
    data = {}

if data.get("type") != "agent-turn-complete":
    raise SystemExit(0)

args = {
    "workspace_id": os.environ["DEVIDE_WORKSPACE_ID"],
    "state": "done",
    "pane": os.environ["AGENT_PANE"],
    "source": "hook",
}
message = " ".join(str(data.get("last-assistant-message") or "").split())[:200]
if message:
    args["message"] = message
print(json.dumps(args))
PY
)"

[[ -n "$arguments" ]] || exit 0

body="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"terminal_report_agent_state\",\"arguments\":${arguments}}}"

curl --max-time 3 -sS -o /dev/null -X POST "$MCP_URL" \
  -H "authorization: Bearer ${TOKEN}" \
  -H "content-type: application/json" \
  -d "$body" 2>/dev/null || true

exit 0
