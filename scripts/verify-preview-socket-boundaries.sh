#!/usr/bin/env bash
#
# Verify the production DevIDE socket and ephemeral preview sockets stay in
# separate ownership lanes.
#
# Main app:
#   /run/devide/current.sock
#
# Preview envs:
#   <repo-parent>/.devide-preview/sockets/*.sock
#
# This script intentionally does not edit Caddy. With --cleanup it only runs the
# preview registry GC and preview router reload, which are scoped to preview
# environments.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_SOCK="${DEVIDE_CURRENT_SOCK:-/run/devide/current.sock}"
PREVIEW_HOME="${DEVIDE_PREVIEW_HOME:-$(dirname "$ROOT")/.devide-preview}"
PREVIEW_INSTANCES="${PREVIEW_HOME}/instances"
PREVIEW_SOCKETS="${PREVIEW_HOME}/sockets"
PREVIEW_ROUTER="${ROOT}/scripts/preview-router.sh"
PREVIEW_ENV="${ROOT}/scripts/preview-env.sh"
CLEANUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)
      CLEANUP=1
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--cleanup]" >&2
      exit 0
      ;;
    *)
      echo "usage: $0 [--cleanup]" >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warn: %s\n' "$*" >&2
}

ok() {
  printf 'ok: %s\n' "$*"
}

json_get() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1"
}

main_socket_check() {
  [[ "$MAIN_SOCK" = /run/devide/current.sock ]] ||
    fail "main socket path is ${MAIN_SOCK}; expected /run/devide/current.sock"

  [[ -S "$MAIN_SOCK" ]] ||
    fail "main socket missing: ${MAIN_SOCK}"

  curl -s -o /dev/null --max-time 5 --unix-socket "$MAIN_SOCK" http://localhost/ \
    || fail "main socket is not answering: ${MAIN_SOCK}"

  ok "main app socket answers at ${MAIN_SOCK}"
}

preview_registry_check() {
  mkdir -p "$PREVIEW_INSTANCES" "$PREVIEW_SOCKETS"

  shopt -s nullglob
  local file count=0
  for file in "$PREVIEW_INSTANCES"/*.json; do
    count=$((count + 1))
    local id socket pid status
    id="$(json_get "$file" id)"
    socket="$(json_get "$file" socket)"
    pid="$(json_get "$file" pid)"
    status="$(json_get "$file" status)"

    [[ -n "$id" ]] || fail "preview registry record has no id: ${file}"

    if [[ -n "$socket" ]]; then
      [[ "$socket" != "$MAIN_SOCK" ]] ||
        fail "preview env ${id} points at main socket ${MAIN_SOCK}"

      case "$socket" in
        "$PREVIEW_SOCKETS"/*.sock) ;;
        *)
          fail "preview env ${id} socket is outside preview socket dir: ${socket}"
          ;;
      esac
    fi

    if [[ "$status" = running ]]; then
      [[ -n "$pid" ]] || fail "running preview env ${id} has no pid"

      if ! kill -0 "$pid" 2>/dev/null; then
        fail "running preview env ${id} has dead pid ${pid}; run $PREVIEW_ENV gc"
      fi

      [[ -z "$socket" || -S "$socket" ]] ||
        fail "running preview env ${id} socket missing: ${socket}"
    fi
  done

  ok "preview registry checked (${count} record(s)); no preview points at main socket"
}

preview_router_check() {
  [[ -x "$PREVIEW_ROUTER" ]] || fail "preview router script missing: ${PREVIEW_ROUTER}"

  local status
  status="$("$PREVIEW_ROUTER" status 2>&1 || true)"
  printf '%s\n' "$status"

  if grep -Fq "$MAIN_SOCK" <<<"$status"; then
    fail "preview router status references main socket ${MAIN_SOCK}"
  fi

  ok "preview router status does not reference main socket"
}

preview_cleanup() {
  [[ -x "$PREVIEW_ENV" ]] || fail "preview env script missing: ${PREVIEW_ENV}"
  "$PREVIEW_ENV" gc
  "$PREVIEW_ROUTER" reload
  ok "preview gc and router reload completed"
}

if [[ "$CLEANUP" = 1 ]]; then
  preview_cleanup
fi

main_socket_check
preview_registry_check
preview_router_check

cat <<EOF

Verification commands:
  curl --unix-socket ${MAIN_SOCK} http://localhost/
  ${PREVIEW_ROUTER} status
  ${PREVIEW_ENV} ls
  ${PREVIEW_ENV} gc && ${PREVIEW_ROUTER} reload
EOF
