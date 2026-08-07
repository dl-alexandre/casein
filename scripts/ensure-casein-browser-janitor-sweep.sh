#!/usr/bin/env bash
#
# Install + enable the hourly Casein orphaned agent-browser Chrome sweep.
# Idempotent; installs units from this checkout so the timer is repo-owned.
#
# Usage:
#   bash scripts/ensure-casein-browser-janitor-sweep.sh
#   bash scripts/ensure-casein-browser-janitor-sweep.sh --no-start
#   bash scripts/ensure-casein-browser-janitor-sweep.sh --disable
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="casein-browser-janitor-sweep.service"
TIMER="casein-browser-janitor-sweep.timer"

START=1
DISABLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START=0; shift ;;
    --disable) DISABLE=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

if [[ "$DISABLE" -eq 1 ]]; then
  log "stopping and disabling ${TIMER}"
  sudo systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
  sudo systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  sudo rm -f "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}"
  sudo systemctl daemon-reload
  log "removed browser janitor timer units"
  exit 0
fi

chmod 0755 "${ROOT}/scripts/casein-browser-janitor-sweep.sh"

for f in "$SERVICE" "$TIMER"; do
  src="${ROOT}/scripts/${f}"
  [ -f "$src" ] || { echo "error: missing ${src}" >&2; exit 1; }
  log "installing ${f} (checkout=${ROOT})"
  sed "s#__CHECKOUT__#${ROOT}#g" "$src" | sudo tee "${UNIT_DIR}/${f}" >/dev/null
done

sudo systemctl daemon-reload
log "enabling ${TIMER}"
sudo systemctl enable "$TIMER" >/dev/null

if [[ "$START" -eq 1 ]]; then
  log "starting ${TIMER}"
  sudo systemctl start "$TIMER"
  systemctl list-timers "$TIMER" --no-pager 2>/dev/null | tail -n +1 || true
else
  log "installed + enabled (not started) — start with: sudo systemctl start ${TIMER}"
fi

log "dry-run: scripts/casein-browser-janitor-sweep.sh --dry-run"
log "run once now: sudo systemctl start ${SERVICE}"
