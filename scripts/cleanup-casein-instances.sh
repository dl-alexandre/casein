#!/usr/bin/env bash
#
# Remove stale /run/casein/instances/*.json records (and orphan sockets).
# Safe to run anytime; uses the same PID/cmdline checks as deploy-devbox-release.sh.
#
set -euo pipefail

INST_DIR="/run/casein/instances"

log() { printf '>>> %s\n' "$*"; }

casein_release_pid_alive() {
  pid="$1"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmdline}" in
    */opt/casein/release/*) return 0 ;;
    *casein_*@*) return 0 ;;
    *) return 1 ;;
  esac
}

# The systemd unit is authoritative: the heartbeat pid can be poisoned by a
# secondary boot under the same CASEIN_INSTANCE_UUID (release eval, seeds)
# that overwrote the record with its own short-lived pid. Deleting the record
# of a live instance hides it from the deploy's drain loop and it runs forever.
casein_instance_alive() {
  inst_uuid="$1"
  inst_pid="$2"
  if [ -n "${inst_uuid}" ] && systemctl is-active --quiet "casein-${inst_uuid}" 2>/dev/null; then
    return 0
  fi
  casein_release_pid_alive "${inst_pid}"
}

removed=0
for inst_file in "${INST_DIR}"/*.json; do
  [ -f "${inst_file}" ] || continue
  inst_pid="$(grep -o '"pid":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  inst_uuid="$(grep -o '"id":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  if casein_instance_alive "${inst_uuid}" "${inst_pid}"; then
    continue
  fi
  inst_sock_stale="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  log "removing ${inst_file}${inst_sock_stale:+ socket ${inst_sock_stale}}"
  sudo rm -f "${inst_file}" ${inst_sock_stale:+"${inst_sock_stale}"}
  removed=$((removed + 1))
done

log "removed ${removed} stale instance record(s)"
