#!/usr/bin/env bash
#
# Canary drain/stop helpers for scripts/deploy-devbox-release.sh, extracted so
# scripts/test-canary-drain.sh can exercise the enumeration/union/branching
# logic hermetically (stubbing systemctl/curl/kill). Pure function definitions
# only — no top-level side effects, safe to source under `set -euo pipefail`.
#
# Callers provide these from their own scope (resolved at call time):
#   log()             — logging function
#   token             — API bearer token for /api/drain
#   INST_DIR          — /run/casein/instances
#   CURRENT_SYMLINK   — /run/casein/current.sock
#   drain_count       — integer the drain loop tallies successful drains into
# Commands (systemctl, curl, kill, sudo, git, readlink) are invoked by name so
# tests can shadow them with shell functions.
#
# token/INST_DIR/CURRENT_SYMLINK/drain_count are intentionally supplied by the
# sourcing scope (deploy-devbox-release.sh or the hermetic test); the directive
# below silences "referenced but not assigned" for them across this lib.
# shellcheck disable=SC2154

# Stale instance JSON records store a PID that may be reused by unrelated
# processes (mix test, opencode, etc.). Require an /opt/casein/release beam.
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

# Instance liveness with the systemd unit as the authority. The heartbeat pid
# can be poisoned: a secondary boot under the same CASEIN_INSTANCE_UUID
# (release eval, seeds) overwrites the record with its own short-lived pid,
# which then reads as dead. Treating such a record as stale deleted it before
# the drain loop ran — every deploy logged "no old instances found to drain"
# and the superseded instance ran forever (seen 2026-07-07: zombie canaries
# fighting the live one over tmux window sizes).
casein_instance_alive() {
  inst_uuid="$1"
  inst_pid="$2"
  if [ -n "${inst_uuid}" ] && systemctl is-active --quiet "casein-${inst_uuid}" 2>/dev/null; then
    return 0
  fi
  casein_release_pid_alive "${inst_pid}"
}

# UUIDs of running casein-<16hex> canary units, one per line. systemd is the
# source of truth for what is actually running; instance records are advisory.
running_canary_uuids() {
  systemctl list-units --type=service --state=running --plain --no-legend 'casein-*' 2>/dev/null |
    awk '{print $1}' |
    sed -n 's/^casein-\([0-9a-f]\{16\}\)\.service$/\1/p'
}

# UUID that current.sock currently resolves to, or empty. The drain loop must
# never stop this instance: normally it is the one we just swapped in (==
# NEW_UUID), but if a CONCURRENT deploy swapped current.sock to its own fresh
# canary after us, that canary is now serving traffic — stopping it would drop
# live sessions. Resolved fresh at drain time so a late concurrent swap counts.
current_sock_uuid() {
  target="$(readlink "${CURRENT_SYMLINK}" 2>/dev/null || true)"
  case "${target}" in
    "${INST_DIR}/"*.sock)
      base="${target##*/}"
      printf '%s\n' "${base%.sock}"
      ;;
  esac
}

# Membership test for a space-padded uuid list, e.g. " a b c ". Returns 0 when
# uuid ($1) is present in list ($2). An empty uuid is never a member.
canary_uuid_in_list() {
  uuid="$1"
  list="$2"
  [ -n "${uuid}" ] || return 1
  case "${list}" in
    *" ${uuid} "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Stop a canary unit. sudo policy on the devbox intentionally forbids
# `systemctl stop`, so fall back to signalling the devbox-owned beam directly
# (units run with Restart=no, so it stays down). A wedged beam can ignore
# SIGTERM — we hit exactly that during the 2026-07-07 incident and had to
# SIGKILL — so escalate rather than leave a zombie still fighting tmux sizes.
stop_canary_unit() {
  stop_uuid="$1"
  if sudo -n systemctl stop "casein-${stop_uuid}" >/dev/null 2>&1; then
    return 0
  fi

  stop_pid="$(systemctl show "casein-${stop_uuid}" -p MainPID --value 2>/dev/null || true)"
  if [ -z "${stop_pid}" ] || [ "${stop_pid}" = "0" ]; then
    # No live main process — nothing to signal (already down, or unit gone).
    return 0
  fi

  kill "${stop_pid}" 2>/dev/null || true

  # Give the beam a few seconds to exit on SIGTERM, then SIGKILL.
  for _ in 1 2 3 4 5 6; do
    kill -0 "${stop_pid}" 2>/dev/null || return 0
    sleep 1
  done

  log "casein-${stop_uuid} ignored SIGTERM (pid ${stop_pid}) — escalating to SIGKILL"
  kill -9 "${stop_pid}" 2>/dev/null || true
  sleep 1
  if kill -0 "${stop_pid}" 2>/dev/null; then
    log "WARNING: casein-${stop_uuid} (pid ${stop_pid}) still alive after SIGKILL"
  fi
  return 0
}

# --- orphaned dev-server reaping ---------------------------------------------
# Leaked `mix phx.server` dev/verify servers — spawned inside an agent worktree
# (e.g. .claude/worktrees/agent-*) that was later removed — keep running with a
# now-deleted working directory. They hold prod-DB connections and, because they
# share the host tmux server, their SessionOwners fight the live instance over
# tmux window sizes (the "screen keeps flashing" reports). They are NOT
# deployment canaries, so the drain loop above never sees them; nothing marks
# them draining, so the SessionOwner drain-guard never fires either. Reap them
# on every deploy. Root-caused 2026-07-21 (8 leaked beams from 2026-07-15 found
# still pinning prod-DB connections).
#
# /proc access is behind seam functions so test-canary-drain.sh drives the
# decision without a real /proc.

# Command line of a pid (NUL-joined argv rendered space-separated), or empty.
proc_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true; }

# Working-directory symlink target of a pid, or empty. A removed directory reads
# as "<path> (deleted)".
proc_cwd() { readlink "/proc/$1/cwd" 2>/dev/null || true; }

# True when pid is a leaked casein beam that is safe to reap: one of our beams
# (a mix phx.server dev server or a release node), with a DELETED working
# directory. The live release and running canaries run from /opt/casein with
# cwd /opt/casein (never deleted), so the deleted-cwd gate alone already spares
# them; the explicit release-path exclusion is belt-and-suspenders.
orphaned_dev_server() {
  od_pid="$1"
  [ -n "${od_pid}" ] || return 1
  od_cmdline="$(proc_cmdline "${od_pid}")"
  case "${od_cmdline}" in
    */opt/casein/release/*) return 1 ;;
    *phx.server*) : ;;
    *casein_*@*) : ;;
    *) return 1 ;;
  esac
  case "$(proc_cwd "${od_pid}")" in
    *"(deleted)") return 0 ;;
    *) return 1 ;;
  esac
}

# Reap every orphaned dev server in the pid list ($@). The deploy passes
# `pgrep -x beam.smp`; the hermetic test passes a fixed list with shadowed
# proc_cmdline/proc_cwd/kill.
reap_orphaned_dev_servers() {
  reaped=0
  for od_pid in "$@"; do
    if orphaned_dev_server "${od_pid}"; then
      log "reaping orphaned dev server pid ${od_pid} (cwd $(proc_cwd "${od_pid}"))"
      kill "${od_pid}" 2>/dev/null || true
      reaped=$((reaped + 1))
    fi
  done
  [ "${reaped}" -gt 0 ] && log "reaped ${reaped} orphaned dev server(s)"
  return 0
}

# Drain one instance. Reachable → graceful /api/drain (200 counted, 409 left
# alone). Unreachable but its unit is still running → a zombie that will never
# drain itself, so stop it directly. Increments the caller's drain_count on a
# successful (200) drain.
drain_instance() {
  # $1 uuid (may be empty for record-only instances), $2 socket, $3 port, $4 revision
  d_uuid="$1"
  d_socket="$2"
  d_port="$3"
  d_revision="$4"

  commits_behind=0
  if [ -n "${d_revision}" ] && [ "${d_revision}" != "dev" ] && \
     git cat-file -e "${d_revision}" 2>/dev/null; then
    commits_behind="$(git rev-list "${d_revision}..HEAD" --count 2>/dev/null || echo 0)"
  fi

  drain_payload="{\"commits_behind\": ${commits_behind}}"
  drain_status=""

  if [ -n "${d_socket}" ] && [ -S "${d_socket}" ]; then
    drain_status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      -d "${drain_payload}" \
      --unix-socket "${d_socket}" \
      http://localhost/api/drain 2>/dev/null || true)"
  elif [ -n "${d_port}" ]; then
    drain_status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      -d "${drain_payload}" \
      "http://127.0.0.1:${d_port}/api/drain" 2>/dev/null || true)"
  fi

  case "${drain_status}" in
    200)
      drain_count=$((drain_count + 1))
      log "drain signalled (${d_uuid:-record-only}${d_socket:+ socket ${d_socket}}, ${commits_behind} commits behind)"
      return 0
      ;;
    409)
      # Already draining from an earlier deploy; its 30-minute hard timeout is
      # armed. Leave it be.
      log "already draining (${d_uuid:-record-only}${d_socket:+ socket ${d_socket}})"
      return 0
      ;;
  esac

  # Unreachable over its socket/port. If its unit is still running it is a
  # zombie that will never drain itself — stop it directly.
  if [ -n "${d_uuid}" ] && systemctl is-active --quiet "casein-${d_uuid}" 2>/dev/null; then
    log "drain unreachable for running unit casein-${d_uuid} — stopping it"
    stop_canary_unit "${d_uuid}"
  else
    log "drain skipped (${d_uuid:-record-only}) — instance not reachable and not running"
  fi
  return 0
}
