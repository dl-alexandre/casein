#!/usr/bin/env bash
#
# Materialize priv/preview_demo into the workspace and serve it on localhost.
# Used by the agent_preview_demo tmux template (Agents tab).
#
# Usage (from workspace checkout root):
#   bash scripts/run-preview-demo.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_DIR="${CASEIN_PREVIEW_DEMO_DIR:-${ROOT}/.casein/preview-demo}"
DEMO_PORT="${CASEIN_PREVIEW_DEMO_PORT:-5173}"
SRC="${ROOT}/priv/preview_demo"

if [[ ! -d "${SRC}" ]]; then
  echo "error: ${SRC} not found — run from the Casein checkout" >&2
  exit 1
fi

mkdir -p "${DEMO_DIR}"
cp -R "${SRC}/." "${DEMO_DIR}/"

cd "${DEMO_DIR}"

cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  Casein Preview Demo                                         ║
║  http://127.0.0.1:${DEMO_PORT}/                               ║
╠══════════════════════════════════════════════════════════════╣
║  Human: preview panel should open automatically after apply. ║
║  Agent MCP:                                                  ║
║    preview_surfaces(workspace_id)                            ║
║    preview_open_localhost(workspace_id, port: ${DEMO_PORT})   ║
║    preview_observe / preview_screenshot / preview_close      ║
╚══════════════════════════════════════════════════════════════╝

EOF

exec python3 -m http.server "${DEMO_PORT}" --bind 127.0.0.1
