#!/usr/bin/env bash
#
# curl wrapper for the on-devbox DevIDE API.
# Prefers http://127.0.0.1:4000; falls back to /run/devide/current.sock.
#
# Usage:
#   source scripts/devide-curl.sh
#   devide_curl -fsS http://127.0.0.1:4000/api/workspaces
#
# Or:
#   bash scripts/devide-curl.sh -fsS http://127.0.0.1:4000/api/workspaces
#
set -euo pipefail

DEVIDE_LOOPBACK_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
CURRENT_SOCK="/run/devide/current.sock"

_loopback_ok() {
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "${DEVIDE_LOOPBACK_URL}/" 2>/dev/null || echo 000)"
  [[ "${code}" != "000" && -n "${code}" ]]
}

_to_unix_path() {
  local url="$1"
  local path="${url#http://127.0.0.1:4000}"
  path="${path#http://localhost:4000}"
  path="${path#http://127.0.0.1}"
  path="${path#http://localhost}"
  if [[ "$path" != /* ]]; then
    path="/${path}"
  fi
  printf '%s' "$path"
}

devide_curl() {
  local args=("$@")

  if _loopback_ok; then
    curl "${args[@]}"
    return
  fi

  if { [ -S "${CURRENT_SOCK}" ] || [ -L "${CURRENT_SOCK}" ]; }; then
    local rewritten=()
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
      local arg="${args[$i]}"
      if [[ "$arg" =~ ^https?:// ]]; then
        rewritten+=(--unix-socket "${CURRENT_SOCK}" "http://localhost$(_to_unix_path "$arg")")
      else
        rewritten+=("$arg")
      fi
      i=$((i + 1))
    done
    curl "${rewritten[@]}"
    return
  fi

  echo "error: DevIDE API unreachable (${DEVIDE_LOOPBACK_URL} down, ${CURRENT_SOCK} missing)" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  devide_curl "$@"
fi