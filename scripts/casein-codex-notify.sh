#!/usr/bin/env bash
# Codex lifecycle/notify receiver. Command hooks send JSON on stdin; the legacy
# notify program sends JSON as its final argv value. Both paths post to DevIDE's
# authenticated, workspace-scoped Codex event endpoint and never block Codex.

set -u
trap 'exit 0' ERR

TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${DEVIDE_WORKSPACE_ID:-}"
PANE="${TMUX_PANE:-}"
TMUX_SESSION="${DEVIDE_TMUX_SESSION:-}"
TRANSPORT="hook"

[[ -n "$TOKEN" && -n "$WORKSPACE_ID" ]] || exit 0

if [[ $# -ge 1 ]]; then
  PAYLOAD="${!#}"
  TRANSPORT="notify"
else
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

[[ -n "$PAYLOAD" ]] || exit 0

HOOK_URL="${DEVIDE_CODEX_HOOK_URL:-}"
if [[ -z "$HOOK_URL" && -n "${DEVIDE_API_BASE_URL:-}" ]]; then
  HOOK_URL="${DEVIDE_API_BASE_URL%/}/api/workspaces/${WORKSPACE_ID}/codex/hooks"
fi
if [[ -z "$HOOK_URL" && -n "${DEVIDE_TERMINAL_MCP_URL:-}" ]]; then
  API_BASE="${DEVIDE_TERMINAL_MCP_URL%%/api/terminals/mcp*}"
  HOOK_URL="${API_BASE}/api/workspaces/${WORKSPACE_ID}/codex/hooks"
fi
[[ -n "$HOOK_URL" ]] || exit 0

BODY="$(
  CODEX_HOOK_PAYLOAD="$PAYLOAD" \
    CODEX_HOOK_TRANSPORT="$TRANSPORT" \
    CODEX_HOOK_PANE="$PANE" \
    CODEX_HOOK_TMUX_SESSION="$TMUX_SESSION" \
    python3 - <<'PY' 2>/dev/null || true
import json, os

try:
    event = json.loads(os.environ.get("CODEX_HOOK_PAYLOAD") or "{}")
except Exception:
    raise SystemExit(0)

if not isinstance(event, dict):
    raise SystemExit(0)

body = {
    "event": event,
    "transport": os.environ.get("CODEX_HOOK_TRANSPORT") or "hook",
}
pane = os.environ.get("CODEX_HOOK_PANE")
tmux_session = os.environ.get("CODEX_HOOK_TMUX_SESSION")
if pane:
    body["pane"] = pane
if tmux_session:
    body["tmux_session"] = tmux_session
print(json.dumps(body, separators=(",", ":")))
PY
)"

[[ -n "$BODY" ]] || exit 0

curl --max-time 3 -sS -o /dev/null -X POST "$HOOK_URL" \
  -H "authorization: Bearer ${TOKEN}" \
  -H "content-type: application/json" \
  -d "$BODY" 2>/dev/null || true

exit 0
