#!/usr/bin/env bash
#
# preview-router-reap.sh — stop the previous preview router and prove it let go
# of the listen port.
#
# Two things spawn a router: `preview-router.sh reload` (`caddy start`, which
# daemonizes and outlives the shell) and the systemd unit (`caddy run`). Neither
# knows about the other, and Caddy binds with SO_REUSEPORT — so a second router
# does NOT fail with "address already in use". It binds *alongside* the first and
# the kernel load-balances between them, so requests hit whichever config that
# connection happened to land on.
#
# That is how a router carrying 26-day-old config kept serving a share of preview
# traffic after a restart that looked successful (pid 1198354). The previous
# `stop` could not catch it: it only ran `caddy stop` when the admin endpoint
# answered, so an orphan with an unreachable admin was never signalled — and it
# deleted the pidfile, the one handle to that orphan, without using it.
#
# Structured as a sourceable lib (like scripts/lib/canary-drain.sh) so the
# decision logic can be tested hermetically with commands shadowed.
#
# Reads from caller scope: CADDYFILE, PIDFILE, LISTEN, ADMIN, pid_alive,
# admin_alive.
#
# AGENTS.md forbids `pkill -f` on this shared box — pattern kills cross users and
# workspaces. Every PID signalled here is positively identified: it must own our
# listen port (or be recorded as ours) *and* be a caddy running *our* Caddyfile.

# Seconds to wait for a SIGTERMed router to exit before escalating.
: "${CASEIN_PREVIEW_ROUTER_REAP_WAIT:=10}"

preview_router_listen_port() { printf '%s\n' "${LISTEN##*:}"; }

# PIDs currently owning the listen port. `ss` is the sanctioned way to resolve a
# port owner (AGENTS.md), rather than matching on a command line.
preview_router_listener_pids() {
  ss -H -ltnp "sport = :$(preview_router_listen_port)" 2>/dev/null |
    grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# True when the port has any listener at all, attributable or not.
#
# Deliberately distinct from listener_pids: a socket owned by another user shows
# no `pid=` to us, and treating "no pid" as "port free" is precisely what lets a
# second router bind alongside it.
preview_router_port_busy() {
  [ -n "$(ss -H -ltn "sport = :$(preview_router_listen_port)" 2>/dev/null)" ]
}

# Only ever signal a caddy running OUR Caddyfile. The devbox-manager runs its own
# Caddy on different ports and must never be touched.
preview_router_is_ours() {
  local pid="$1" cmdline
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" || return 1
  case "$cmdline" in *caddy*) ;; *) return 1 ;; esac
  case "$cmdline" in *"$CADDYFILE"*) return 0 ;; *) return 1 ;; esac
}

# Candidate PIDs for a previous router, from all three places one can hide:
# the pidfile we wrote, the systemd unit's main process, and the port owner.
# Deduplicated; each is ownership-checked before being signalled.
preview_router_pids() {
  {
    [ -f "$PIDFILE" ] && cat "$PIDFILE" 2>/dev/null
    systemctl show casein-preview-router.service -p MainPID --value 2>/dev/null
    preview_router_listener_pids
  } | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -v '^0$' | sort -u
}

# True while any router of ours is still alive.
preview_router_alive() {
  local pid
  for pid in $(preview_router_pids); do
    preview_router_is_ours "$pid" && pid_alive "$pid" && return 0
  done
  return 1
}

# Stop the previous router and WAIT for it to release the port.
#
# Mirrors stop_canary_unit in scripts/lib/canary-drain.sh: graceful first, then
# SIGTERM, poll, and escalate to SIGKILL rather than leave a listener competing
# for connections. Returns non-zero if the port is still held at the end, so
# callers fail the start instead of binding a second listener.
preview_router_reap() {
  local pid reaped=0 waited=0

  # Graceful: ask it to shut down through its own admin API when reachable.
  if admin_alive; then
    caddy stop --address "$ADMIN" >/dev/null 2>&1 || true
  fi

  for pid in $(preview_router_pids); do
    preview_router_is_ours "$pid" || continue
    pid_alive "$pid" || continue
    kill "$pid" 2>/dev/null || true
    reaped=1
  done

  # `caddy stop` returns before the process is gone. Returning here without
  # waiting is what leaves the old listener holding the port while the new one
  # binds beside it.
  while [ "$waited" -lt "$CASEIN_PREVIEW_ROUTER_REAP_WAIT" ]; do
    if ! preview_router_alive; then
      [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
      [ "$reaped" = 1 ] && echo "preview-router: reaped previous router" >&2
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  # A wedged caddy can ignore SIGTERM the same way a wedged beam can.
  for pid in $(preview_router_pids); do
    preview_router_is_ours "$pid" || continue
    pid_alive "$pid" || continue
    echo "preview-router: pid $pid ignored SIGTERM — escalating to SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null || true
  done

  sleep 1
  if preview_router_alive; then
    echo "error: a previous preview router still owns port $(preview_router_listen_port) after SIGKILL" >&2
    return 1
  fi

  [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
  echo "preview-router: reaped previous router (required SIGKILL)" >&2
  return 0
}
