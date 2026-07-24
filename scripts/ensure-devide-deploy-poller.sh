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

SUDOERS_FILE="/etc/sudoers.d/devide-deploy-trigger"

install_poller_trigger_sudoers() {
  log "installing sudoers drop-in for webhook poller trigger (${SUDOERS_FILE})"
  printf '%s\n' \
    'devbox ALL=(root) NOPASSWD: /bin/systemctl start devide-deploy.service' \
    'devbox ALL=(root) NOPASSWD: /usr/bin/install -o devbox -g devbox -m 664 /tmp/last-deploy-*.json /run/casein/last-deploy.json' |
    sudo tee "${SUDOERS_FILE}" >/dev/null
  sudo chmod 440 "${SUDOERS_FILE}"
  sudo visudo -cf "${SUDOERS_FILE}" >/dev/null
}

ensure_last_deploy_status_file() {
  local status_file="/run/casein/last-deploy.json"
  sudo mkdir -p /run/casein
  if [ ! -f "${status_file}" ]; then
    sudo touch "${status_file}"
  fi
  sudo chown devbox:devbox "${status_file}"
  sudo chmod 664 "${status_file}"
}

if [[ "$DISABLE" -eq 1 ]]; then
  log "stopping and disabling ${TIMER}"
  sudo systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
  sudo systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  sudo rm -f "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}" "${SUDOERS_FILE}"
  sudo systemctl daemon-reload
  log "removed deploy poller units and webhook sudoers drop-in"
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
install_poller_trigger_sudoers
ensure_last_deploy_status_file
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
