#!/usr/bin/env bash
#
# Install + enable the daily Casein ephemeral /tmp cleanup timer, which runs
# scripts/casein-tmp-cleanup.sh to age-prune credo-diff snapshots, ghostty
# diagnostic dumps, and leaked ExUnit test-artifact roots. `/tmp` is not a
# separate mount on the devbox, so this keeps ephemera off the small root disk.
# Idempotent; installs units from this checkout so the timer is repo-owned.
#
# Rollout is dry-run-first: by default the installed service is LOG-ONLY. Watch
# a cycle (journalctl -u casein-tmp-cleanup.service), then re-run with --apply to
# arm real deletion. Age filtering keeps anything recently in use.
#
# Usage:
#   bash scripts/ensure-casein-tmp-cleanup.sh                 # dry-run (log only)
#   bash scripts/ensure-casein-tmp-cleanup.sh --apply         # arm deletion
#   bash scripts/ensure-casein-tmp-cleanup.sh --user devbox   # run-as user
#   bash scripts/ensure-casein-tmp-cleanup.sh --no-start
#   bash scripts/ensure-casein-tmp-cleanup.sh --disable
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="casein-tmp-cleanup.service"
TIMER="casein-tmp-cleanup.timer"

APPLY=0
START=1
DISABLE=0
RUN_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --no-start) START=0; shift ;;
    --disable) DISABLE=1; shift ;;
    --user) RUN_USER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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
  log "removed tmp-cleanup timer units"
  exit 0
fi

# Run as the owner of the temp root (or $SUDO_USER) so removals happen with the
# same identity that created the ephemera.
if [[ -z "$RUN_USER" ]]; then
  RUN_USER="$(stat -c '%U' "${TMPDIR:-/tmp}" 2>/dev/null || true)"
  [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]] && RUN_USER="${SUDO_USER:-$RUN_USER}"
fi
if [[ -z "$RUN_USER" ]]; then
  echo "error: could not determine run-as user; pass --user <name>" >&2
  exit 1
fi

if [[ "$APPLY" -eq 1 ]]; then
  CLEANUP_ARGS="--apply"
  log "install mode: APPLY (timer will delete aged ephemera)"
else
  CLEANUP_ARGS=""
  log "install mode: DRY-RUN (timer logs only; re-run with --apply to arm deletion)"
fi

chmod 0755 "${ROOT}/scripts/casein-tmp-cleanup.sh"

MAINT_ROOT="${CASEIN_MAINTENANCE_ROOT:-/opt/casein/maintenance}"
log "staging tmp-cleanup script to ${MAINT_ROOT}"
sudo mkdir -p "${MAINT_ROOT}/scripts"
sudo install -m 0755 -o root -g root \
  "${ROOT}/scripts/casein-tmp-cleanup.sh" \
  "${MAINT_ROOT}/scripts/casein-tmp-cleanup.sh"

for f in "$SERVICE" "$TIMER"; do
  src="${ROOT}/scripts/${f}"
  [ -f "$src" ] || { echo "error: missing ${src}" >&2; exit 1; }
  log "installing ${f} (ExecStart root=${MAINT_ROOT} user=${RUN_USER})"
  sed -e "s#__CHECKOUT__#${MAINT_ROOT}#g" \
      -e "s#__USER__#${RUN_USER}#g" \
      -e "s#__CLEANUP_ARGS__#${CLEANUP_ARGS}#g" \
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
  log "installed + enabled (not started) — start with: sudo systemctl start ${TIMER}"
fi

log "run once now: sudo systemctl start ${SERVICE}"
log "watch a cycle: journalctl -u ${SERVICE} -n 60 --no-pager"
