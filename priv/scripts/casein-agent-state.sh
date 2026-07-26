#!/usr/bin/env bash
# casein-agent-state.sh — agent-runtime hook that reports the agent's semantic
# state to Casein's terminal MCP endpoint.
#
# Two runtimes wire it in:
#   - Claude Code: via a materialized --settings file (UserPromptSubmit,
#     PreToolUse, Notification, Stop, SessionStart/End). Event name arrives as
#     hook_event_name in the stdin JSON payload.
#   - Grok CLI: a global SessionStart bootstrap reports the native session and
#     private leader metadata; ACP then activates the session capability bundle.
#
# It is fire-and-forget: any missing environment, unmapped event, or network
# failure exits 0 so the agent is never blocked or slowed. It never writes to
# stdout (hook stdout may be interpreted by the runtime); diagnostics go to
# stderr.

set -u

# Never let an error in here surface to the agent.
trap 'exit 0' ERR

TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${CASEIN_WORKSPACE_ID:-}"
MCP_URL="${CASEIN_TERMINAL_MCP_URL:-}"
PANE="${TMUX_PANE:-}"

# Without credentials, a target pane, or an endpoint there is nothing to do.
[[ -n "$TOKEN" && -n "$WORKSPACE_ID" && -n "$MCP_URL" && -n "$PANE" ]] || exit 0

payload="$(cat 2>/dev/null || true)"

# Parse event name (line 1), single-line message (line 2), transcript path
# (line 3), and runtime session id (line 4) from the hook JSON. Claude uses
# snake_case; Grok's hook envelope is camelCase. Grok's runner also exports the
# event name as GROK_HOOK_EVENT.
parsed="$(
  HOOK_PAYLOAD="$payload" python3 - <<'PY' 2>/dev/null || true
import json, os

try:
    data = json.loads(os.environ.get("HOOK_PAYLOAD") or "{}")
except Exception:
    data = {}

print(str(data.get("hook_event_name") or data.get("hookEventName") or ""))
print(" ".join(str(data.get("message") or "").split())[:200])
print(str(data.get("transcript_path") or data.get("transcriptPath") or ""))
print(str(data.get("session_id") or data.get("sessionId") or ""))
PY
)"

EVENT="$(printf '%s\n' "$parsed" | sed -n 1p)"
MESSAGE="$(printf '%s\n' "$parsed" | sed -n 2p)"
TRANSCRIPT_PATH="$(printf '%s\n' "$parsed" | sed -n 3p)"
AGENT_SESSION_ID="$(printf '%s\n' "$parsed" | sed -n 4p)"

# Grok's runner env is authoritative when present (values are snake_case).
EVENT="${GROK_HOOK_EVENT:-$EVENT}"

case "$EVENT" in
  UserPromptSubmit | PreToolUse | user_prompt_submit | pre_tool_use) STATE="working" ;;
  Notification | notification) STATE="blocked" ;;
  # Grok fires stop_failure when a turn dies on an API error — the agent is
  # stuck and needs attention, which is what blocked signals downstream.
  stop_failure) STATE="blocked" ;;
  Stop | stop) STATE="done" ;;
  SessionStart | SessionEnd | session_start | session_end) STATE="idle" ;;
  *) exit 0 ;;
esac

# Debounce: skip a repeated `working` report within 30s (PreToolUse fires
# constantly). blocked/done/idle are low-frequency and always sent.
CACHE_DIR="${CASEIN_AGENT_MCP_HOME:-${TMPDIR:-/tmp}}"
CACHE_FILE="${CACHE_DIR}/.casein-agent-state.${PANE//[^A-Za-z0-9_]/_}"
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
  CASEIN_WORKSPACE_ID="$WORKSPACE_ID" \
    AGENT_STATE="$STATE" \
    AGENT_PANE="$PANE" \
    AGENT_MESSAGE="$MESSAGE" \
    AGENT_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
    AGENT_SESSION_ID="$AGENT_SESSION_ID" \
    python3 - <<'PY' 2>/dev/null || true
import json, os
args = {
    "workspace_id": os.environ["CASEIN_WORKSPACE_ID"],
    "state": os.environ["AGENT_STATE"],
    "pane": os.environ["AGENT_PANE"],
    "source": "hook",
}
agent_runtime = os.environ.get("CASEIN_AGENT_LAUNCH_CONTEXT") or ""
if agent_runtime:
    args["agent_runtime"] = agent_runtime
message = os.environ.get("AGENT_MESSAGE") or ""
if message:
    args["message"] = message
transcript_path = os.environ.get("AGENT_TRANSCRIPT_PATH") or ""
if transcript_path:
    args["transcript_path"] = transcript_path
agent_session_id = os.environ.get("AGENT_SESSION_ID") or ""
if agent_session_id:
    args["agent_session_id"] = agent_session_id
if agent_runtime == "grok" or os.environ.get("GROK_HOOK_EVENT"):
    for env_name, key in [
        ("CASEIN_GROK_LEADER_SOCKET", "grok_leader_socket"),
        ("CASEIN_GROK_BUNDLE_DIR", "grok_bundle_dir"),
        ("CASEIN_GROK_BUNDLE_DIGEST", "grok_bundle_digest"),
    ]:
        value = os.environ.get(env_name) or ""
        if value:
            args[key] = value
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
