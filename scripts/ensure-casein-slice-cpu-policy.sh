#!/usr/bin/env bash
#
# Install the root-level CPU slice policy that keeps the interactive Casein
# viewer responsive while agent batch work runs.
#
# BACKGROUND
#
# scripts/deploy-devbox-release.sh starts each canary with CPUWeight=1000,
# which orders the app against its siblings *inside* system.slice. That covers
# the dominant case: agent panes inherit whichever canary cgroup spawned their
# tmux server and stay there after that unit dies, so most agent load lands in
# system.slice alongside the app.
#
# It does not reach agent work under user.slice (direct SSH sessions, login
# shells), which contends with system.slice at the cgroup root instead. This
# script closes that remaining gap by tilting the root split.
#
# MEASURED FIRST — over a 20s window on a loaded devbox (32 cores):
#
#     system.slice   647% of one core     user.slice   114%
#
#     within system.slice:
#       devbox-manager.service            305%
#       casein-<uuid>.service (INACTIVE)  240%   <- tmux server + opencode
#       devide-<uuid>.service (FAILED)    115%   <- pre-rename orphan cgroup
#       docker.service                    105%
#       containerd.service                105%
#       casein-<uuid>.service (the app)    90%
#
# So user.slice is roughly 15% of total load, not the main competitor. This
# policy is therefore a MODEST lever, deliberately set to a modest value: the
# heavy hitters are all in system.slice, where the per-unit CPUWeight=1000
# already ranks the app above them. Do not expect this file to be the thing
# that fixes a stall — it trims the tail.
#
# Weights, not quotas: on an idle box every slice still gets every core. This
# only decides who yields under contention. 50 is a 2:1 tilt, not starvation —
# interactive SSH stays usable, which matters on a box shared by several devs.
#
# Usage:
#   bash scripts/ensure-casein-slice-cpu-policy.sh
#   bash scripts/ensure-casein-slice-cpu-policy.sh --disable
#   CASEIN_USER_SLICE_CPU_WEIGHT=25 bash scripts/ensure-casein-slice-cpu-policy.sh
#
set -euo pipefail

UNIT_DIR="/etc/systemd/system/user.slice.d"
DROPIN="${UNIT_DIR}/10-casein-cpu-policy.conf"
WEIGHT="${CASEIN_USER_SLICE_CPU_WEIGHT:-50}"

DISABLE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disable) DISABLE=1; shift ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

if [[ "$DISABLE" -eq 1 ]]; then
  log "removing ${DROPIN}"
  sudo rm -f "$DROPIN"
  sudo rmdir "$UNIT_DIR" 2>/dev/null || true
  sudo systemctl daemon-reload
  # daemon-reload alone does not re-apply cgroup attributes for a slice that
  # no longer carries the property; reset it explicitly back to the default.
  sudo systemctl set-property user.slice CPUWeight=100 || true
  log "user.slice CPUWeight reset to default (100)"
  log "current: $(cat /sys/fs/cgroup/user.slice/cpu.weight 2>/dev/null)"
  exit 0
fi

if ! [[ "$WEIGHT" =~ ^[0-9]+$ ]] || [[ "$WEIGHT" -lt 1 ]] || [[ "$WEIGHT" -gt 10000 ]]; then
  echo "error: CASEIN_USER_SLICE_CPU_WEIGHT must be 1-10000; got ${WEIGHT}" >&2
  exit 1
fi

log "installing ${DROPIN} (user.slice CPUWeight=${WEIGHT})"
sudo mkdir -p "$UNIT_DIR"
sudo tee "$DROPIN" >/dev/null <<EOF
# Managed by scripts/ensure-casein-slice-cpu-policy.sh — do not edit by hand.
#
# Tilts the cgroup-root split so the interactive Casein viewer in system.slice
# is not scheduled behind agent batch work in user.slice. A weight, not a
# quota: an idle box is unaffected. See the script header for the measurement
# that motivates the value.
[Slice]
CPUWeight=${WEIGHT}
EOF

sudo systemctl daemon-reload
# The drop-in alone does not push the attribute onto an already-running slice.
sudo systemctl set-property user.slice "CPUWeight=${WEIGHT}"

log "effective: user.slice cpu.weight=$(cat /sys/fs/cgroup/user.slice/cpu.weight 2>/dev/null)"
log "           system.slice cpu.weight=$(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null)"
log "revert with: bash scripts/ensure-casein-slice-cpu-policy.sh --disable"
