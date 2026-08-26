#!/usr/bin/env bash
#
# Hermetic unit tests for scripts/lib/service-path.sh — the canary unit PATH
# that lets Commands.spawn resolve allowlisted verifier tools (`mix`).
# No systemd, no deploy, no network.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/service-path.sh
source "${ROOT}/scripts/lib/service-path.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

SYSTEMD_DEFAULT="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEPLOY="${ROOT}/scripts/deploy-devbox-release.sh"

# ── deploy script wires the helper onto the canary unit ──────────────────────
grep -q 'scripts/lib/service-path.sh' "${DEPLOY}" || fail "deploy script must source service-path.sh"
grep -q 'SERVICE_PATH="$(casein_service_path "${USER_NAME}")"' "${DEPLOY}" ||
  fail "deploy script must compute SERVICE_PATH via casein_service_path"
grep -q -- '--property="Environment=PATH=${SERVICE_PATH}"' "${DEPLOY}" ||
  fail "deploy script must pin Environment=PATH on systemd-run"
grep -q '/home/devbox/.local/bin' "${DEPLOY}" && fail "deploy script must not hardcode /home/devbox/.local/bin" || ok
grep -q '/home/devbox' "${ROOT}/scripts/lib/service-path.sh" &&
  fail "service-path helper must not hardcode /home/devbox" || ok

# ── default prepends <home>/.local/bin ───────────────────────────────────────
unset CASEIN_SERVICE_PATH CASEIN_TOOL_BIN_DIR CASEIN_SERVICE_BASE_PATH CASEIN_DEPLOY_USER USER_NAME
export CASEIN_DEPLOY_HOME="/tmp/casein-service-path-home"
got="$(casein_service_path)"
expected="${CASEIN_DEPLOY_HOME}/.local/bin:${SYSTEMD_DEFAULT}"
[ "${got}" = "${expected}" ] || fail "default path: got '${got}' expected '${expected}'"
ok

# ── CASEIN_SERVICE_PATH overrides the entire PATH ────────────────────────────
export CASEIN_SERVICE_PATH="/opt/custom/bin:/usr/bin"
got="$(casein_service_path)"
[ "${got}" = "/opt/custom/bin:/usr/bin" ] || fail "SERVICE_PATH override: got '${got}'"
unset CASEIN_SERVICE_PATH
ok

# ── CASEIN_TOOL_BIN_DIR overrides the default tool directory ─────────────────
export CASEIN_TOOL_BIN_DIR="/opt/tools/bin"
got="$(casein_service_path)"
[ "${got}" = "/opt/tools/bin:${SYSTEMD_DEFAULT}" ] || fail "TOOL_BIN_DIR override: got '${got}'"
ok

# ── no duplicate when the tool dir is already on the base PATH ───────────────
export CASEIN_DEPLOY_HOME="/tmp/casein-service-path-home"
unset CASEIN_TOOL_BIN_DIR
export CASEIN_SERVICE_BASE_PATH="${CASEIN_DEPLOY_HOME}/.local/bin:/usr/bin:/bin"
got="$(casein_service_path)"
[ "${got}" = "${CASEIN_SERVICE_BASE_PATH}" ] || fail "duplicate tool dir: got '${got}'"
unset CASEIN_SERVICE_BASE_PATH
ok

# ── no home / no tool dir → systemd default only ─────────────────────────────
unset CASEIN_DEPLOY_HOME CASEIN_TOOL_BIN_DIR CASEIN_SERVICE_PATH CASEIN_SERVICE_BASE_PATH
unset CASEIN_DEPLOY_USER USER_NAME HOME
got="$(casein_service_path "")"
[ "${got}" = "${SYSTEMD_DEFAULT}" ] || fail "empty home fallback: got '${got}'"
ok

# ── diagnostic: mix missing on the systemd default PATH ──────────────────────
diag="$(casein_service_resolve mix "")"
printf '%s\n' "${diag}" | grep -qx "PATH=${SYSTEMD_DEFAULT}" || fail "diagnose PATH line: ${diag}"
printf '%s\n' "${diag}" | grep -qx "mix=missing" || fail "diagnose mix missing: ${diag}"
ok

# ── diagnostic: planted mix under CASEIN_TOOL_BIN_DIR ────────────────────────
tmp="$(mktemp -d "${TMPDIR:-/tmp}/casein-service-path.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/bin/mix"
chmod 0755 "${tmp}/bin/mix"
export CASEIN_TOOL_BIN_DIR="${tmp}/bin"
diag="$(casein_service_resolve mix)"
printf '%s\n' "${diag}" | grep -qx "PATH=${tmp}/bin:${SYSTEMD_DEFAULT}" || fail "planted PATH: ${diag}"
printf '%s\n' "${diag}" | grep -qx "mix=${tmp}/bin/mix" || fail "planted mix: ${diag}"
ok

echo "PASS: ${pass} checks"
