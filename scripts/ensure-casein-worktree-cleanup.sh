#!/usr/bin/env bash
#
# Install + enable the daily Casein agent-worktree cleanup timer, which runs
# scripts/cleanup-agent-worktrees.sh to remove leftover worktrees that are
# idle + clean + fully pushed (dirty/live/unpushed/current are always kept).
# Idempotent; installs units from this checkout so the timer is repo-owned.
#
# Scripts are installed to a DURABLE path (default /opt/casein/maintenance),
# never left pointing at an agent worktree checkout that can be reaped. Units
# ExecStart that path. Re-running after a deploy refreshes the installed copy.
#
# Rollout is dry-run-first: by default the installed service is LOG-ONLY. Watch
# a cycle (journalctl -u casein-worktree-cleanup.service), then re-run with
# --apply to arm real deletion.
#
# Usage:
#   bash scripts/ensure-casein-worktree-cleanup.sh                 # dry-run (log only)
#   bash scripts/ensure-casein-worktree-cleanup.sh --apply         # arm deletion
#   bash scripts/ensure-casein-worktree-cleanup.sh --user devbox   # run-as user
#   bash scripts/ensure-casein-worktree-cleanup.sh --no-start
#   bash scripts/ensure-casein-worktree-cleanup.sh --disable
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
SERVICE="casein-worktree-cleanup.service"
TIMER="casein-worktree-cleanup.timer"
WT_ROOT="${CASEIN_AGENT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/casein-agent-worktrees}"
# Durable install root — never an agent worktree. deploy-build is also durable
# but maintenance/ is dedicated so janitors survive poller rebuilds of deploy-build.
MAINT_ROOT="${CASEIN_MAINTENANCE_ROOT:-/opt/casein/maintenance}"

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
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
  log "removed worktree-cleanup timer units"
  exit 0
fi

# The service must run as the user that owns the tmux server, or the liveness
# probe fails and the script refuses to delete. Default to the owner of the
# worktree root, then $SUDO_USER.
if [[ -z "$RUN_USER" ]]; then
  RUN_USER="$(stat -c '%U' "$WT_ROOT" 2>/dev/null || true)"
  [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]] && RUN_USER="${SUDO_USER:-$RUN_USER}"
fi
if [[ -z "$RUN_USER" ]]; then
  echo "error: could not determine run-as user; pass --user <name>" >&2
  exit 1
fi

if [[ "$APPLY" -eq 1 ]]; then
  CLEANUP_ARGS="--apply"
  log "install mode: APPLY (timer will delete clean+idle+pushed worktrees)"
else
  CLEANUP_ARGS=""
  log "install mode: DRY-RUN (timer logs only; re-run with --apply to arm deletion)"
fi

chmod 0755 "${ROOT}/scripts/cleanup-agent-worktrees.sh"

# Stage script into durable maintenance root so units never point at a
# reaped agent worktree (or a transient deploy-build tree mid-rebuild).
log "staging cleanup script to ${MAINT_ROOT}"
sudo mkdir -p "${MAINT_ROOT}/scripts"
sudo install -m 0755 -o root -g root \
  "${ROOT}/scripts/cleanup-agent-worktrees.sh" \
  "${MAINT_ROOT}/scripts/cleanup-agent-worktrees.sh"

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
