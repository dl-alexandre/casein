#!/usr/bin/env bash

# Shared Caddy upstream discovery and reconciliation for the devbox release
# activator and periodic deploy poller. Callers provide log().

CASEIN_CADDY_CANONICAL_DIAL="${CASEIN_CADDY_CANONICAL_DIAL:-unix//run/casein/current.sock}"
CASEIN_CADDY_LOOPBACK_DIAL="${CASEIN_CADDY_LOOPBACK_DIAL:-127.0.0.1:4000}"
CADDY_UPSTREAM_PATH="${CADDY_UPSTREAM_PATH:-}"
CADDY_PREVIOUS_DIAL="${CADDY_PREVIOUS_DIAL:-}"
CADDY_UPSTREAM_PATCHED="${CADDY_UPSTREAM_PATCHED:-0}"

casein_find_caddy_upstream_path() {
  local host="$1"

  sudo curl -s http://localhost:2019/config/ 2>/dev/null |
    CASEIN_CADDY_HOST="$host" python3 -c '
import json
import os
import sys

host = os.environ["CASEIN_CADDY_HOST"]
config = json.load(sys.stdin)

def hosts_match(route):
    for matcher in route.get("match") or []:
        if host in (matcher.get("host") or []):
            return True
    return False

def find_app_dial(value, path=""):
    if isinstance(value, dict):
        if (
            value.get("handler") == "reverse_proxy"
            and value.get("rewrite", {}).get("uri") != "/oauth2/auth"
        ):
            for index, upstream in enumerate(value.get("upstreams") or []):
                if "dial" in upstream:
                    return f"{path}/upstreams/{index}/dial"
        for key, child in value.items():
            if key == "handle_response":
                continue
            result = find_app_dial(child, f"{path}/{key}")
            if result:
                return result
    elif isinstance(value, list):
        for index, child in enumerate(value):
            result = find_app_dial(child, f"{path}/{index}")
            if result:
                return result
    return None

routes = (
    config.get("apps", {})
    .get("http", {})
    .get("servers", {})
    .get("srv0", {})
    .get("routes")
    or []
)
for index, route in enumerate(routes):
    if hosts_match(route):
        result = find_app_dial(
            route, f"/apps/http/servers/srv0/routes/{index}"
        )
        if result:
            print(result)
        break
'
}

casein_reconcile_caddy_upstream() {
  local host="$1"
  local mode="${2:-migration}"
  local observed=""

  CADDY_UPSTREAM_PATH="$(casein_find_caddy_upstream_path "$host" || true)"
  if [ -z "$CADDY_UPSTREAM_PATH" ]; then
    log "warning: Caddy app upstream for ${host} was not found"
    return 1
  fi

  CADDY_PREVIOUS_DIAL="$(
    sudo curl -s "http://localhost:2019/config${CADDY_UPSTREAM_PATH}" 2>/dev/null |
      tr -d '"' || true
  )"

  case "$CADDY_PREVIOUS_DIAL" in
    "$CASEIN_CADDY_CANONICAL_DIAL")
      log "Caddy upstream for ${host} points at the canonical socket"
      return 0
      ;;
    "$CASEIN_CADDY_LOOPBACK_DIAL")
      log "Caddy upstream for ${host} uses the supported loopback proxy"
      return 0
      ;;
    *)
      if [ "$mode" = "repair" ]; then
        log "warning: refusing to repair unknown Caddy upstream ${CADDY_PREVIOUS_DIAL:-empty} for ${host}"
        return 1
      fi
      log "migrating Caddy upstream for ${host}: ${CADDY_PREVIOUS_DIAL:-unknown} -> ${CASEIN_CADDY_CANONICAL_DIAL}"
      ;;
  esac

  if ! sudo curl -fsS -X PATCH \
      "http://localhost:2019/config${CADDY_UPSTREAM_PATH}" \
      -H "content-type: application/json" \
      -d "\"${CASEIN_CADDY_CANONICAL_DIAL}\"" >/dev/null; then
    log "warning: Caddy upstream PATCH failed; leaving ${CADDY_PREVIOUS_DIAL:-unknown} in place"
    return 1
  fi

  observed="$(
    sudo curl -s "http://localhost:2019/config${CADDY_UPSTREAM_PATH}" 2>/dev/null |
      tr -d '"' || true
  )"
  if [ "$observed" != "$CASEIN_CADDY_CANONICAL_DIAL" ]; then
    log "warning: Caddy upstream verification read ${observed:-empty}, expected ${CASEIN_CADDY_CANONICAL_DIAL}"
    return 1
  fi

  CADDY_UPSTREAM_PATCHED=1
  log "Caddy upstream repaired and verified"
}
