#!/usr/bin/env bash
#
# casein-adopt-stranded.sh — move processes out of dead deploy cgroups.
#
# Each deploy starts the release in a transient `casein-<uuid>.service`. Its
# children inherit that cgroup, and `KillMode=process` means they survive the
# unit being replaced — so after a few deploys the box accumulates cgroups
# belonging to inactive or failed units that are still full of running work.
#
# scripts/casein-tmux-anchor.service prevents this for the tmux server (and
# therefore every pane). This script is the general remediation for everything
# else a canary spawns: workspace dev servers, agent-browser launchers, grok
# sandboxes, language servers.
#
# THESE PROCESSES ARE USUALLY NOT ABANDONED. Measured on the devbox: of 96
# stranded processes, nine held listening sockets — two workspace dev servers
# on 0.0.0.0:4003 and 0.0.0.0:4010, a local probe, and the agent-browser
# launchers supervising live headless-Chrome trees. So this script MOVES and
# never kills. "No supervising parent" is a good abandonment signal for a
# self-contained browser tree; it is a terrible one here, because a detached
# dev server legitimately has no parent and still serves traffic.
#
# SAFETY:
#   - Only cgroups of `casein-*`/`devide-*` units that are NOT active are
#     considered. The live canary is skipped by definition, and re-checked by
#     name as a belt-and-braces guard.
#   - Migration is a write to cgroup.procs: no signal is sent, and the process
#     does not observe the move.
#   - Nothing is killed, ever. Reaping stranded work is a separate decision
#     that needs a human looking at what is actually listening.
#
# DRY RUN BY DEFAULT — prints the plan and moves nothing. Pass --apply.
#
# Usage:
#   scripts/casein-adopt-stranded.sh            # dry run
#   scripts/casein-adopt-stranded.sh --apply
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="/etc/systemd/system"
UNIT="casein-orphan-anchor.service"
# The orphan anchor lives in casein-agents.slice (memory-bounded; see
# scripts/casein-agents.slice), so its cgroup is under that slice.
CG_ROOT="/sys/fs/cgroup/casein-agents.slice/${UNIT}"
SLICE="/sys/fs/cgroup/system.slice"

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

# Units that are currently running must never be drained.
mapfile -t live_units < <(
  systemctl list-units --type=service --state=running --no-legend 2>/dev/null |
    awk '{print $1}'
)

is_live() {
  local u="$1" l
  for l in "${live_units[@]}"; do [[ "$u" == "$l" ]] && return 0; done
  return 1
}

declare -a stranded_dirs=()
total=0

for d in "${SLICE}"/casein-*.service "${SLICE}"/devide-*.service; do
  [[ -d "$d" ]] || continue
  unit="$(basename "$d")"

  # Never drain the anchors themselves.
  [[ "$unit" == "$UNIT" ]] && continue
  [[ "$unit" == "casein-tmux-anchor.service" ]] && continue

  if is_live "$unit"; then
    log "SKIP  ${unit} (unit is running)"
    continue
  fi

  # Second guard: ask systemd directly rather than trusting the list above.
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ "$state" == "active" || "$state" == "activating" ]]; then
    log "SKIP  ${unit} (is-active=${state})"
    continue
  fi

  n="$(wc -l <"${d}/cgroup.procs" 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] || continue

  stranded_dirs+=("$d")
  total=$((total + n))
  log "FOUND ${unit} (is-active=${state:-unknown}) holding ${n} process(es)"
done

if [[ "${#stranded_dirs[@]}" -eq 0 ]]; then
  log "no stranded processes in dead deploy cgroups"
  exit 0
fi

if [[ "$APPLY" -eq 0 ]]; then
  log "DRY RUN — would migrate ${total} process(es) from ${#stranded_dirs[@]} dead cgroup(s)"
  log "processes that hold listening sockets (proof they are live, not debris):"
  for d in "${stranded_dirs[@]}"; do
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      if sudo ss -tlnp 2>/dev/null | grep -q "pid=${pid},"; then
        log "      pid=${pid} $(ps -o comm= -p "$pid" 2>/dev/null) $(sudo ss -tlnp 2>/dev/null | grep "pid=${pid}," | awk '{print $4}' | tr '\n' ' ')"
      fi
    done <"${d}/cgroup.procs"
  done
  log "re-run with --apply"
  exit 0
fi

# ── install the anchor ──────────────────────────────────────────────────────
src="${ROOT}/scripts/${UNIT}"
[[ -f "$src" ]] || { echo "error: missing ${src}" >&2; exit 1; }
log "installing ${UNIT}"
sudo cp "$src" "${UNIT_DIR}/${UNIT}"
sudo systemctl daemon-reload
sudo systemctl enable "$UNIT" >/dev/null

# `start`, never `restart` — a restart would tear down a cgroup that may
# already hold adopted processes, and systemd cannot remove a non-empty one.
# Compare the *realised* cgroup, not the configured Slice=: after a
# daemon-reload  already reports the new unit-file value while
# the running instance still sits in its old cgroup.
current_cg="$(systemctl show -p ControlGroup --value "$UNIT" 2>/dev/null || true)"
if [[ "$(systemctl is-active "$UNIT" 2>/dev/null)" != "active" ]]; then
  sudo systemctl start "$UNIT"
elif [[ "$current_cg" != "/casein-agents.slice/${UNIT}" ]]; then
  # Re-home an anchor that predates casein-agents.slice. Safe for the same
  # reason as in ensure-casein-tmux-anchor.sh: KillMode=process signals only
  # the anchor's own sleep, and the new cgroup is at a different path. Anything
  # adopted earlier stays alive in the old cgroup; the loop below re-adopts it
  # only if it is still stranded in a *dead* deploy cgroup, so re-run
  # ensure-casein-tmux-anchor.sh --apply afterwards to sweep the rest.
  log "${UNIT} is realised at ${current_cg:-?}; re-homing into casein-agents.slice (adopted processes are not signalled)"
  sudo systemctl stop "$UNIT"
  sudo systemctl start "$UNIT"
else
  log "${UNIT} already active in casein-agents.slice — leaving it alone"
fi

for _ in $(seq 1 20); do
  [[ -f "${CG_ROOT}/cgroup.procs" ]] && break
  sleep 0.25
done
[[ -f "${CG_ROOT}/cgroup.procs" ]] || { echo "error: anchor cgroup missing" >&2; exit 1; }

# ── migrate ─────────────────────────────────────────────────────────────────
moved=0
refused=0

# Snapshot the pid list before migrating, and repeat until it stops shrinking.
#
# Streaming `while read < cgroup.procs` while writing pids out of that same
# file silently skips entries: the kernel regenerates the file's contents on
# each read as processes leave, so the reader's offset lands past rows it
# never saw. It looked like the writes were being refused when in fact most
# were never attempted. Snapshot, then loop to a fixed point.
for d in "${stranded_dirs[@]}"; do
  for _pass in 1 2 3; do
    [[ -r "${d}/cgroup.procs" ]] || break
    mapfile -t pids <"${d}/cgroup.procs"
    [[ "${#pids[@]}" -gt 0 ]] || break

    before_pass="${#pids[@]}"
    for pid in "${pids[@]}"; do
      [[ -n "$pid" && -d "/proc/${pid}" ]] || continue
      if echo "$pid" | sudo tee "${CG_ROOT}/cgroup.procs" >/dev/null 2>&1; then
        moved=$((moved + 1))
      else
        refused=$((refused + 1))
      fi
    done

    [[ -r "${d}/cgroup.procs" ]] || break
    after_pass="$(wc -l <"${d}/cgroup.procs")"
    [[ "$after_pass" -eq 0 || "$after_pass" -eq "$before_pass" ]] && break
  done
done

log "migrated ${moved} process(es) (${refused} refused)"

for d in "${stranded_dirs[@]}"; do
  # A fully drained cgroup is removed by systemd, so the file is gone — that
  # is the success case, not an error. Check before reading or the shell
  # prints its own redirect failure regardless of any 2>/dev/null.
  if [[ -r "${d}/cgroup.procs" ]]; then
    log "  $(basename "$d"): $(wc -l <"${d}/cgroup.procs") left"
  else
    log "  $(basename "$d"): drained (cgroup removed)"
  fi
done

log "nothing was killed — reaping stranded work is a separate, human decision"
