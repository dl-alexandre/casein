#!/usr/bin/env bash

# Shared Caddy upstream discovery and reconciliation for the devbox release
# activator and periodic deploy poller. Callers provide log().

CASEIN_CADDY_CANONICAL_DIAL="${CASEIN_CADDY_CANONICAL_DIAL:-unix//run/casein/current.sock}"
CASEIN_CADDY_LOOPBACK_DIAL="${CASEIN_CADDY_LOOPBACK_DIAL:-127.0.0.1:4000}"
CASEIN_CADDY_LEGACY_DIAL="${CASEIN_CADDY_LEGACY_DIAL:-unix//run/devide/current.sock}"
CASEIN_CADDY_ADMIN_URL="${CASEIN_CADDY_ADMIN_URL:-http://localhost:2019}"

# Keep Caddy admin calls bounded even when inherited environment values are
# malformed or hostile. Enumerating the small accepted ranges avoids shell
# arithmetic overflow on arbitrarily large numeric strings.
case "${CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT:-}" in
  1 | 2 | 3 | 4 | 5) ;;
  *) CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT=2 ;;
esac
case "${CASEIN_CADDY_ADMIN_MAX_TIME:-}" in
  1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10) ;;
  *) CASEIN_CADDY_ADMIN_MAX_TIME=5 ;;
esac

CADDY_UPSTREAM_PATH="${CADDY_UPSTREAM_PATH:-}"
CADDY_PREVIOUS_DIAL="${CADDY_PREVIOUS_DIAL:-}"
CADDY_UPSTREAM_PATCHED="${CADDY_UPSTREAM_PATCHED:-0}"
CADDY_RECONCILE_OUTCOME="${CADDY_RECONCILE_OUTCOME:-not_attempted}"

casein_caddy_admin_curl() {
  curl \
    --connect-timeout "${CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT}" \
    --max-time "${CASEIN_CADDY_ADMIN_MAX_TIME}" \
    "$@"
}

# Read the root-owned deploy bearer exactly as its shell syntax defines it.
# Tokens may contain '=' padding or quotes, so splitting on '=' is unsafe.
casein_read_casein_api_token() {
  local env_file="$1"
  local token=""

  if [ -r "$env_file" ]; then
    token="$(
      unset CASEIN_API_TOKEN
      set -a
      # The trusted deploy caller supplies the environment path.
      # shellcheck source=/dev/null
      . "$env_file" >/dev/null 2>&1
      printf '%s' "${CASEIN_API_TOKEN:-}"
    )"
  elif sudo test -r "$env_file" 2>/dev/null; then
    token="$(sudo bash -c 'unset CASEIN_API_TOKEN; set -a; . "$1" >/dev/null 2>&1; printf "%s" "${CASEIN_API_TOKEN:-}"' _ "$env_file")"
  fi

  printf '%s' "$token"
}

# A candidate's deploy-status endpoint returns HTTP 503 when its own bounded
# Caddy-admin probe is unavailable. The canonical HTTPS route may still be
# serving that exact candidate, so activation may use this deliberately narrow
# attestation instead of treating a transient local-admin timeout as a route
# failure. It accepts no generic health result: every non-Caddy check, revision,
# and current socket must match exactly; an observed dial, malformed response,
# authentication/transport failure, or any other HTTP status is rejected.
casein_canonical_route_attests_caddy_unavailable() {
  local host="$1"
  local revision="$2"
  local socket_path="$3"
  local token="$4"
  local response_file=""
  local http_code=""

  if [ "$host" != "casein.devbox.milcgroup.com" ] ||
    ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]] ||
    [ -z "$socket_path" ] || [ -z "$token" ]; then
    log "warning: refusing canonical attestation with invalid expected identity"
    return 1
  fi

  response_file="$(mktemp "${TMPDIR:-/tmp}/casein-canonical-status-XXXXXX.json")" || {
    log "warning: unable to stage canonical deployment attestation"
    return 1
  }

  if ! http_code="$(curl \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout "${CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT}" \
    --max-time "${CASEIN_CADDY_ADMIN_MAX_TIME}" \
    -sS \
    -o "$response_file" \
    -w '%{http_code}' \
    -H "authorization: Bearer ${token}" \
    "https://${host}/api/deploy_status")"; then
    rm -f "$response_file"
    log "warning: canonical deployment attestation request failed"
    return 1
  fi

  # This is intentionally the controller's Caddy-unavailable response, not a
  # broad acceptance of failed health endpoints. Every other status fails closed.
  if [ "$http_code" != "503" ] || ! \
      CASEIN_EXPECTED_REVISION="$revision" \
      CASEIN_EXPECTED_SOCKET="$socket_path" \
      python3 - "$response_file" <<'PY'
import json
import os
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        status = json.load(handle)
except (OSError, ValueError, TypeError):
    sys.exit(1)

if not isinstance(status, dict) or status.get("ok") is not False:
    sys.exit(1)

if status.get("version") != os.environ["CASEIN_EXPECTED_REVISION"]:
    sys.exit(1)

expected_socket = os.environ["CASEIN_EXPECTED_SOCKET"]
if status.get("socket_path") != expected_socket or status.get("current_socket") != expected_socket:
    sys.exit(1)

checks = status.get("checks")
if not isinstance(checks, dict):
    sys.exit(1)

expected_check_names = {
    "socket_exists",
    "current_socket_points_to_instance",
    "caddy_casein_upstream",
    "deploy_revision_current",
    "deploy_pipeline_ok",
}
if set(checks) != expected_check_names:
    sys.exit(1)

for name in (
    "socket_exists",
    "current_socket_points_to_instance",
    "deploy_revision_current",
    "deploy_pipeline_ok",
):
    if checks.get(name) is not True:
        sys.exit(1)

caddy = checks.get("caddy_casein_upstream")
if not isinstance(caddy, dict):
    sys.exit(1)

# A fetched config with a missing/wrong route has no error or a concrete dial;
# it is not an unavailable probe and must never use this exception.
if caddy.get("ok") is not False or caddy.get("actual") is not None:
    sys.exit(1)
if not isinstance(caddy.get("error"), str) or not caddy["error"]:
    sys.exit(1)

expected_dials = caddy.get("expected")
if (
    not isinstance(expected_dials, list)
    or len(expected_dials) != 2
    or set(expected_dials) != {
    "unix//run/casein/current.sock",
    "127.0.0.1:4000",
    }
):
    sys.exit(1)
PY
  then
    rm -f "$response_file"
    log "warning: canonical deployment attestation did not prove only Caddy unavailability"
    return 1
  fi

  rm -f "$response_file"
  log "canonical HTTPS attested the exact handoff while Caddy admin was unavailable"
  return 0
}

casein_find_caddy_upstream_path() {
  local host="$1"
  local config=""

  if ! config="$(casein_caddy_admin_curl -s "${CASEIN_CADDY_ADMIN_URL}/config/" 2>/dev/null)"; then
    # Distinct from malformed config or a missing route: callers may use a
    # canonical-route attestation only when the admin probe itself is absent.
    return 2
  fi

  printf '%s\n' "$config" | CASEIN_CADDY_HOST="$host" python3 -c '
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
found = False
for index, route in enumerate(routes):
    if hosts_match(route):
        result = find_app_dial(
            route, f"/apps/http/servers/srv0/routes/{index}"
        )
        if result:
            print(result)
            found = True
        break
sys.exit(0 if found else 3)
'
}

casein_reconcile_caddy_upstream() {
  local host="$1"
  local mode="${2:-migration}"
  local observed=""
  local previous_dial=""
  local find_status=0
  local unknown_dial_observed=0

  CADDY_RECONCILE_OUTCOME="not_attempted"
  CADDY_UPSTREAM_PATH="$(casein_find_caddy_upstream_path "$host")" || find_status=$?
  if [ -z "$CADDY_UPSTREAM_PATH" ]; then
    if [ "$find_status" -eq 2 ]; then
      CADDY_RECONCILE_OUTCOME="admin_unavailable"
    else
      CADDY_RECONCILE_OUTCOME="route_lookup_failed"
    fi
    log "warning: Caddy app upstream for ${host} was not found"
    return 1
  fi

  if ! previous_dial="$(
    casein_caddy_admin_curl -s \
      "${CASEIN_CADDY_ADMIN_URL}/config${CADDY_UPSTREAM_PATH}" 2>/dev/null
  )"; then
    CADDY_RECONCILE_OUTCOME="admin_unavailable"
    log "warning: Caddy upstream read failed for ${host}"
    return 1
  fi
  CADDY_PREVIOUS_DIAL="$(printf '%s' "$previous_dial" | tr -d '"')"

  case "$CADDY_PREVIOUS_DIAL" in
    "$CASEIN_CADDY_CANONICAL_DIAL")
      if [ "$mode" = "repair" ]; then
        CADDY_RECONCILE_OUTCOME="verified_known_dial"
        log "Caddy upstream for ${host} points at the canonical socket"
        return 0
      fi
      # current.sock is an atomic symlink. Caddy may keep a pooled Unix
      # connection to the old target after the symlink changes, so activation
      # deliberately re-applies the same scalar value. The narrowly-scoped
      # config mutation reprovisions this reverse proxy without changing any
      # route or relying on a broad Caddy reload.
      log "refreshing canonical Caddy upstream for ${host} after socket handoff"
      ;;
    "$CASEIN_CADDY_LOOPBACK_DIAL")
      if [ "$mode" = "repair" ]; then
        CADDY_RECONCILE_OUTCOME="verified_known_dial"
        log "Caddy upstream for ${host} uses the supported loopback proxy"
        return 0
      fi
      log "refreshing supported loopback Caddy upstream for ${host} after socket handoff"
      ;;
    "$CASEIN_CADDY_LEGACY_DIAL")
      log "migrating known legacy Caddy upstream for ${host}: ${CADDY_PREVIOUS_DIAL} -> ${CASEIN_CADDY_CANONICAL_DIAL}"
      ;;
    *)
      unknown_dial_observed=1
      if [ "$mode" = "repair" ]; then
        CADDY_RECONCILE_OUTCOME="unknown_dial"
        log "warning: refusing to repair unknown Caddy upstream ${CADDY_PREVIOUS_DIAL:-empty} for ${host}"
        return 1
      fi
      log "migrating Caddy upstream for ${host}: ${CADDY_PREVIOUS_DIAL:-unknown} -> ${CASEIN_CADDY_CANONICAL_DIAL}"
      ;;
  esac

  local desired_dial="$CASEIN_CADDY_CANONICAL_DIAL"
  case "$CADDY_PREVIOUS_DIAL" in
    "$CASEIN_CADDY_CANONICAL_DIAL" | "$CASEIN_CADDY_LOOPBACK_DIAL")
      desired_dial="$CADDY_PREVIOUS_DIAL"
      ;;
  esac

  if ! casein_caddy_admin_curl -fsS -X PATCH \
      "${CASEIN_CADDY_ADMIN_URL}/config${CADDY_UPSTREAM_PATH}" \
      -H "content-type: application/json" \
      -d "\"${desired_dial}\"" >/dev/null; then
    CADDY_RECONCILE_OUTCOME="patch_failed"
    log "warning: Caddy upstream PATCH failed; leaving ${CADDY_PREVIOUS_DIAL:-unknown} in place"
    return 1
  fi

  if ! observed="$(
    casein_caddy_admin_curl -s \
      "${CASEIN_CADDY_ADMIN_URL}/config${CADDY_UPSTREAM_PATH}" 2>/dev/null
  )"; then
    CADDY_RECONCILE_OUTCOME="verification_failed"
    log "warning: Caddy upstream verification failed for ${host}"
    return 1
  fi
  observed="$(printf '%s' "$observed" | tr -d '"')"
  if [ "$observed" != "$desired_dial" ]; then
    CADDY_RECONCILE_OUTCOME="verification_failed"
    log "warning: Caddy upstream verification read ${observed:-empty}, expected ${desired_dial}"
    return 1
  fi

  CADDY_UPSTREAM_PATCHED=1
  if [ "$unknown_dial_observed" -eq 1 ]; then
    # Activation migration may repair an unknown value, but a transient status
    # response must not hide that the preceding route was untrusted.
    CADDY_RECONCILE_OUTCOME="unknown_dial_repaired"
  else
    CADDY_RECONCILE_OUTCOME="verified_known_dial"
  fi
  log "Caddy upstream repaired and verified"
}

casein_caddy_reconcile_allows_attestation() {
  case "$CADDY_RECONCILE_OUTCOME" in
    admin_unavailable | verified_known_dial) return 0 ;;
    *) return 1 ;;
  esac
}
