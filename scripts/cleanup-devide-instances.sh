#!/usr/bin/env bash
#
# Remove stale /run/devide/instances/*.json records (and orphan sockets).
# Safe to run anytime; uses the same PID/cmdline checks as deploy-devbox-release.sh.
#
set -euo pipefail

INST_DIR="/run/devide/instances"

log() { printf '>>> %s\n' "$*"; }

dev_ide_release_pid_alive() {
  pid="$1"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmdline}" in
    */opt/devide/release/*) return 0 ;;
    *dev_ide_*@*) return 0 ;;
    *) return 1 ;;
  esac
}

removed=0
for inst_file in "${INST_DIR}"/*.json; do
  [ -f "${inst_file}" ] || continue
  inst_pid="$(grep -o '"pid":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  if [ -n "${inst_pid}" ] && dev_ide_release_pid_alive "${inst_pid}"; then
    continue
  fi
  inst_sock_stale="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  log "removing ${inst_file}${inst_sock_stale:+ socket ${inst_sock_stale}}"
  sudo rm -f "${inst_file}" ${inst_sock_stale:+"${inst_sock_stale}"}
  removed=$((removed + 1))
done

log "removed ${removed} stale instance record(s)"