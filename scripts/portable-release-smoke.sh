#!/usr/bin/env bash
#
# Build and exercise Casein's portable production profile in an isolated
# Docker Compose project. Only Docker, Docker Compose, and curl are required on
# the host; the Phoenix Channel client runs from its own disposable image.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${CASEIN_PORTABLE_SMOKE_PROJECT:-casein-portable-smoke-$$}"
TIMEOUT_SECONDS="${CASEIN_PORTABLE_SMOKE_TIMEOUT_SECONDS:-120}"

CASEIN_IMAGE="${CASEIN_PORTABLE_SMOKE_IMAGE:-${PROJECT}:latest}"
CHANNEL_SMOKE_IMAGE="${CASEIN_PORTABLE_CHANNEL_SMOKE_IMAGE:-${PROJECT}-channel:latest}"
remove_casein_image=1
remove_channel_smoke_image=1

if [ -n "${CASEIN_PORTABLE_SMOKE_IMAGE+x}" ]; then
  remove_casein_image=0
fi

if [ -n "${CASEIN_PORTABLE_CHANNEL_SMOKE_IMAGE+x}" ]; then
  remove_channel_smoke_image=0
fi

log() { printf '>>> [portable-smoke] %s\n' "$*"; }

cleanup() {
  status=$?
  set +e

  if [ "$status" -ne 0 ]; then
    log "failed; final container logs follow"
    "${compose[@]}" logs --no-color --tail 200
  fi

  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1

  if [ "${CASEIN_PORTABLE_SMOKE_KEEP_IMAGES:-0}" != "1" ]; then
    if [ "$remove_casein_image" -eq 1 ]; then
      docker image rm -f "$CASEIN_IMAGE" >/dev/null 2>&1
    fi

    if [ "$remove_channel_smoke_image" -eq 1 ]; then
      docker image rm -f "$CHANNEL_SMOKE_IMAGE" >/dev/null 2>&1
    fi
  fi

  rm -rf "$TMP_ROOT"
  return "$status"
}

for command in docker curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: $command is required" >&2
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "error: the Docker Compose plugin is required" >&2
  exit 1
fi

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "error: CASEIN_PORTABLE_SMOKE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 1
    ;;
  0)
    echo "error: CASEIN_PORTABLE_SMOKE_TIMEOUT_SECONDS must be greater than zero" >&2
    exit 1
    ;;
esac

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/casein-portable-smoke-XXXXXX")"
compose=(docker compose --project-name "$PROJECT" --file "$ROOT/docker-compose.yml")

mkdir -p "$TMP_ROOT/workspaces/alpha"
printf '# Portable smoke workspace\n' >"$TMP_ROOT/workspaces/alpha/README.md"

# Do not inherit a checkout-local .env: the contract is specifically that the
# portable profile boots with only this neutral configuration.
export COMPOSE_DISABLE_ENV_FILE=1
export SECRET_KEY_BASE="portable-smoke-secret-key-base-000000000000000000000000000000000000"
export CASEIN_API_TOKEN="portable-smoke-api-token"
export CASEIN_RUNNER_TOKEN="portable-smoke-runner-token"
export PHX_HOST="localhost"
export PORT="4000"
export POSTGRES_USER="casein"
export POSTGRES_PASSWORD="portable_smoke_postgres"
export POSTGRES_DB="casein_portable_smoke"
export CASEIN_HOST_PORT="0"
export CASEIN_PROFILE="portable"
export CASEIN_RELEASE_PROFILE="portable"
export CASEIN_IMAGE
export CASEIN_WORKSPACES_ROOT="/workspaces"
export CASEIN_WORKSPACES_HOST="$TMP_ROOT/workspaces"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "building portable production image"
"${compose[@]}" build casein

log "building disposable Phoenix Channel client"
docker build \
  --tag "$CHANNEL_SMOKE_IMAGE" \
  --file "$ROOT/docker/smoke/Dockerfile" \
  "$ROOT/docker/smoke"

log "running database migrations"
"${compose[@]}" run --rm casein /app/bin/migrate

log "starting portable stack"
"${compose[@]}" up --detach casein

published="$("${compose[@]}" port casein 4000)"
host_port="${published##*:}"
base_url="http://127.0.0.1:${host_port}"

deadline=$((SECONDS + TIMEOUT_SECONDS))
health_json=""

while [ "$SECONDS" -lt "$deadline" ]; do
  if health_json="$(curl --fail --silent --show-error --max-time 2 "$base_url/healthz" 2>/dev/null)"; then
    break
  fi

  sleep 1
done

if [ -z "$health_json" ]; then
  echo "error: /healthz did not become ready within ${TIMEOUT_SECONDS}s" >&2
  exit 1
fi

log "checking cockpit HTTP surface"
curl --fail --silent --show-error --location "$base_url/" >/dev/null

log "checking terminal MCP initialization"
mcp_json="$(
  curl --fail --silent --show-error \
    --header "authorization: Bearer ${CASEIN_API_TOKEN}" \
    --header "content-type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$base_url/api/terminals/mcp"
)"

log "checking a fresh terminal inside the production image"
terminal_json="$(
  curl --fail --silent --show-error \
    --header "authorization: Bearer ${CASEIN_API_TOKEN}" \
    "$base_url/api/smoke/terminal"
)"

log "checking Phoenix Channel keystroke round-trip"
user_token="$(
  "${compose[@]}" exec --no-TTY casein /app/bin/casein rpc \
    'IO.write(CaseinWeb.ChannelAuth.sign_user_token("portable-smoke-user"))'
)"
app_container="$("${compose[@]}" ps --quiet casein)"

docker run --rm \
  --network "container:${app_container}" \
  "$CHANNEL_SMOKE_IMAGE" \
  --url "ws://localhost:4000/socket/websocket" \
  --token "$user_token" \
  --workspace alpha \
  --timeout 20

log "checking bearer-gated workspace API"
workspaces_json="$(
  curl --fail --silent --show-error \
    --header "authorization: Bearer ${CASEIN_API_TOKEN}" \
    "$base_url/api/workspaces"
)"

HEALTH_JSON="$health_json" \
MCP_JSON="$mcp_json" \
TERMINAL_JSON="$terminal_json" \
WORKSPACES_JSON="$workspaces_json" \
docker run --rm --interactive \
  --entrypoint python3 \
  --env HEALTH_JSON \
  --env MCP_JSON \
  --env TERMINAL_JSON \
  --env WORKSPACES_JSON \
  "$CHANNEL_SMOKE_IMAGE" \
  -c 'import json, os

health = json.loads(os.environ["HEALTH_JSON"])
assert health == {"ok": True, "checks": {"database": "ready"}}, health

mcp = json.loads(os.environ["MCP_JSON"])
assert mcp["result"]["serverInfo"]["name"] == "Casein Terminal MCP Server", mcp

terminal = json.loads(os.environ["TERMINAL_JSON"])
assert terminal == {"ok": True}, terminal

workspaces = json.loads(os.environ["WORKSPACES_JSON"])
assert isinstance(workspaces, list), workspaces
assert any(item.get("id") == "alpha" or item.get("name") == "alpha" for item in workspaces), workspaces
'

log "portable release contract passed at $base_url"
