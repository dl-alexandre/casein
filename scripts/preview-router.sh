#!/usr/bin/env bash
#
# preview-router.sh — dynamic reverse proxy for ephemeral preview environments.
#
# Generates a Caddyfile from the preview registry mapping
#   <id>.<PREVIEW_DOMAIN>  ->  127.0.0.1:<env-port>
# and runs/reloads a DEDICATED Caddy instance (its own admin port, no TLS). This
# is OUR instance — it never touches the devbox-manager Caddy.
#
# Edge hookup (one-time, devbox-manager side — NOT done here): point the
# *.devbox.milcgroup.com catch-all at this router so unmatched single-label
# subdomains (covered by the existing wildcard DNS + TLS cert) fall through:
#     handle { reverse_proxy 127.0.0.1:41080 }   # was: respond 404
# Then https://<id>.devbox.milcgroup.com routes straight to the env.
#
# Commands:
#   preview-router.sh reload    # regenerate from registry + start-or-reload
#   preview-router.sh stop
#   preview-router.sh reap      # kill any previous router and free the port
#   preview-router.sh status
#   preview-router.sh config    # print the generated Caddyfile
#
# The systemd unit (host overlay, not this repo) must reap before ExecStart, or
# its `caddy run` binds alongside an orphan under SO_REUSEPORT instead of
# failing. Add it as a second ExecStartPre:
#
#     ExecStartPre=/bin/bash -lc '.../scripts/preview-router.sh config >/dev/null'
#     ExecStartPre=/bin/bash -lc '.../scripts/preview-router.sh reap'
#
# `reap` exits non-zero if the port is still held, which makes systemd fail the
# start rather than add a second listener serving stale config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${CASEIN_PREVIEW_HOME:-$(dirname "$ROOT")/.casein-preview}"
INST_DIR="$STATE/instances"
ROUTER_DIR="$STATE/router"
CADDYFILE="$ROUTER_DIR/Caddyfile"
PIDFILE="$ROUTER_DIR/caddy.pid"
ROUTE_COUNT_FILE="$ROUTER_DIR/route-count"
LISTEN="${CASEIN_PREVIEW_ROUTER_LISTEN:-:41080}"
ADMIN="${CASEIN_PREVIEW_ROUTER_ADMIN:-127.0.0.1:41081}"
DOMAIN="${CASEIN_PREVIEW_DOMAIN:-devbox.milcgroup.com}"
# Upstreams for the two gates in front of own-origin preview panes. Overridable
# so the route can be exercised against stubs, and so a non-prod devbox can point
# at its own identity proxy and Casein socket.
IDENTITY_UPSTREAM="${CASEIN_PREVIEW_IDENTITY_UPSTREAM:-127.0.0.1:4180}"
AUTHZ_UPSTREAM="${CASEIN_PREVIEW_AUTHZ_UPSTREAM:-unix//run/casein/current.sock}"
LOGIN_URL="${CASEIN_PREVIEW_LOGIN_URL:-https://devbox.milcgroup.com/oauth2/start}"

mkdir -p "$ROUTER_DIR"
json_get() { sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1"; }
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

record_active() {
  local f="$1" status pid socket
  status="$(json_get "$f" status)"
  pid="$(json_get "$f" pid)"
  socket="$(json_get "$f" socket)"

  [ "$status" = running ] || return 1
  pid_alive "$pid" || return 1
  [ -z "$socket" ] || [ -S "$socket" ]
}

# Own-origin preview panes: pv-<port>-<workspace>.<domain> -> 127.0.0.1:<port>.
#
# This is a STATIC route — the port and workspace live in the hostname, so a
# preview opening or closing never needs a config reload, and the router keeps no
# registry for panes.
#
# It exists because the alternative, Casein's /preview-proxy/<ws>/<port>/ path
# prefix, permanently breaks LiveView: the client reports window.location.href on
# every channel join, the proxied app's router has no route for a prefixed path,
# and the rejected join makes the client fall back to a full page request in an
# endless ~1s reload loop. On its own origin the app sees its real path.
#
# Two gates run before anything reaches a loopback port, because the ports behind
# this route are other people's dev servers:
#   1. oauth2-proxy establishes identity (and sets X-Auth-Request-Email);
#   2. Casein decides whether THIS viewer may reach THIS workspace's port, using
#      the same gate as the path proxy (Casein.Previews.Access). Being signed in
#      is not sufficient.
emit_preview_pane_route() {
  local domain_re
  domain_re="$(printf '%s' "$DOMAIN" | sed 's/\./\\./g')"

  cat <<EOF
    @preview_pane header_regexp preview_pane Host ^pv-(?P<port>[0-9]{1,5})-(?P<ws>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.${domain_re}\$
    handle @preview_pane {
        forward_auth ${IDENTITY_UPSTREAM} {
            uri /oauth2/auth
            copy_headers X-Auth-Request-User X-Auth-Request-Email
            @unauthorized status 401 403
            handle_response @unauthorized {
                redir ${LOGIN_URL}?rd={scheme}://{host}{uri}
            }
        }
        forward_auth ${AUTHZ_UPSTREAM} {
            uri /api/previews/authz
        }
        reverse_proxy 127.0.0.1:{re.preview_pane.port} {
            # The pane embeds this origin in an iframe, so upstream frame-blocking
            # must not survive the hop. Only the framing controls are dropped; the
            # rest of the app's CSP is left intact.
            header_down -X-Frame-Options
            header_down Content-Security-Policy "frame-ancestors[^;]*;?\\s*" ""
        }
    }
EOF
}

generate() {
  local n=0
  {
    echo "{"
    echo "    admin $ADMIN"
    echo "    auto_https off"
    echo "}"
    echo
    echo "# Generated by preview-router.sh from $INST_DIR — do not edit by hand."
    echo "$LISTEN {"
    shopt -s nullglob
    local f
    for f in "$INST_DIR"/*.json; do
      local id port socket upstream
      record_active "$f" || continue
      id="$(json_get "$f" id)"; port="$(json_get "$f" port)"; socket="$(json_get "$f" socket)"
      [ -n "$id" ] || continue
      # Prefer the unix socket (collision-free, the canonical front door); fall
      # back to the loopback port for older registry records without a socket.
      if [ -n "$socket" ]; then
        upstream="unix/$socket"
      elif [ -n "$port" ]; then
        upstream="127.0.0.1:$port"
      else
        continue
      fi
      printf '    @%s host %s.%s\n' "$id" "$id" "$DOMAIN"
      printf '    handle @%s {\n        reverse_proxy %s\n    }\n' "$id" "$upstream"
      n=$((n+1))
    done
    emit_preview_pane_route
    echo '    handle {'
    echo '        respond "No active preview environment for {host}" 404'
    echo '    }'
    echo "}"
  } > "$CADDYFILE"
  printf '%s\n' "$n" > "$ROUTE_COUNT_FILE"
}

admin_alive() { curl -s --max-time 2 "http://$ADMIN/config/" >/dev/null 2>&1; }

# --- reaping the previous router ---------------------------------------------
# Decision logic lives in a sourceable lib so it can be tested hermetically; see
# scripts/lib/preview-router-reap.sh for why a restart needs an explicit reap.
# shellcheck source=lib/preview-router-reap.sh
source "$ROOT/scripts/lib/preview-router-reap.sh"

cmd_reload() {
  generate
  caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1 \
    || { echo "error: generated Caddyfile failed validation" >&2; caddy validate --adapter caddyfile --config "$CADDYFILE"; exit 1; }
  if admin_alive; then
    caddy reload --adapter caddyfile --config "$CADDYFILE" --address "$ADMIN" >/dev/null 2>&1
    echo "router reloaded ($(cat "$ROUTE_COUNT_FILE" 2>/dev/null || echo 0) active env(s)) on $LISTEN"
    return 0
  fi

  # No reachable admin, but that does NOT mean no router. An orphan from the
  # other spawn path holds the port with an unreachable admin, and starting on
  # top of it succeeds under SO_REUSEPORT — producing two routers serving
  # different configs to the same port. Reap before binding.
  preview_router_reap || exit 1

  # Refuse to rebind while anything still answers on the port. Better to fail
  # loudly than to add a second listener that serves stale config to a random
  # share of requests. An unattributable listener (another user's process) also
  # lands here rather than being treated as a free port.
  if preview_router_port_busy; then
    echo "error: $(preview_router_listen_port) still has a listener after reaping; refusing to bind alongside it" >&2
    ss -H -ltnp "sport = :$(preview_router_listen_port)" 2>/dev/null >&2 || true
    exit 1
  fi

  caddy start --adapter caddyfile --config "$CADDYFILE" --pidfile "$PIDFILE" >/dev/null 2>&1
  echo "router started on $LISTEN (admin $ADMIN)"
}

cmd_stop() {
  preview_router_reap || exit 1
  echo "router stopped"
}

cmd_status() {
  if admin_alive; then
    echo "router: running on $LISTEN (admin $ADMIN)"
    shopt -s nullglob
    local f
    for f in "$INST_DIR"/*.json; do
      record_active "$f" || continue
      local sock; sock="$(json_get "$f" socket)"
      printf '  %s.%s -> %s\n' "$(json_get "$f" id)" "$DOMAIN" \
        "${sock:+unix/$sock}${sock:-127.0.0.1:$(json_get "$f" port)}"
    done
  else
    echo "router: not running"
  fi
}

case "${1:-}" in
  reload) cmd_reload;;
  stop)   cmd_stop;;
  reap)   preview_router_reap;;
  status) cmd_status;;
  config) generate; cat "$CADDYFILE";;
  *) echo "usage: $0 {reload|stop|reap|status|config}" >&2; exit 2;;
esac
