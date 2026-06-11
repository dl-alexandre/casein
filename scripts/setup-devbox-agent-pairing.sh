#!/usr/bin/env bash
#
# One-shot local devbox setup for human+agent side-by-side DevIDE work.
# Builds the current checkout, deploys to the local systemd release, pins
# workspace mode, ensures Playwright, and writes .devbox-agent.env.
#
# Run on the devbox host from the dev_ide checkout:
#   bash scripts/setup-devbox-agent-pairing.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
SERVICE="${DEV_IDE_SYSTEMD_SERVICE:-devide}"
WORKSPACE_NAME="${DEV_IDE_WORKSPACE_NAME:-dalexandre-devide}"
AGENT_ENV="${ROOT}/.devbox-agent.env"

log() { printf '>>> %s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker required to build release" >&2
  exit 1
fi

if ! sudo test -f "$ENV_FILE"; then
  echo "error: missing $ENV_FILE — run devbox first-deploy first" >&2
  exit 1
fi

TOKEN="$(sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "$ENV_FILE" | tail -n 1)"
if [[ -z "$TOKEN" ]]; then
  echo "error: DEV_IDE_API_TOKEN missing from $ENV_FILE" >&2
  exit 1
fi

log "building release from $(git rev-parse --short HEAD 2>/dev/null || echo checkout)"
./scripts/build-release.sh

TARBALL="/tmp/dev_ide-release-$(date +%s).tgz"
tar -C release-out -czf "$TARBALL" .
log "deploying $TARBALL"
bash scripts/deploy-devbox-release.sh "$TARBALL" "$(git rev-parse --short HEAD 2>/dev/null || echo local)"

log "resolving workspace id for ${WORKSPACE_NAME}"
WORKSPACE_ID="$(
  curl -fsS -H "authorization: Bearer ${TOKEN}" http://127.0.0.1:4000/api/workspaces |
    WORKSPACE_NAME="$WORKSPACE_NAME" python3 -c "
import json, sys, os
name = os.environ['WORKSPACE_NAME']
for w in json.load(sys.stdin):
    if w.get('name') == name:
        print(w['id'])
        break
"
)"

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "error: workspace ${WORKSPACE_NAME} not found in manager list" >&2
  exit 1
fi

log "setting workspace mode to manual for raw terminal (${WORKSPACE_ID})"
DB_URL="$(sudo awk -F= '/^DATABASE_URL=/{print $2}' "$ENV_FILE" | tail -n 1)"
if [[ -n "$DB_URL" ]] && command -v psql >/dev/null 2>&1; then
  # ecto://user:pass@host:port/db → psql connection pieces
  DB_USER="$(printf '%s' "$DB_URL" | sed -n 's|ecto://\([^:]*\):.*|\1|p')"
  DB_PASS="$(printf '%s' "$DB_URL" | sed -n 's|ecto://[^:]*:\([^@]*\)@.*|\1|p')"
  DB_HOST="$(printf '%s' "$DB_URL" | sed -n 's|.*@\([^:]*\):.*|\1|p')"
  DB_PORT="$(printf '%s' "$DB_URL" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')"
  DB_NAME="$(printf '%s' "$DB_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')"
  PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "UPDATE workspace_records SET mode='manual' WHERE external_id='${WORKSPACE_ID}';"
else
  log "warn: could not set workspace mode automatically (psql/DATABASE_URL missing)"
fi

scripts_dir="$(
  find /opt/devide/release/lib -maxdepth 4 -type d -path '*/priv/scripts' -print -quit 2>/dev/null
)"

if [[ -n "$scripts_dir" ]] && [[ -f "${scripts_dir}/node_modules/playwright/cli.js" ]]; then
  log "ensuring Playwright Chromium for devbox user"
  (
    cd "$scripts_dir"
    sudo -u devbox env HOME=/home/devbox \
      node node_modules/playwright/cli.js install chromium
  )
fi

PUBLIC_URL="https://devide.devbox.milcgroup.com"
LOCAL_URL="http://127.0.0.1:4000"

cat >"$AGENT_ENV" <<EOF
# DevIDE devbox agent pairing — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source before starting an external agent:  source .devbox-agent.env

export DEV_IDE_API_TOKEN='${TOKEN}'
export DEVIDE_URL='${LOCAL_URL}'
export DEVIDE_PUBLIC_URL='${PUBLIC_URL}'
export DEVIDE_WORKSPACE_ID='${WORKSPACE_ID}'
export DEVIDE_WORKSPACE_NAME='${WORKSPACE_NAME}'
export DEVIDE_TERMINAL_MCP_URL='${PUBLIC_URL}/api/terminals/mcp'
export DEVIDE_PREVIEW_MCP_URL='${PUBLIC_URL}/api/preview/mcp'
export DEVIDE_CHECKOUT='${ROOT}'
export DEVIDE_AGENT_MCP_HOME="\${HOME}/.devide/agent-mcp/${WORKSPACE_NAME}"
EOF
chmod 600 "$AGENT_ENV"

log "wrote ${AGENT_ENV}"

log "materializing per-workspace MCP client configs (Grok/Claude/Codex/OpenCode)"
# shellcheck source=/dev/null
source "${AGENT_ENV}"
bash scripts/materialize-agent-mcp.sh

log "verifying MCP endpoints"
DEVIDE_URL="$LOCAL_URL" DEV_IDE_API_TOKEN="$TOKEN" \
  WORKSPACE_ID="$WORKSPACE_ID" DEVIDE_WORKSPACE_NAME="$WORKSPACE_NAME" \
  bash scripts/verify_agent_pairing.sh

log "done"
log "Open: ${PUBLIC_URL}/workspaces/${WORKSPACE_ID}"
log "Agents tab → Apply Agent Pair layout, then start your external agent with:"
log "  source ${AGENT_ENV}"
log "  bash scripts/launch-devide-agent.sh grok   # or codex | claude | opencode"
