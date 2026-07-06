#!/usr/bin/env bash
#
# Install + enable the daily DevIDE stale worktree alarm sweep.
# Idempotent; installs units from this checkout so the timer is repo-owned.
#
# Usage:
#   bash scripts/ensure-devide-worktree-alarm-sweep.sh
#   bash scripts/ensure-devide-worktree-alarm-sweep.sh --no-start
#   bash scripts/ensure-devide-worktree-alarm-sweep.sh --disable
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="devide-worktree-alarm-sweep.service"
TIMER="devide-worktree-alarm-sweep.timer"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"

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

ensure_env_policy() {
  if ! sudo test -f "$ENV_FILE"; then
    log "warning: ${ENV_FILE} missing; skipping TTL env policy"
    return
  fi

  local backup
  backup="${ENV_FILE}.worktree-alarm.$(date -u +%Y%m%d%H%M%S)"
  log "setting worktree alarm TTL in ${ENV_FILE} (backup=${backup})"
  sudo cp -a "$ENV_FILE" "$backup"
  sudo chmod 600 "$backup"

  sudo awk '
    BEGIN { seen_ttl = 0 }
    /^DEVIDE_WORKTREE_ALARM_TTL_SECONDS=/ {
      print "DEVIDE_WORKTREE_ALARM_TTL_SECONDS=86400"
      seen_ttl = 1
      next
    }
    { print }
    END {
      if (!seen_ttl) print "DEVIDE_WORKTREE_ALARM_TTL_SECONDS=86400"
    }
  ' "$backup" | sudo tee "$ENV_FILE" >/dev/null
  sudo chmod 600 "$ENV_FILE"
}

if [[ "$DISABLE" -eq 1 ]]; then
  log "stopping and disabling ${TIMER}"
  sudo systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
  sudo systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  sudo rm -f "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}"
  sudo systemctl daemon-reload
  log "removed worktree alarm timer units"
  exit 0
fi

ensure_env_policy
chmod 0755 "${ROOT}/scripts/devide-worktree-alarm-sweep.sh"

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

log "run once now: sudo systemctl start ${SERVICE}"