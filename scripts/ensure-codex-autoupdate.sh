#!/usr/bin/env bash
#
# Install + enable the daily Codex CLI autoupdate timer.
# Idempotent; installs units from this checkout so the timer is repo-owned.
#
# Usage:
#   bash scripts/ensure-codex-autoupdate.sh
#   bash scripts/ensure-codex-autoupdate.sh --no-start
#   bash scripts/ensure-codex-autoupdate.sh --disable
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="codex-autoupdate.service"
TIMER="codex-autoupdate.timer"
INSTALL_USER="${CASEIN_CODEX_AUTOUPDATE_USER:-${SUDO_USER:-$(id -un)}}"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
NPM_BIN="${CASEIN_NPM_BIN:-$(command -v npm || true)}"

START=1
DISABLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START=0; shift ;;
    --disable) DISABLE=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
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
  log "removed codex autoupdate timer units"
  exit 0
fi

if [[ -z "$INSTALL_HOME" ]]; then
  echo "error: could not resolve home directory for ${INSTALL_USER}" >&2
  exit 1
fi

if [[ -z "$NPM_BIN" ]]; then
  echo "error: npm not found on PATH; set CASEIN_NPM_BIN=/path/to/npm" >&2
  exit 1
fi

for f in "$SERVICE" "$TIMER"; do
  src="${ROOT}/scripts/${f}"
  [ -f "$src" ] || { echo "error: missing ${src}" >&2; exit 1; }
  log "installing ${f} (checkout=${ROOT}, user=${INSTALL_USER})"
  sed \
    -e "s#__CHECKOUT__#${ROOT}#g" \
    -e "s#__USER__#${INSTALL_USER}#g" \
    -e "s#__HOME__#${INSTALL_HOME}#g" \
    -e "s#__NPM__#${NPM_BIN}#g" \
    "$src" | sudo tee "${UNIT_DIR}/${f}" >/dev/null
done

sudo systemctl daemon-reload
log "enabling ${TIMER}"
sudo systemctl enable "$TIMER" >/dev/null

if [[ "$START" -eq 1 ]]; then
  log "starting ${TIMER}"
  sudo systemctl start "$TIMER"
  systemctl list-timers "$TIMER" --no-pager 2>/dev/null | tail -n +1 || true
else
  log "installed + enabled (not started) - start with: sudo systemctl start ${TIMER}"
fi

log "run once now: sudo systemctl start ${SERVICE}"
