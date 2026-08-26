#!/usr/bin/env bash
#
# Service PATH for the managed Casein canary unit.
#
# systemd's default service PATH is
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin (plus /snap/bin
# on some hosts). That cannot resolve allowlisted verifier tools (`mix`,
# `elixir`, `erl`) which live in the deploy user's ~/.local/bin (mise shims).
# Casein.Commands.spawn uses System.find_executable("mix"), so a missing PATH
# here fails every code_exec verifier in the live canary.
#
# Portable: never hardcode a host home. Configurable via:
#   CASEIN_SERVICE_PATH       if set, used as the entire PATH
#   CASEIN_TOOL_BIN_DIR       extra dir prepended (default: <home>/.local/bin)
#   CASEIN_DEPLOY_HOME        home for the default tool dir (tests / override)
#   CASEIN_SERVICE_BASE_PATH  PATH after the tool dir (default: systemd-like)
#   CASEIN_DEPLOY_USER        used to resolve home via getent when HOME unset
#
# Pure functions, safe to source under `set -euo pipefail`.

CASEIN_SYSTEMD_DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

casein_service_home() {
  if [ -n "${CASEIN_DEPLOY_HOME:-}" ]; then
    printf '%s\n' "${CASEIN_DEPLOY_HOME}"
    return 0
  fi

  local user_name="${1:-${CASEIN_DEPLOY_USER:-${USER_NAME:-}}}"
  if [ -n "${user_name}" ]; then
    local home
    home="$(getent passwd "${user_name}" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "${home}" ]; then
      printf '%s\n' "${home}"
      return 0
    fi
  fi

  if [ -n "${HOME:-}" ]; then
    printf '%s\n' "${HOME}"
    return 0
  fi

  printf '%s\n' ""
}

casein_service_path() {
  if [ -n "${CASEIN_SERVICE_PATH:-}" ]; then
    printf '%s\n' "${CASEIN_SERVICE_PATH}"
    return 0
  fi

  local home tool_dir base
  home="$(casein_service_home "${1:-}")"
  tool_dir="${CASEIN_TOOL_BIN_DIR:-}"
  if [ -z "${tool_dir}" ] && [ -n "${home}" ]; then
    tool_dir="${home}/.local/bin"
  fi

  base="${CASEIN_SERVICE_BASE_PATH:-${CASEIN_SYSTEMD_DEFAULT_PATH}}"

  if [ -z "${tool_dir}" ]; then
    printf '%s\n' "${base}"
    return 0
  fi

  case ":${base}:" in
    *":${tool_dir}:"*) printf '%s\n' "${base}" ;;
    *) printf '%s\n' "${tool_dir}:${base}" ;;
  esac
}

# Deterministic diagnostic: print PATH=<value> and <bin>=<resolved|missing>.
# Does not execute the binary. Used by tests and operators.
casein_service_resolve() {
  local bin="${1:?usage: casein_service_resolve <bin> [user]}"
  local path resolved
  path="$(casein_service_path "${2:-}")"
  printf 'PATH=%s\n' "${path}"
  resolved="$(PATH="${path}" command -v "${bin}" 2>/dev/null || true)"
  if [ -n "${resolved}" ]; then
    printf '%s=%s\n' "${bin}" "${resolved}"
  else
    printf '%s=missing\n' "${bin}"
  fi
}
