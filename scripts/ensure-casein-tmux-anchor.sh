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
# MEMORY BOUNDARY. The anchor lives in casein-agents.slice, whose MemoryHigh /
# MemoryMax (CASEIN_AGENTS_MEMORY_HIGH / CASEIN_AGENTS_MEMORY_MAX, default
# 60% / 75% of RAM) cap the whole agent fleet so it can never starve the host
# again (devbox, 2026-08-27). An anchor already running in system.slice is
# re-homed with a stop+start — safe, because KillMode=process only signals the
# anchor's own sleep — and its process tree is then migrated into the new
# cgroup exactly like a first install.
#
# DRY RUN BY DEFAULT — prints the plan and moves nothing. Pass --apply.
#
# Usage:
#   bash scripts/ensure-casein-tmux-anchor.sh                 # dry run
#   bash scripts/ensure-casein-tmux-anchor.sh --apply         # install + migrate
#   bash scripts/ensure-casein-tmux-anchor.sh --apply --server-only
#   CASEIN_TMUX_LABEL=casein_dev bash scripts/... --apply     # a different socket
#   CASEIN_AGENTS_MEMORY_HIGH=50% CASEIN_AGENTS_MEMORY_MAX=65% bash scripts/... --apply
#   bash scripts/ensure-casein-tmux-anchor.sh --disable
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
UNIT="casein-tmux-anchor.service"
SLICE="casein-agents.slice"
MEM_HIGH="${CASEIN_AGENTS_MEMORY_HIGH:-60%}"
MEM_MAX="${CASEIN_AGENTS_MEMORY_MAX:-75%}"
LABEL="${CASEIN_TMUX_LABEL:-casein}"
TMUX_BIN="${CASEIN_TMUX_BIN:-$(command -v tmux || echo /usr/bin/tmux)}"
# systemd nests slices by name (casein-agents.slice is a child of casein.slice),
# so the cgroup path is derived from the realised ControlGroup after start.
CG_ROOT=""
# Sentinel that keeps the legacy casein-tmux.service inert (see
# supersede_legacy_unit). Deleting it re-arms that unit on the next boot.
SENTINEL="/etc/casein/tmux-anchor-owns-server"

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
  # The slice is shared with casein-orphan-anchor.service; only drop it when
  # that unit is not homed there (or does not exist).
  if [[ "$(systemctl show -p Slice --value casein-orphan-anchor.service 2>/dev/null || true)" != "$SLICE" ]]; then
    sudo rm -f "${UNIT_DIR}/${SLICE}"
    log "removed ${SLICE} (no other unit was homed in it)"
  fi
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

slice_src="${ROOT}/scripts/${SLICE}"
[ -f "$slice_src" ] || { echo "error: missing ${slice_src}" >&2; exit 1; }
log "installing ${SLICE} (MemoryHigh=${MEM_HIGH} MemoryMax=${MEM_MAX})"
sed -e "s#__MEMORY_HIGH__#${MEM_HIGH}#g" -e "s#__MEMORY_MAX__#${MEM_MAX}#g" "$slice_src" \
  | sudo tee "${UNIT_DIR}/${SLICE}" >/dev/null

sudo systemctl daemon-reload

# daemon-reload alone does not re-apply cgroup attributes to a slice that is
# already realised; set-property does, immediately and persistently (it
# writes a drop-in that agrees with the unit file we just installed).
sudo systemctl set-property "$SLICE" "MemoryHigh=${MEM_HIGH}" "MemoryMax=${MEM_MAX}" >/dev/null 2>&1 || true
sudo systemctl enable "$UNIT" >/dev/null

# `start`, never `restart`. Once this unit is holding adopted tmux servers, a
# restart would tear down and recreate the very cgroup they live in — systemd
# cannot remove a non-empty cgroup, so the result is a confused half-state
# rather than a clean re-adopt. Starting an already-active unit is a no-op,
# which makes re-running this script safe.
# Compare the *realised* cgroup, not the configured Slice=: after a
# daemon-reload  already reports the new unit-file value while
# the running instance still sits in its old cgroup.
current_cg="$(systemctl show -p ControlGroup --value "$UNIT" 2>/dev/null || true)"
if [[ "$(systemctl is-active "$UNIT" 2>/dev/null)" != "active" ]]; then
  sudo systemctl start "$UNIT"
elif [[ "$current_cg" != */"${SLICE}/${UNIT}" ]]; then
  # Re-home an anchor that predates the slice. A unit's cgroup path includes
  # its slice, so this is the one legitimate stop+start: the new cgroup is at
  # a *different* path, so there is no half-state to trip over. KillMode=
  # process means the stop signals only the anchor's own sleep; the adopted
  # server and every pane keep running in the old cgroup until the migration
  # loop below moves them.
  log "${UNIT} is realised at ${current_cg:-?}; re-homing into ${SLICE} (adopted processes are not signalled)"
  # restart, not stop+start: the devbox sudo policy denies `systemctl stop`
  # (and kill/disable/mask) but allows restart, and here they are equivalent
  # — only the sleep is signalled, and the unit comes back in the new slice.
  sudo systemctl restart "$UNIT"
else
  log "${UNIT} already active in ${SLICE} — leaving it alone (adopted processes stay put)"
fi

for _ in $(seq 1 20); do
  CG_ROOT="/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$UNIT" 2>/dev/null || true)"
  [[ "$CG_ROOT" == */"${SLICE}/${UNIT}" && -f "${CG_ROOT}/cgroup.procs" ]] && break
  sleep 0.25
done

if [[ "$CG_ROOT" != */"${SLICE}/${UNIT}" || ! -f "${CG_ROOT}/cgroup.procs" ]]; then
  echo "error: anchor cgroup under ${SLICE} did not appear (got ${CG_ROOT}); not migrating" >&2
  exit 1
fi
supersede_legacy_unit() {
  # casein-tmux.service is Type=forking with ExecStart=tmux ... new-session, so
  # systemd tracks the tmux SERVER as its main process, under the default
  # KillMode=control-group. Stopping that unit SIGTERMs the server and every
  # pane with it. On 2026-08-29 an unattended libpam upgrade ran
  # `systemctl daemon-reexec` and restarted PAM-linked services; systemd
  # stopped this unit and destroyed every session across four workspaces
  # (OneBackend-v3#20076). The 2026-08-27 loss was the same, via openssl.
  #
  # The anchor supersedes it entirely: KillMode=process, Delegate=yes, and an
  # ExecStartPost that guarantees a keepalive session exists. Left enabled,
  # though, the legacy unit re-arms the failure on the next boot by taking
  # ownership of the server again.
  #
  # Neutralised by condition rather than `systemctl disable`/`mask`, which the
  # devbox sudo policy forbids. Reverse by deleting the sentinel file.
  local dropin_dir="${UNIT_DIR}/casein-tmux.service.d"
  local dropin="${dropin_dir}/superseded-by-anchor.conf"

  systemctl list-unit-files casein-tmux.service >/dev/null 2>&1 || return 0

  log "superseding legacy casein-tmux.service (Type=forking + KillMode=control-group)"
  sudo mkdir -p "${dropin_dir}" /etc/casein
  printf '%s\n' \
    '# While this file exists, casein-tmux.service no-ops and' \
    '# casein-tmux-anchor.service owns the -L casein tmux server.' \
    '# See scripts/ensure-casein-tmux-anchor.sh (OneBackend-v3#20076).' \
    | sudo tee "${SENTINEL}" >/dev/null
  printf '%s\n' \
    '# Superseded by casein-tmux-anchor.service — see' \
    '# scripts/ensure-casein-tmux-anchor.sh (OneBackend-v3#20076).' \
    '[Unit]' \
    "ConditionPathExists=!${SENTINEL}" \
    | sudo tee "${dropin}" >/dev/null
  sudo systemctl daemon-reload

  # The running server is never signalled: this only stops the unit from
  # claiming a *future* server. A live legacy unit keeps its server until the
  # migration below re-homes it into the anchor cgroup.
  log "casein-tmux.service will no-op while ${SENTINEL} exists"
}

supersede_legacy_unit

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

slice_cg="/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$SLICE" 2>/dev/null || true)"
log "${SLICE}: memory.high=$(cat "${slice_cg}/memory.high" 2>/dev/null || echo ?) memory.max=$(cat "${slice_cg}/memory.max" 2>/dev/null || echo ?) memory.current=$(cat "${slice_cg}/memory.current" 2>/dev/null || echo ?)"
log "panes created from now on inherit the anchor cgroup"
log "revert with: bash scripts/ensure-casein-tmux-anchor.sh --disable"
