#!/usr/bin/env bash
#
# Install the deploy-independent tmux cgroup anchor and migrate the running
# tmux server (plus its existing process tree) into it.
#
# See scripts/casein-tmux-anchor.service for why the anchor exists. Short
# version: tmux servers inherit the cgroup of whatever first ran a tmux
# command — the live canary — and stay there after that canary is replaced,
# so the server and every pane it spawns end up in the cgroup of a dead unit.
#
# MIGRATION IS NON-DESTRUCTIVE. Moving a process between cgroups is a write to
# cgroup.procs; no signal is sent and the process does not notice. Verified on
# a live server: 5 sessions intact across the move, and panes created
# afterwards were born in the anchor cgroup.
#
# DRY RUN BY DEFAULT — prints the plan and moves nothing. Pass --apply.
#
# Usage:
#   bash scripts/ensure-casein-tmux-anchor.sh                 # dry run
#   bash scripts/ensure-casein-tmux-anchor.sh --apply         # install + migrate
#   bash scripts/ensure-casein-tmux-anchor.sh --apply --server-only
#   CASEIN_TMUX_LABEL=casein_dev bash scripts/... --apply     # a different socket
#   bash scripts/ensure-casein-tmux-anchor.sh --disable
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
UNIT="casein-tmux-anchor.service"
LABEL="${CASEIN_TMUX_LABEL:-casein}"
TMUX_BIN="${CASEIN_TMUX_BIN:-$(command -v tmux || echo /usr/bin/tmux)}"
CG_ROOT="/sys/fs/cgroup/system.slice/${UNIT}"

APPLY=0
SERVER_ONLY=0
DISABLE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --server-only) SERVER_ONLY=1; shift ;;
    --disable) DISABLE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

if [[ "$DISABLE" -eq 1 ]]; then
  # Stopping is safe by construction: KillMode=process means only the anchor's
  # own sleep is signalled. Adopted processes keep running; they simply end up
  # in the parent slice's cgroup again.
  log "stopping and disabling ${UNIT} (adopted tmux server is NOT killed)"
  sudo systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  sudo rm -f "${UNIT_DIR}/${UNIT}"
  sudo systemctl daemon-reload
  log "removed ${UNIT}"
  exit 0
fi

# ── locate the running server ───────────────────────────────────────────────
# `display-message` needs a session to answer, so it cannot find a server that
# is running with zero sessions — exactly the state abandoned test/probe
# servers end up in, and they are the ones most likely to be stranded. Derive
# the conventional socket path as a fallback so those are still reachable.
socket_path="$("$TMUX_BIN" -L "$LABEL" display-message -p '#{socket_path}' 2>/dev/null || true)"

if [[ -z "$socket_path" || ! -S "$socket_path" ]]; then
  socket_path="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/${LABEL}"
fi

server_pid=""
if [[ -S "$socket_path" ]]; then
  server_pid="$(sudo lsof -t "$socket_path" 2>/dev/null | head -1 || true)"
fi

if [[ -z "$server_pid" ]]; then
  log "no running tmux server for -L ${LABEL} (nothing to migrate)"
else
  log "tmux server -L ${LABEL} pid=${server_pid} currently in $(sed 's|0::||' "/proc/${server_pid}/cgroup" 2>/dev/null)"
fi

# Descendants of the server: every pane shell and whatever it spawned.
collect_tree() {
  local queue=("$1") out=() pid kids k
  while [[ "${#queue[@]}" -gt 0 ]]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    out+=("$pid")
    kids="$(pgrep -P "$pid" 2>/dev/null || true)"
    for k in $kids; do queue+=("$k"); done
  done
  printf '%s\n' "${out[@]}"
}

migrate_pids=()
if [[ -n "$server_pid" ]]; then
  if [[ "$SERVER_ONLY" -eq 1 ]]; then
    migrate_pids=("$server_pid")
  else
    mapfile -t migrate_pids < <(collect_tree "$server_pid")
  fi
fi

if [[ "$APPLY" -eq 0 ]]; then
  log "DRY RUN — would install ${UNIT} and migrate ${#migrate_pids[@]} process(es)"
  if [[ "${#migrate_pids[@]}" -gt 0 ]]; then
    log "source cgroups that would be vacated:"
    for pid in "${migrate_pids[@]}"; do
      sed 's|0::||' "/proc/${pid}/cgroup" 2>/dev/null || true
    done | sort | uniq -c | sort -rn | sed 's/^/      /'
  fi
  log "re-run with --apply"
  exit 0
fi

# ── install + start ─────────────────────────────────────────────────────────
src="${ROOT}/scripts/${UNIT}"
[ -f "$src" ] || { echo "error: missing ${src}" >&2; exit 1; }
log "installing ${UNIT} (tmux=${TMUX_BIN})"
sed "s#__TMUX_BIN__#${TMUX_BIN}#g" "$src" | sudo tee "${UNIT_DIR}/${UNIT}" >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable "$UNIT" >/dev/null

# `start`, never `restart`. Once this unit is holding adopted tmux servers, a
# restart would tear down and recreate the very cgroup they live in — systemd
# cannot remove a non-empty cgroup, so the result is a confused half-state
# rather than a clean re-adopt. Starting an already-active unit is a no-op,
# which makes re-running this script safe.
if [[ "$(systemctl is-active "$UNIT" 2>/dev/null)" != "active" ]]; then
  sudo systemctl start "$UNIT"
else
  log "${UNIT} already active — leaving it alone (adopted processes stay put)"
fi

for _ in $(seq 1 20); do
  [[ -f "${CG_ROOT}/cgroup.procs" ]] && break
  sleep 0.25
done

if [[ ! -f "${CG_ROOT}/cgroup.procs" ]]; then
  echo "error: anchor cgroup ${CG_ROOT} did not appear; not migrating" >&2
  exit 1
fi
log "anchor cgroup ready: ${CG_ROOT}"

# ── migrate ─────────────────────────────────────────────────────────────────
moved=0
failed=0
for pid in "${migrate_pids[@]}"; do
  [[ -d "/proc/${pid}" ]] || continue
  if echo "$pid" | sudo tee "${CG_ROOT}/cgroup.procs" >/dev/null 2>&1; then
    moved=$((moved + 1))
  else
    # Kernel threads, exited pids, and processes in an incompatible cgroup
    # tree are expected to refuse; the server itself is what matters.
    failed=$((failed + 1))
  fi
done

log "migrated ${moved} process(es) into the anchor (${failed} refused)"

if [[ -n "$server_pid" && -d "/proc/${server_pid}" ]]; then
  log "tmux server now in $(sed 's|0::||' "/proc/${server_pid}/cgroup" 2>/dev/null)"
  sessions="$("$TMUX_BIN" -L "$LABEL" list-sessions 2>/dev/null | wc -l)"
  log "tmux server alive with ${sessions} session(s)"
else
  echo "error: tmux server pid ${server_pid} is gone after migration" >&2
  exit 1
fi

log "panes created from now on inherit the anchor cgroup"
log "revert with: bash scripts/ensure-casein-tmux-anchor.sh --disable"
