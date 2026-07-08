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
INST_DIR="/run/devide/instances"
CURRENT_SYMLINK="/run/devide/current.sock"

# ── current_sock_uuid: parse the symlink target into a uuid ──────────────────
readlink() { printf '%s\n' "/run/devide/instances/abc123def4567890.sock"; }
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
devide-aaaaaaaaaaaaaaaa.service loaded active running DevIDE canary a
devide-bbbbbbbbbbbbbbbb.service loaded active running DevIDE canary b
devide-loopback.service         loaded active running DevIDE loopback
devide-preview-router.service   loaded active running DevIDE preview
UNITS
}
mapfile -t uuids < <(running_canary_uuids)
[ "${#uuids[@]}" = "2" ] || fail "expected 2 canary uuids, got ${#uuids[@]}: ${uuids[*]}"
[ "${uuids[0]}" = "aaaaaaaaaaaaaaaa" ] || fail "first uuid '${uuids[0]}'"
[ "${uuids[1]}" = "bbbbbbbbbbbbbbbb" ] || fail "second uuid '${uuids[1]}'"
ok

echo "OK: canary-drain checks passed (${pass} assertions)"
