#!/usr/bin/env bash
# devide-agent-state.sh — Claude Code hook that reports the agent's semantic
# state to DevIDE's terminal MCP endpoint.
#
# Installed by the DevIDE launcher via a materialized --settings file; wired to
# the UserPromptSubmit, PreToolUse, Notification, Stop, and SessionStart/End
# hook events. Reads the hook JSON payload on stdin, maps the event to a
# semantic state, and fires a best-effort MCP report.
#
# It is fire-and-forget: any missing environment, unmapped event, or network
# failure exits 0 so the agent is never blocked or slowed. It never writes to
# stdout (Claude Code may interpret hook stdout); diagnostics go to stderr.

set -u

# Never let an error in here surface to the agent.
trap 'exit 0' ERR

TOKEN="${DEV_IDE_API_TOKEN:-}"
WORKSPACE_ID="${DEVIDE_WORKSPACE_ID:-}"
MCP_URL="${DEVIDE_TERMINAL_MCP_URL:-}"
PANE="${TMUX_PANE:-}"

# Without credentials, a target pane, or an endpoint there is nothing to do.
[[ -n "$TOKEN" && -n "$WORKSPACE_ID" && -n "$MCP_URL" && -n "$PANE" ]] || exit 0

payload="$(cat 2>/dev/null || true)"

# Parse event name (line 1), single-line message (line 2), and transcript_path
# (line 3) from the hook JSON. Claude includes transcript_path on every event.
parsed="$(
  HOOK_PAYLOAD="$payload" python3 - <<'PY' 2>/dev/null || true
import json, os

try:
    data = json.loads(os.environ.get("HOOK_PAYLOAD") or "{}")
except Exception:
    data = {}

print(str(data.get("hook_event_name") or ""))
print(" ".join(str(data.get("message") or "").split())[:200])
print(str(data.get("transcript_path") or ""))
PY
)"

EVENT="$(printf '%s\n' "$parsed" | sed -n 1p)"
MESSAGE="$(printf '%s\n' "$parsed" | sed -n 2p)"
TRANSCRIPT_PATH="$(printf '%s\n' "$parsed" | sed -n 3p)"

case "$EVENT" in
  UserPromptSubmit | PreToolUse) STATE="working" ;;
  Notification) STATE="blocked" ;;
  Stop) STATE="done" ;;
  SessionStart | SessionEnd) STATE="idle" ;;
  *) exit 0 ;;
esac

# Debounce: skip a repeated `working` report within 30s (PreToolUse fires
# constantly). blocked/done/idle are low-frequency and always sent.
CACHE_DIR="${DEVIDE_AGENT_MCP_HOME:-${TMPDIR:-/tmp}}"
CACHE_FILE="${CACHE_DIR}/.devide-agent-state.${PANE//[^A-Za-z0-9_]/_}"
NOW="$(date +%s 2>/dev/null || echo 0)"

if [[ "$STATE" == "working" && -r "$CACHE_FILE" ]]; then
  read -r LAST_STATE LAST_TS <"$CACHE_FILE" 2>/dev/null || true
  if [[ "${LAST_STATE:-}" == "working" ]]; then
    delta=$((NOW - ${LAST_TS:-0}))
    if [[ "$delta" -ge 0 && "$delta" -lt 30 ]]; then
      exit 0
    fi
  fi
fi

printf '%s %s\n' "$STATE" "$NOW" >"$CACHE_FILE" 2>/dev/null || true

arguments="$(
  DEVIDE_WORKSPACE_ID="$WORKSPACE_ID" \
    AGENT_STATE="$STATE" \
    AGENT_PANE="$PANE" \
    AGENT_MESSAGE="$MESSAGE" \
    AGENT_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
    python3 - <<'PY' 2>/dev/null || true
import json, os
args = {
    "workspace_id": os.environ["DEVIDE_WORKSPACE_ID"],
    "state": os.environ["AGENT_STATE"],
    "pane": os.environ["AGENT_PANE"],
    "source": "hook",
}
message = os.environ.get("AGENT_MESSAGE") or ""
if message:
    args["message"] = message
transcript_path = os.environ.get("AGENT_TRANSCRIPT_PATH") or ""
if transcript_path:
    args["transcript_path"] = transcript_path
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
