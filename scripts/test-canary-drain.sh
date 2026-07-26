#!/usr/bin/env bash
#
# Hermetic unit tests for scripts/lib/canary-drain.sh — the deploy drain/stop
# decision logic. Commands (systemctl, curl, kill, sudo, readlink) are shadowed
# by shell functions so nothing real is signalled. No devbox, no network.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/canary-drain.sh
source "${ROOT}/scripts/lib/canary-drain.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

# Collaborators the lib reads from caller scope.
log() { :; }
token="test-token"
INST_DIR="/run/casein/instances"
CURRENT_SYMLINK="/run/casein/current.sock"

# ── current_sock_uuid: parse the symlink target into a uuid ──────────────────
readlink() { printf '%s\n' "/run/casein/instances/abc123def4567890.sock"; }
got="$(current_sock_uuid)"
[ "${got}" = "abc123def4567890" ] || fail "current_sock_uuid parsed '${got}'"
ok

# Non-managed target (e.g. dev symlink elsewhere) yields empty, never a uuid.
readlink() { printf '%s\n' "/some/other/path.sock"; }
got="$(current_sock_uuid)"
[ -z "${got}" ] || fail "current_sock_uuid should be empty for foreign target, got '${got}'"
ok

# Missing symlink (readlink fails) yields empty.
readlink() { return 1; }
got="$(current_sock_uuid)"
[ -z "${got}" ] || fail "current_sock_uuid should be empty when symlink absent, got '${got}'"
ok
unset -f readlink

# ── canary_uuid_in_list: space-padded membership, empty never matches ────────
canary_uuid_in_list "b" " a b c " || fail "expected 'b' in list"
ok
canary_uuid_in_list "z" " a b c " && fail "did not expect 'z' in list" || ok
canary_uuid_in_list "" " a b c " && fail "empty uuid must never match" || ok
# A uuid that is only a substring of a member must not match (padding guard).
canary_uuid_in_list "a" " abc " && fail "'a' must not match member 'abc'" || ok

# ── drain_instance: reachable instance drains gracefully (200) ───────────────
git() { return 1; }                 # no revision → commits_behind=0
systemctl() { return 1; }           # is-active → false (irrelevant on 200 path)
curl() { printf '200'; }            # /api/drain returns 200
# -S predicate on the fake socket: make the file exist as a socket-ish path by
# pointing d_socket at something [ -S ] accepts. Use a real fifo/socket? Simpler:
# route via the port branch, which needs no [ -S ] test.
drain_count=0
stop_called=""
stop_canary_unit() { stop_called="$1"; }
drain_instance "uuidReachable000" "" "41069" ""
[ "${drain_count}" = "1" ] || fail "200 drain should increment drain_count, got ${drain_count}"
[ -z "${stop_called}" ] || fail "200 drain must not stop the unit"
ok

# ── drain_instance: already-draining (409) is left alone, not counted ────────
curl() { printf '409'; }
drain_count=0
stop_called=""
drain_instance "uuidDraining0000" "" "41069" ""
[ "${drain_count}" = "0" ] || fail "409 must not increment drain_count"
[ -z "${stop_called}" ] || fail "409 must not stop the unit"
ok

# ── drain_instance: unreachable + unit running → stop it ─────────────────────
curl() { printf '000'; }            # unreachable / curl failed
systemctl() { case "$*" in *is-active*) return 0 ;; *) return 1 ;; esac; }  # running
drain_count=0
stop_called=""
drain_instance "uuidZombie000000" "" "41069" ""
[ "${stop_called}" = "uuidZombie000000" ] || fail "unreachable running unit must be stopped, stop_called='${stop_called}'"
[ "${drain_count}" = "0" ] || fail "a stopped zombie is not a counted drain"
ok

# ── drain_instance: unreachable + unit NOT running → skip, no stop ───────────
curl() { printf '000'; }
systemctl() { return 1; }           # is-active → false
drain_count=0
stop_called=""
drain_instance "uuidGhost0000000" "" "41069" ""
[ -z "${stop_called}" ] || fail "a non-running instance must not be stopped"
ok

# ── running_canary_uuids: parse systemctl output to bare 16-hex uuids ────────
systemctl() {
  cat <<'UNITS'
devide-aaaaaaaaaaaaaaaa.service loaded active running Casein canary a
devide-bbbbbbbbbbbbbbbb.service loaded active running Casein canary b
casein-loopback.service         loaded active running Casein loopback
casein-preview-router.service   loaded active running Casein preview
UNITS
}
mapfile -t uuids < <(running_canary_uuids)
[ "${#uuids[@]}" = "2" ] || fail "expected 2 canary uuids, got ${#uuids[@]}: ${uuids[*]}"
[ "${uuids[0]}" = "aaaaaaaaaaaaaaaa" ] || fail "first uuid '${uuids[0]}'"
[ "${uuids[1]}" = "bbbbbbbbbbbbbbbb" ] || fail "second uuid '${uuids[1]}'"
ok

# ── orphaned_dev_server / reap_orphaned_dev_servers ──────────────────────────
# Shadow the /proc seams: pid → cmdline and pid → cwd fixtures.
declare -A FIX_CMDLINE FIX_CWD
proc_cmdline() { printf '%s' "${FIX_CMDLINE[$1]:-}"; }
proc_cwd() { printf '%s' "${FIX_CWD[$1]:-}"; }

# A leaked mix phx.server with a deleted worktree cwd → reapable.
FIX_CMDLINE[100]="/home/devbox/.../elixir/bin/mix phx.server"
FIX_CWD[100]="/tmp/casein-agent-worktrees/agent-x (deleted)"
orphaned_dev_server 100 || fail "leaked phx.server with deleted cwd must be orphaned"
ok

# A leaked release-node beam (dev_ide_*@host) with deleted cwd → reapable.
FIX_CMDLINE[101]="/erts/bin/beam.smp -- ... -name dev_ide_abc@host ..."
FIX_CWD[101]="/data/workspaces/x/.claude/worktrees/agent-y (deleted)"
orphaned_dev_server 101 || fail "leaked release node with deleted cwd must be orphaned"
ok

# The LIVE release: cwd is /opt/casein (not deleted) → never reaped. Also guarded
# by the explicit release-path exclusion.
FIX_CMDLINE[200]="/opt/casein/release/erts-16.4/bin/beam.smp -- ... "
FIX_CWD[200]="/opt/casein"
orphaned_dev_server 200 && fail "live release must never be orphaned" || ok

# A canary boot from the release path but (implausibly) a deleted cwd is still
# spared by the release-path exclusion — defense in depth.
FIX_CMDLINE[201]="/opt/casein/release/bin/beam.smp -- -name dev_ide_ccc@host"
FIX_CWD[201]="/opt/casein (deleted)"
orphaned_dev_server 201 && fail "release-path beam must never be orphaned even if cwd deleted" || ok

# A legitimate dev server in a LIVE worktree (cwd not deleted) → not reaped.
FIX_CMDLINE[300]="/home/devbox/.../mix phx.server"
FIX_CWD[300]="/data/workspaces/alice/proj"
orphaned_dev_server 300 && fail "dev server in a live worktree must not be orphaned" || ok

# A non-dev-ide beam (some other Elixir app) with deleted cwd → not ours, skip.
FIX_CMDLINE[400]="/erts/bin/beam.smp -- -name other_app@host"
FIX_CWD[400]="/tmp/whatever (deleted)"
orphaned_dev_server 400 && fail "a non-dev_ide beam must not be reaped" || ok

# reap_orphaned_dev_servers kills exactly the orphaned pids from a mixed list.
# The lib calls `kill "${od_pid}"` (single arg), so the stub captures $1.
killed=""
kill() { killed="${killed}$1 "; }
reap_orphaned_dev_servers 100 101 200 201 300 400
[ "${killed}" = "100 101 " ] || fail "reap must kill only orphaned pids, killed='${killed}'"
ok
unset -f proc_cmdline proc_cwd kill

echo "OK: canary-drain checks passed (${pass} assertions)"
