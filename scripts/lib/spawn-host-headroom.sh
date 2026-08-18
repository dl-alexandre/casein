#!/usr/bin/env bash
#
# spawn-host-headroom.sh — load/memory gate for worker spawn (#863).
#
# ALWAYS_FULL blind spawn waves thrash the box. Consult 1-minute load against
# nproc and MemAvailable before opening a worker window. Decline LOUDLY when
# headroom is gone — a silent no-op is worse than spawning.
#
# Source from spawn-agent-worker.sh:
#   # shellcheck source=spawn-host-headroom.sh
#   source "${ROOT}/scripts/lib/spawn-host-headroom.sh"
#   spawn_host_headroom_check || exit $?
#
# Env:
#   CASEIN_SPAWN_FORCE=1              operator override — spawn anyway (loud warn)
#   CASEIN_SPAWN_MAX_LOAD_RATIO       refuse when load1 > nproc * ratio (default 1.0)
#   CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB refuse when MemAvailable below this (default 2097152 = 2 GiB)
#   CASEIN_SPAWN_LOADAVG_PATH         override /proc/loadavg (tests)
#   CASEIN_SPAWN_MEMINFO_PATH         override /proc/meminfo (tests)
#   CASEIN_SPAWN_NPROC                override core count (tests)
#
# Exit codes from spawn_host_headroom_check:
#   0  enough headroom (or FORCE override)
#   75 temporary failure — load or memory over threshold (EX_TEMPFAIL)
#   2  misconfiguration (bad threshold / unreadable probes)

# shellcheck disable=SC2034  # exported for callers/tests that inspect the last probe
SPAWN_HOST_HEADROOM_LAST=""

spawn_host_headroom_nproc() {
  local n="${CASEIN_SPAWN_NPROC:-}"
  if [[ -n "${n}" ]]; then
    printf '%s\n' "${n}"
    return 0
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi
  # Portable fallback — at least one core.
  printf '1\n'
}

# Prints "load1 nproc ratio" on stdout. Returns 0 always when readable.
spawn_host_headroom_load() {
  local path="${CASEIN_SPAWN_LOADAVG_PATH:-/proc/loadavg}"
  local line load1
  if [[ ! -r "${path}" ]]; then
    echo "error: spawn headroom: cannot read loadavg at ${path}" >&2
    return 2
  fi
  read -r line <"${path}" || true
  load1="${line%% *}"
  if [[ -z "${load1}" ]]; then
    echo "error: spawn headroom: empty loadavg at ${path}" >&2
    return 2
  fi
  # Reject non-numeric garbage early.
  case "${load1}" in
    '' | *[!0-9.]*)
      echo "error: spawn headroom: unparseable load1='${load1}' from ${path}" >&2
      return 2
      ;;
  esac
  printf '%s\n' "${load1}"
}

# Prints MemAvailable kilobytes. Falls back to MemFree if Available missing.
spawn_host_headroom_mem_available_kb() {
  local path="${CASEIN_SPAWN_MEMINFO_PATH:-/proc/meminfo}"
  local avail="" free="" key val unit
  if [[ ! -r "${path}" ]]; then
    echo "error: spawn headroom: cannot read meminfo at ${path}" >&2
    return 2
  fi
  while read -r key val unit; do
    case "${key}" in
      MemAvailable:) avail="${val}" ;;
      MemFree:) free="${val}" ;;
    esac
  done <"${path}"
  if [[ -n "${avail}" ]]; then
    printf '%s\n' "${avail}"
    return 0
  fi
  if [[ -n "${free}" ]]; then
    printf '%s\n' "${free}"
    return 0
  fi
  echo "error: spawn headroom: MemAvailable/MemFree missing in ${path}" >&2
  return 2
}

# Compare load1 to nproc * max_ratio using awk (bash has no floats).
# Prints "1" if over threshold, "0" otherwise.
spawn_host_headroom_load_over() {
  local load1="$1" nproc="$2" max_ratio="$3"
  # Avoid awk var name `load` — gawk treats it as a builtin.
  awk -v l1="${load1}" -v n="${nproc}" -v r="${max_ratio}" 'BEGIN {
    if (n <= 0 || r < 0) { exit 2 }
    limit = n * r
    if (l1 > limit) print 1; else print 0
    exit 0
  }'
}

spawn_host_headroom_check() {
  local force="${CASEIN_SPAWN_FORCE:-0}"
  local max_ratio="${CASEIN_SPAWN_MAX_LOAD_RATIO:-1.0}"
  local min_mem_kb="${CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB:-2097152}"
  local load1 nproc mem_kb over reason=""

  case "${max_ratio}" in
    '' | *[!0-9.]*)
      echo "error: spawn headroom: CASEIN_SPAWN_MAX_LOAD_RATIO must be numeric (got '${max_ratio}')" >&2
      return 2
      ;;
  esac
  case "${min_mem_kb}" in
    '' | *[!0-9]*)
      echo "error: spawn headroom: CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB must be integer KiB (got '${min_mem_kb}')" >&2
      return 2
      ;;
  esac

  load1="$(spawn_host_headroom_load)" || return $?
  nproc="$(spawn_host_headroom_nproc)" || return $?
  mem_kb="$(spawn_host_headroom_mem_available_kb)" || return $?

  over="$(spawn_host_headroom_load_over "${load1}" "${nproc}" "${max_ratio}")" || {
    echo "error: spawn headroom: failed load comparison" >&2
    return 2
  }

  SPAWN_HOST_HEADROOM_LAST="load1=${load1} nproc=${nproc} max_ratio=${max_ratio} mem_available_kb=${mem_kb} min_mem_kb=${min_mem_kb}"

  if [[ "${over}" == "1" ]]; then
    reason="load1 ${load1} exceeds nproc ${nproc} × max_ratio ${max_ratio}"
  fi
  if ((mem_kb < min_mem_kb)); then
    if [[ -n "${reason}" ]]; then
      reason="${reason}; "
    fi
    reason="${reason}MemAvailable ${mem_kb} KiB below minimum ${min_mem_kb} KiB"
  fi

  if [[ -z "${reason}" ]]; then
    return 0
  fi

  # LOUD decline — never a silent no-op. The phrase "headroom exhausted" is
  # reserved for the refusal path (#996): FORCE must not emit it, because
  # callers grep that string and will treat a successful override as a refuse.
  if [[ "${force}" == "1" ]]; then
    cat >&2 <<EOF
warn: host headroom below threshold; proceeding under CASEIN_SPAWN_FORCE
      ${reason}
      probe: ${SPAWN_HOST_HEADROOM_LAST}
      operator accepts thrash risk; this is not a silent no-op
      tune: CASEIN_SPAWN_MAX_LOAD_RATIO  CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB
EOF
    return 0
  fi

  cat >&2 <<EOF
error: spawn refused — host headroom exhausted (#863)
       ${reason}
       probe: ${SPAWN_HOST_HEADROOM_LAST}
       calibration: healthy fill observed near load 18.6 on 32 cores (~0.58×nproc) with tens of GiB free;
                    refuse defaults are load1 > 1.0×nproc or MemAvailable < 2 GiB.
       override: CASEIN_SPAWN_FORCE=1 bash scripts/spawn-agent-worker.sh ...  # operator accepts thrash risk
       tune:     CASEIN_SPAWN_MAX_LOAD_RATIO  CASEIN_SPAWN_MIN_MEM_AVAILABLE_KB
EOF
  printf 'refused:headroom\n'
  return 75
}
