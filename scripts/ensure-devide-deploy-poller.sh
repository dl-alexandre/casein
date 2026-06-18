#!/usr/bin/env bash
#
# Install + enable the on-box auto-deploy poller (devide-deploy.timer/.service).
# This is the self-hosted replacement for the GitHub Actions deploy job while
# Actions is billing-blocked: it polls origin/master and auto-deploys when it
# advances (see scripts/deploy-poller.sh).
#
# Idempotent — safe to re-run. Substitutes this checkout's path into the unit
# files before installing, so it works regardless of where the checkout lives.
#
# Usage:
#   bash scripts/ensure-devide-deploy-poller.sh            # install + enable + start timer
#   bash scripts/ensure-devide-deploy-poller.sh --no-start # install + enable, don't start now
#   bash scripts/ensure-devide-deploy-poller.sh --disable  # stop + disable + remove units
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="devide-deploy.service"
TIMER="devide-deploy.timer"

START=1
DISABLE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START=0; shift ;;
    --disable) DISABLE=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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
  log "removed deploy poller units"
  exit 0
fi

for f in "$SERVICE" "$TIMER"; do
  src="${ROOT}/scripts/${f}"
  [ -f "$src" ] || { echo "error: missing ${src}" >&2; exit 1; }
  log "installing ${f} (checkout=${ROOT})"
  # Substitute the real checkout path for the __CHECKOUT__ placeholder.
  sed "s#__CHECKOUT__#${ROOT}#g" "$src" | sudo tee "${UNIT_DIR}/${f}" >/dev/null
done

sudo systemctl daemon-reload
log "enabling ${TIMER}"
sudo systemctl enable "$TIMER" >/dev/null

if [[ "$START" -eq 1 ]]; then
  log "starting ${TIMER}"
  sudo systemctl start "$TIMER"
  log "deploy poller active — next tick within ~2 min"
  systemctl list-timers "$TIMER" --no-pager 2>/dev/null | tail -n +1 || true
else
  log "installed + enabled (not started) — start with: sudo systemctl start ${TIMER}"
fi

log "logs: journalctl -u ${SERVICE} -f     |     run once now: sudo systemctl start ${SERVICE}"
