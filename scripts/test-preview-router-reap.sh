#!/usr/bin/env bash
#
# Hermetic unit tests for scripts/lib/preview-router-reap.sh — the preview
# router's reap/rebind decisions. ss, systemctl, caddy, kill and sleep are
# shadowed by shell functions, and process identity is read from a fake /proc,
# so nothing real is signalled. No devbox, no network, no ports bound.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Collaborators the lib reads from caller scope. shellcheck cannot see the
# sourced lib consume these, hence the targeted disable.
# shellcheck disable=SC2034
{
  CADDYFILE="$TMP/router/Caddyfile"
  PIDFILE="$TMP/router/caddy.pid"
  LISTEN=":41080"
  ADMIN="127.0.0.1:41081"
  CASEIN_PREVIEW_ROUTER_REAP_WAIT=2
}
mkdir -p "$TMP/router" "$TMP/proc"
pid_alive() { [ -n "$1" ] && [ -n "${ALIVE[$1]:-}" ]; }

# shellcheck source=scripts/lib/preview-router-reap.sh
source "$ROOT/scripts/lib/preview-router-reap.sh"

# Fake /proc/<pid>/cmdline so ownership checks are exercised for real.
preview_router_is_ours() {
  local pid="$1" cmdline
  [ -n "$pid" ] && [ -r "$TMP/proc/$pid" ] || return 1
  cmdline="$(cat "$TMP/proc/$pid")"
  case "$cmdline" in *caddy*) ;; *) return 1 ;; esac
  case "$cmdline" in *"$CADDYFILE"*) return 0 ;; *) return 1 ;; esac
}

declare -A ALIVE=()
KILLED=""
SIGKILLED=""
LISTENERS=""
ADMIN_UP=0
CADDY_STOP_CALLED=0

reset_world() {
  ALIVE=(); KILLED=""; SIGKILLED=""; LISTENERS=""
  ADMIN_UP=0; CADDY_STOP_CALLED=0
  rm -f "$PIDFILE"; rm -f "$TMP"/proc/*
}

spawn() { # spawn <pid> <cmdline>
  ALIVE[$1]=1
  printf '%s' "$2" > "$TMP/proc/$1"
}

sleep() { :; }                       # tests must not actually wait
admin_alive() { [ "$ADMIN_UP" = 1 ]; }
caddy() { [ "${1:-}" = stop ] && CADDY_STOP_CALLED=1; return 0; }
systemctl() { printf '%s\n' "${UNIT_MAINPID:-0}"; }

# `ss -H -ltnp "sport = :41080"` → one line per listener; `-ltn` (no -p) is the
# attribution-free variant used by port_busy.
ss() {
  local want_pid=0 a
  for a in "$@"; do case "$a" in -*p*) want_pid=1;; esac; done
  local p
  for p in $LISTENERS; do
    if [ "$want_pid" = 1 ] && [ "${p#unattributable}" = "$p" ]; then
      printf 'LISTEN 0 4096 *:41080 *:* users:(("caddy",pid=%s,fd=3))\n' "$p"
    else
      printf 'LISTEN 0 4096 *:41080 *:*\n'
    fi
  done
}

kill() {
  if [ "${1:-}" = "-9" ]; then SIGKILLED="$SIGKILLED $2"; unset "ALIVE[$2]"; return 0; fi
  if [ "${1:-}" = "-0" ]; then return 0; fi
  KILLED="$KILLED $1"
  # Default fake: a well-behaved caddy exits on SIGTERM.
  [ "${IGNORES_SIGTERM:-0}" = 1 ] || unset "ALIVE[$1]"
  return 0
}

# ── ownership: never signal the manager's Caddy ─────────────────────────────
reset_world
spawn 111 "caddy run --config /opt/devbox/manager/data/Caddyfile"
LISTENERS="111"
preview_router_is_ours 111 && fail "manager Caddy must never be identified as ours"
ok

reset_world
spawn 222 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
preview_router_is_ours 222 || fail "our own router must be identified"
ok

# A non-caddy process holding the port is not ours either.
reset_world
spawn 333 "/usr/bin/python3 -m http.server 41080"
preview_router_is_ours 333 && fail "non-caddy process must not be identified as ours"
ok

# ── the SO_REUSEPORT orphan: unreachable admin, still holding the port ──────
reset_world
spawn 1198354 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
LISTENERS="1198354"
ADMIN_UP=0                                  # orphan's admin is gone
preview_router_reap >/dev/null 2>&1 || fail "reap must succeed against an orphan"
[ -z "${ALIVE[1198354]:-}" ] || fail "orphan must be dead after reap"
case "$KILLED" in *1198354*) ok;; *) fail "orphan was never signalled (the original bug)";; esac

# It is found via the port even with no pidfile and no systemd unit.
reset_world
spawn 999 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
LISTENERS="999"
UNIT_MAINPID=0
got="$(preview_router_pids | tr '\n' ' ')"
case "$got" in *999*) ok;; *) fail "port owner must be a reap candidate, got '$got'";; esac

# ── graceful path is tried before signals ──────────────────────────────────
reset_world
spawn 555 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
LISTENERS="555"; ADMIN_UP=1
preview_router_reap >/dev/null 2>&1 || fail "reap must succeed on the graceful path"
[ "$CADDY_STOP_CALLED" = 1 ] || fail "reachable admin must get a graceful caddy stop first"
ok

# ── escalation: a wedged router that ignores SIGTERM ───────────────────────
reset_world
spawn 777 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
LISTENERS="777"
IGNORES_SIGTERM=1
preview_router_reap >/dev/null 2>&1 || fail "reap must still succeed after escalating"
IGNORES_SIGTERM=0
case "$SIGKILLED" in *777*) ok;; *) fail "SIGTERM-ignoring router must be SIGKILLed";; esac
[ -z "${ALIVE[777]:-}" ] || fail "router must be gone after SIGKILL"
ok

# ── refuse to rebind while the port is still held ──────────────────────────
# An unattributable listener (another user's socket shows no pid to us) must
# read as BUSY, not as a free port — treating it as free is what allows a second
# router to bind alongside under SO_REUSEPORT.
reset_world
LISTENERS="unattributable1"
preview_router_port_busy || fail "unattributable listener must count as busy"
ok
[ -z "$(preview_router_listener_pids)" ] || fail "unattributable listener must yield no pid"
ok

reset_world
LISTENERS=""
preview_router_port_busy && fail "no listener must read as free" || ok

# ── pidfile hygiene ────────────────────────────────────────────────────────
reset_world
printf '4242\n' > "$PIDFILE"
spawn 4242 "/usr/local/bin/caddy run --adapter caddyfile --config $CADDYFILE"
preview_router_reap >/dev/null 2>&1 || fail "reap must succeed for a pidfile-recorded router"
[ ! -f "$PIDFILE" ] || fail "pidfile must be removed once the router is gone"
ok

# A stale pidfile naming a dead pid must not wedge the reap.
reset_world
printf '31337\n' > "$PIDFILE"
preview_router_reap >/dev/null 2>&1 || fail "stale pidfile must not fail the reap"
ok

# ── nothing running is a clean no-op ───────────────────────────────────────
reset_world
preview_router_reap >/dev/null 2>&1 || fail "reap with nothing running must succeed"
[ -z "$KILLED" ] || fail "reap must not signal anything when no router exists, killed:$KILLED"
ok

echo "OK: preview-router reap checks passed ($pass assertions)"
