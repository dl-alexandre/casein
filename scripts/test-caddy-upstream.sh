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

curl() {
  local method="GET"
  local url=""
  local data=""
  local connect_timeout=""
  local max_time=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -d) data="$2"; shift 2 ;;
      --connect-timeout) connect_timeout="$2"; shift 2 ;;
      --max-time) max_time="$2"; shift 2 ;;
      -H | -o | -w | --unix-socket) shift 2 ;;
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
    printf '%s\n' \
      '{"apps":{"http":{"servers":{"srv0":{"routes":[{"match":[{"host":["casein.devbox.milcgroup.com"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"unix//run/casein/current.sock"}]}]}]}}}}}'
  elif [ "$method" = "PATCH" ]; then
    current_dial="${data%\"}"
    current_dial="${current_dial#\"}"
    patch_count=$((patch_count + 1))
  elif [ "$url" = "${admin_url}/config${upstream_path}" ]; then
    printf '"%s"\n' "$current_dial"
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

current_dial="unix//unexpected/current.sock"
casein_reconcile_caddy_upstream "casein.devbox.milcgroup.com" migration
[ "$current_dial" = "unix//run/casein/current.sock" ]
[ "$patch_count" -eq 2 ]

unset -f curl

tmpdir="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
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
