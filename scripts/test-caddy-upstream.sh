#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/caddy-upstream.sh
source "${ROOT}/scripts/lib/caddy-upstream.sh"

log() { :; }
sudo() {
  echo "Caddy admin probe unexpectedly invoked sudo" >&2
  return 93
}

upstream_path="/apps/http/servers/srv0/routes/0/handle/0/upstreams/0/dial"
current_dial="unix//run/casein/current.sock"
patch_count=0
admin_url="${CASEIN_CADDY_ADMIN_URL}"
admin_config_fail=0
admin_read_fail=0
admin_patch_fail=0
admin_verify_fail=0
canonical_body=""
canonical_http_code="503"
canonical_curl_fail=0
canonical_proto=""
canonical_tls=0
canonical_authorization=""
canonical_trace="$(mktemp "${TMPDIR:-/tmp}/casein-canonical-attestation-XXXXXX")"
cleanup_canonical_trace() { rm -f "$canonical_trace"; }
trap cleanup_canonical_trace EXIT

token_fixture="$(mktemp "${TMPDIR:-/tmp}/casein-token-fixture-XXXXXX")"
cleanup_token_fixture() { rm -f "$token_fixture"; }
trap 'cleanup_canonical_trace; cleanup_token_fixture' EXIT
printf "%s\n" "CASEIN_API_TOKEN='quoted==padded=='" >"$token_fixture"
token_fixture_value="$(casein_read_casein_api_token "$token_fixture")"
[ "$token_fixture_value" = "quoted==padded==" ]

curl() {
  local method="GET"
  local url=""
  local data=""
  local connect_timeout=""
  local max_time=""
  local output_file=""
  local write_out=""
  local headers=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -d) data="$2"; shift 2 ;;
      --connect-timeout) connect_timeout="$2"; shift 2 ;;
      --max-time) max_time="$2"; shift 2 ;;
      --proto) canonical_proto="$2"; shift 2 ;;
      --tlsv1.2) canonical_tls=1; shift ;;
      -H) headers="${headers}${2}"$'\n'; shift 2 ;;
      -o) output_file="$2"; shift 2 ;;
      -w) write_out="$2"; shift 2 ;;
      --unix-socket) shift 2 ;;
      -s | -fsS | -sS) shift ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done

  if [ "$connect_timeout" != "$CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT" ]; then
    echo "connect timeout option missing or incorrect: ${connect_timeout:-empty}" >&2
    return 91
  fi
  if [ "$max_time" != "$CASEIN_CADDY_ADMIN_MAX_TIME" ]; then
    echo "max time option missing or incorrect: ${max_time:-empty}" >&2
    return 92
  fi

  if [ "$url" = "${admin_url}/config/" ]; then
    [ "$admin_config_fail" -eq 0 ] || return 28
    printf '%s\n' \
      '{"apps":{"http":{"servers":{"srv0":{"routes":[{"match":[{"host":["casein.devbox.milcgroup.com"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"unix//run/casein/current.sock"}]}]}]}}}}}'
  elif [ "$method" = "PATCH" ]; then
    [ "$admin_patch_fail" -eq 0 ] || return 28
    current_dial="${data%\"}"
    current_dial="${current_dial#\"}"
    patch_count=$((patch_count + 1))
  elif [ "$url" = "${admin_url}/config${upstream_path}" ]; then
    [ "$admin_read_fail" -eq 0 ] || return 28
    if [ "$admin_verify_fail" -eq 1 ] &&
        [ "$current_dial" = "unix//run/casein/current.sock" ]; then
      return 28
    fi
    printf '"%s"\n' "$current_dial"
  elif [ "$url" = "https://casein.devbox.milcgroup.com/api/deploy_status" ]; then
    canonical_authorization="$(printf '%s\n' "$headers" | sed -n 's/^authorization: //p' | tail -n 1)"
    printf '%s|%s|%s\n' \
      "$canonical_proto" "$canonical_tls" "$canonical_authorization" >"$canonical_trace"

    if [ "$canonical_curl_fail" -eq 1 ]; then
      return 28
    fi
    if [ -z "$output_file" ] || [ "$write_out" != '%{http_code}' ]; then
      return 23
    fi

    printf '%s' "$canonical_body" >"$output_file"
    printf '%s' "$canonical_http_code"
  else
    return 22
  fi
}

assert_timeout_normalization() {
  local input_connect_timeout="$1"
  local input_max_time="$2"
  local expected_connect_timeout="$3"
  local expected_max_time="$4"

  CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT="$input_connect_timeout"
  CASEIN_CADDY_ADMIN_MAX_TIME="$input_max_time"
  # shellcheck source=scripts/lib/caddy-upstream.sh
  source "${ROOT}/scripts/lib/caddy-upstream.sh"

  if [ "$CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT" != "$expected_connect_timeout" ]; then
    echo "normalized connect timeout mismatch: got ${CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT}, expected ${expected_connect_timeout}" >&2
    exit 1
  fi
  if [ "$CASEIN_CADDY_ADMIN_MAX_TIME" != "$expected_max_time" ]; then
    echo "normalized max time mismatch: got ${CASEIN_CADDY_ADMIN_MAX_TIME}, expected ${expected_max_time}" >&2
    exit 1
  fi

  casein_caddy_admin_curl -s "${admin_url}/config/" >/dev/null
}

assert_timeout_normalization 0 0 2 5
assert_timeout_normalization nope invalid 2 5
assert_timeout_normalization 999999999999999999999999 999999999999999999999999 2 5
assert_timeout_normalization 5 10 5 10

unset CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT CASEIN_CADDY_ADMIN_MAX_TIME
# shellcheck source=scripts/lib/caddy-upstream.sh
source "${ROOT}/scripts/lib/caddy-upstream.sh"

casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" repair
[ "$current_dial" = "unix//run/casein/current.sock" ]
[ "$patch_count" -eq 0 ]
[ "$CADDY_RECONCILE_OUTCOME" = "verified_known_dial" ]
casein_caddy_reconcile_allows_attestation

casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" repair
[ "$patch_count" -eq 0 ]

current_dial="unix//run/devide/current.sock"
casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" repair
[ "$current_dial" = "unix//run/casein/current.sock" ]
[ "$patch_count" -eq 1 ]

current_dial="unix//unexpected/current.sock"
if casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" repair; then
  echo "repair unexpectedly rewrote an unknown upstream" >&2
  exit 1
fi
[ "$current_dial" = "unix//unexpected/current.sock" ]
[ "$patch_count" -eq 1 ]
[ "$CADDY_RECONCILE_OUTCOME" = "unknown_dial" ]
if casein_caddy_reconcile_allows_attestation; then
  echo "unknown Caddy dial unexpectedly allowed attestation" >&2
  exit 1
fi

current_dial="unix//unexpected/current.sock"
casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" migration
[ "$current_dial" = "unix//run/casein/current.sock" ]
[ "$patch_count" -eq 2 ]
[ "$CADDY_RECONCILE_OUTCOME" = "unknown_dial_repaired" ]
if casein_caddy_reconcile_allows_attestation; then
  echo "repaired unknown Caddy dial unexpectedly allowed attestation" >&2
  exit 1
fi

current_dial="unix//run/devide/current.sock"
admin_patch_fail=1
if casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" migration; then
  echo "failed Caddy PATCH unexpectedly reconciled" >&2
  exit 1
fi
[ "$CADDY_RECONCILE_OUTCOME" = "patch_failed" ]
if casein_caddy_reconcile_allows_attestation; then
  echo "failed Caddy PATCH unexpectedly allowed attestation" >&2
  exit 1
fi
admin_patch_fail=0

current_dial="unix//run/devide/current.sock"
admin_verify_fail=1
if casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" migration; then
  echo "failed Caddy verification unexpectedly reconciled" >&2
  exit 1
fi
[ "$CADDY_RECONCILE_OUTCOME" = "verification_failed" ]
if casein_caddy_reconcile_allows_attestation; then
  echo "failed Caddy verification unexpectedly allowed attestation" >&2
  exit 1
fi
admin_verify_fail=0

admin_config_fail=1
if casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" repair; then
  echo "unavailable Caddy admin unexpectedly reconciled" >&2
  exit 1
fi
[ "$CADDY_RECONCILE_OUTCOME" = "admin_unavailable" ]
casein_caddy_reconcile_allows_attestation
admin_config_fail=0
current_dial="unix//run/casein/current.sock"

attestation_revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
attestation_socket="/run/casein/instances/candidate.sock"

attestation_body() {
  CASEIN_FIXTURE_REVISION="$1" \
  CASEIN_FIXTURE_SOCKET="$2" \
  CASEIN_FIXTURE_CADDY_ACTUAL="$3" \
  CASEIN_FIXTURE_CADDY_ERROR="$4" \
  CASEIN_FIXTURE_PIPELINE_OK="$5" \
  CASEIN_FIXTURE_EXTRA_FAILED="$6" \
  python3 - <<'PY'
import json
import os

actual = os.environ["CASEIN_FIXTURE_CADDY_ACTUAL"]
error = os.environ["CASEIN_FIXTURE_CADDY_ERROR"]

caddy = {
    "ok": False,
    "actual": None if actual == "__nil__" else actual,
    "expected": ["unix//run/casein/current.sock", "127.0.0.1:4000"],
}
if error != "__missing__":
    caddy["error"] = error

checks = {
    "socket_exists": True,
    "current_socket_points_to_instance": True,
    "deploy_revision_current": True,
    "deploy_pipeline_ok": os.environ["CASEIN_FIXTURE_PIPELINE_OK"] == "true",
    "caddy_casein_upstream": caddy,
}
if os.environ["CASEIN_FIXTURE_EXTRA_FAILED"] == "true":
    checks["future_check"] = False

print(json.dumps({
    "ok": False,
    "version": os.environ["CASEIN_FIXTURE_REVISION"],
    "socket_path": os.environ["CASEIN_FIXTURE_SOCKET"],
    "current_socket": os.environ["CASEIN_FIXTURE_SOCKET"],
    "checks": checks,
}, separators=(",", ":")))
PY
}

attestation_body_with_duplicate_expected_dial() {
  attestation_body "$@" | python3 -c '
import json
import sys

status = json.load(sys.stdin)
status["checks"]["caddy_casein_upstream"]["expected"].append(
    "127.0.0.1:4000"
)
print(json.dumps(status, separators=(",", ":")))
'
}

# Only a canonical 503 body that proves the exact candidate plus every
# non-Caddy check can satisfy the temporary Caddy-unavailable exception.
canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "timeout" true false)"
canonical_http_code=503
canonical_curl_fail=0
canonical_proto=""
canonical_tls=0
canonical_authorization=""
casein_canonical_route_attests_caddy_unavailable \
  "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"
grep -Fx '=https|1|Bearer test-token' "$canonical_trace" >/dev/null

# The activation caller obtains its bearer from casein.env. Preserve a quoted,
# padded value through that read and into the canonical route request.
canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "timeout" true false)"
casein_canonical_route_attests_caddy_unavailable \
  "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "$token_fixture_value"
grep -Fx '=https|1|Bearer quoted==padded==' "$canonical_trace" >/dev/null

# All variations below remain fail-closed: stale route, known wrong dial,
# missing/malformed Caddy evidence, other failed checks, auth/HTTP failure,
# and a bounded transport timeout.
canonical_body="$(attestation_body "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$attestation_socket" "__nil__" "timeout" true false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "stale canonical revision unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "unix//wrong/current.sock" "timeout" true false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "wrong Caddy dial unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "__missing__" true false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "missing Caddy probe error unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body_with_duplicate_expected_dial "$attestation_revision" "$attestation_socket" "__nil__" "timeout" true false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "non-exact Caddy expected dials unexpectedly attested" >&2
  exit 1
fi

canonical_body='{"ok":false}'
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "malformed canonical response unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "timeout" false false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "failed non-Caddy check unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body "$attestation_revision" "/run/casein/instances/other.sock" "__nil__" "timeout" true false)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "wrong current socket unexpectedly attested" >&2
  exit 1
fi

canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "timeout" true false)"
canonical_http_code=401
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "authentication failure unexpectedly attested" >&2
  exit 1
fi
canonical_http_code=503

canonical_body="$(attestation_body "$attestation_revision" "$attestation_socket" "__nil__" "timeout" true true)"
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "unknown failed check unexpectedly attested" >&2
  exit 1
fi

canonical_curl_fail=1
if casein_canonical_route_attests_caddy_unavailable \
    "casein.devbox.milcgroup.com" "$attestation_revision" "$attestation_socket" "test-token"; then
  echo "timed out canonical request unexpectedly attested" >&2
  exit 1
fi
canonical_curl_fail=0

unset -f curl

tmpdir="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
  cleanup_canonical_trace
  cleanup_token_fixture
}
trap cleanup EXIT

port_file="${tmpdir}/port"
request_file="${tmpdir}/requests"
log_file="${tmpdir}/messages"

python3 - "$port_file" "$request_file" <<'PY' &
import socket
import sys
import threading
import time

port_file, request_file = sys.argv[1:]
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen()

with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(listener.getsockname()[1]))

config = (
    b'{"apps":{"http":{"servers":{"srv0":{"routes":[{"match":[{"host":'
    b'["casein.devbox.milcgroup.com"]}],"handle":[{"handler":"reverse_proxy",'
    b'"upstreams":[{"dial":"unix//run/casein/current.sock"}]}]}]}}}}}'
)

def handle_connection(connection):
    with connection:
        data = b""
        connection.settimeout(1)
        try:
            while b"\r\n\r\n" not in data:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                data += chunk
        except (TimeoutError, socket.timeout):
            pass

        request_line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
        with open(request_file, "a", encoding="utf-8") as handle:
            handle.write(request_line + "\n")

        if request_line == "GET /config/ HTTP/1.1":
            response = (
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(config)}\r\n".encode()
                + b"Connection: close\r\n\r\n"
                + config
            )
            connection.sendall(response)
            return

        time.sleep(30)

while True:
    connection, _address = listener.accept()
    threading.Thread(
        target=handle_connection, args=(connection,), daemon=True
    ).start()
PY
server_pid=$!

for _attempt in $(seq 1 100); do
  [ -s "$port_file" ] && break
  kill -0 "$server_pid" 2>/dev/null || {
    echo "hung Caddy fixture exited before publishing its port" >&2
    exit 1
  }
  sleep 0.01
done
[ -s "$port_file" ]

CASEIN_CADDY_ADMIN_URL="http://127.0.0.1:$(cat "$port_file")"
CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT=1
CASEIN_CADDY_ADMIN_MAX_TIME=1
CADDY_UPSTREAM_PATCHED=0
log() { printf '%s\n' "$*" >>"$log_file"; }

start_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
if casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" migration; then
  echo "hung Caddy admin unexpectedly reconciled" >&2
  exit 1
fi
end_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
elapsed_ms=$(((end_ns - start_ns) / 1000000))

if [ "$elapsed_ms" -gt 3000 ]; then
  echo "hung Caddy admin exceeded timeout bound: ${elapsed_ms}ms" >&2
  exit 1
fi
if grep -q '^PATCH ' "$request_file"; then
  echo "hung Caddy admin received an unsafe PATCH" >&2
  exit 1
fi
if grep -q 'repaired and verified' "$log_file"; then
  echo "hung Caddy admin was incorrectly reported as repaired" >&2
  exit 1
fi
[ "$CADDY_UPSTREAM_PATCHED" -eq 0 ]

echo "caddy upstream repair tests passed"
