#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
TOKEN="${DEV_IDE_API_TOKEN:-}"
WORKSPACE_ID="${1:-${WORKSPACE_ID:-${DEVIDE_WORKSPACE_ID:-}}}"
WORKSPACE_TERMINAL_ID="${WORKSPACE_TERMINAL_ID:-${DEVIDE_WORKSPACE_NAME:-$WORKSPACE_ID}}"
OUT_ROOT="${WORKSPACE_DOCTOR_OUT:-tmp/workspace-doctor}"

usage() {
  cat <<'EOF'
Usage: scripts/workspace-doctor.sh <workspace_id>

Collects a read-only diagnostic bundle for a workspace:
  - deploy handoff status
  - workspace status/topology/audit API payloads
  - terminal MCP sessions for the workspace
  - matching local tmux sessions/panes when tmux is available

Environment:
  DEVIDE_URL           Base URL (default http://127.0.0.1:4000)
  DEV_IDE_API_TOKEN    Bearer token
  WORKSPACE_ID         Default workspace id when argv is omitted
  WORKSPACE_DOCTOR_OUT Output root (default tmp/workspace-doctor)
EOF
}

if [[ "${WORKSPACE_ID}" == "-h" || "${WORKSPACE_ID}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${WORKSPACE_ID}" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: DEV_IDE_API_TOKEN is not set" >&2
  exit 1
fi

# shellcheck source=scripts/devide-curl.sh
source "${ROOT}/scripts/devide-curl.sh"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
safe_ws="$(printf '%s' "${WORKSPACE_ID}" | tr -c 'A-Za-z0-9_.-' '_')"
out_dir="${OUT_ROOT}/${safe_ws}-${ts}"
mkdir -p "${out_dir}"

auth_header=( -H "authorization: Bearer ${TOKEN}" -H "content-type: application/json" )

write_json() {
  local path="$1"
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.dumps(json.loads(raw), indent=2, sort_keys=True))
except Exception:
    sys.stdout.write(raw)
' >"${path}"
}

api_get() {
  local path="$1"
  devide_curl -fsS "${auth_header[@]}" "${DEVIDE_URL}${path}"
}

terminal_rpc() {
  local id="$1"
  local method="$2"
  local params="{}"
  if [[ $# -ge 3 && -n "${3:-}" ]]; then
    params="$3"
  fi
  local body
  printf -v body '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}' "$id" "$method" "$params"

  devide_curl -fsS -X POST "${DEVIDE_URL}/api/terminals/mcp" \
    "${auth_header[@]}" \
    -d "${body}"
}

echo "==> collecting workspace diagnostics for ${WORKSPACE_ID}"
echo "    output: ${out_dir}"

{
  printf 'workspace_id=%s\n' "${WORKSPACE_ID}"
  printf 'workspace_terminal_id=%s\n' "${WORKSPACE_TERMINAL_ID}"
  printf 'devide_url=%s\n' "${DEVIDE_URL}"
  printf 'collected_at=%s\n' "${ts}"
  git rev-parse HEAD 2>/dev/null | sed 's/^/checkout_revision=/'
} >"${out_dir}/summary.env"

api_get "/api/deploy_status" | write_json "${out_dir}/deploy_status.json" || true
api_get "/api/workspaces/${WORKSPACE_ID}/status" | write_json "${out_dir}/workspace_status.json" || true
api_get "/api/workspaces/${WORKSPACE_ID}/topology" | write_json "${out_dir}/workspace_topology.json" || true
api_get "/api/workspaces/${WORKSPACE_ID}/audit?limit=50" | write_json "${out_dir}/audit_tail.json" || true

terminal_rpc 1 tools/call \
  "{\"name\":\"terminal_list_sessions\",\"arguments\":{\"workspace_id\":\"${WORKSPACE_TERMINAL_ID}\"}}" \
  | write_json "${out_dir}/terminal_sessions.json" || true

if command -v tmux >/dev/null 2>&1; then
  tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}' \
    | WORKSPACE_ID="${WORKSPACE_ID}" WORKSPACE_TERMINAL_ID="${WORKSPACE_TERMINAL_ID}" python3 -c '
import os, sys
prefixes = [
    f"devide_{os.environ['WORKSPACE_ID']}_",
    f"devide_{os.environ['WORKSPACE_TERMINAL_ID']}_",
]
for line in sys.stdin:
    if any(line.startswith(prefix) for prefix in prefixes):
        sys.stdout.write(line)
' \
    >"${out_dir}/tmux_sessions.txt" 2>/dev/null || true

  while read -r session _rest; do
    [[ -n "${session:-}" ]] || continue
    tmux list-panes -t "${session}" -a \
      -F '#{session_name} #{window_index}.#{pane_index} #{pane_id} #{pane_active} #{pane_current_command} #{pane_current_path}' \
      >>"${out_dir}/tmux_panes.txt" 2>/dev/null || true
  done <"${out_dir}/tmux_sessions.txt"
fi

echo "==> workspace doctor bundle written: ${out_dir}"
