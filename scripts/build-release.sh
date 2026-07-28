#!/usr/bin/env bash
#
# Build a prod release inside a container using the same Elixir/Erlang
# toolchain pinned by the production Dockerfile — no host toolchain required.
#
# This is the supported build path on any host that has Docker but not an
# Elixir/Erlang toolchain installed. Reuses the Dockerfile's `builder` stage
# so build steps stay in one place; we just extract the release tree out of
# it.
#
# Usage:
#   ./scripts/build-release.sh                       # builds, leaves tree at ./release-out
#   OUTPUT_DIR=/some/path ./scripts/build-release.sh # extract elsewhere
#
# The final builder image is also tagged with CASEIN_BUILDER_CACHE_TAG
# (default: casein:builder) and kept as a cache anchor for future builds.
# Extraction still uses a per-run tag so concurrent builds cannot retag the
# image out from under a running extraction.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/release-out}"

cd "${REPO_DIR}"

DOCKER_BIN="${CASEIN_DOCKER_BIN:-docker}"
CLEANUP_TIMEOUT_SECONDS="${CASEIN_DOCKER_CLEANUP_TIMEOUT_SECONDS:-30}"
OPERATION_TIMEOUT_SECONDS="${CASEIN_DOCKER_OPERATION_TIMEOUT_SECONDS:-600}"

if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
  echo "error: docker is required (toolchain runs in a container)" >&2
  exit 1
fi

BUILDER_TAG="casein:builder-$(date +%s)-$$"
BUILDER_CACHE_TAG="${CASEIN_BUILDER_CACHE_TAG:-casein:builder}"
EXTRACT_CONTAINER="casein-release-extract-$(date +%s)-$$"
EXTRACT_CONTAINER_CREATED=0

if ! [[ "${CLEANUP_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CASEIN_DOCKER_CLEANUP_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if ! [[ "${OPERATION_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CASEIN_DOCKER_OPERATION_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

build_args=(--target builder -t "${BUILDER_TAG}" -t "${BUILDER_CACHE_TAG}")

add_build_arg() {
  local name="$1"
  local value="$2"
  if [ -n "${value}" ]; then
    build_args+=(--build-arg "${name}=${value}")
  fi
}

if [ -z "${CASEIN_GIT_REVISION:-}" ] && command -v git >/dev/null 2>&1; then
  CASEIN_GIT_REVISION="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi

add_build_arg CASEIN_REPO_ADAPTER "${CASEIN_REPO_ADAPTER:-}"
add_build_arg CASEIN_GIT_REVISION "${CASEIN_GIT_REVISION:-}"
add_build_arg CASEIN_RELEASE_PROFILE "${CASEIN_RELEASE_PROFILE:-}"
add_build_arg CASEIN_RELEASE_REPO_ADAPTER "${CASEIN_RELEASE_REPO_ADAPTER:-}"
add_build_arg CASEIN_RELEASE_TARGET "${CASEIN_RELEASE_TARGET:-}"
add_build_arg CASEIN_RELEASE_CHANNEL "${CASEIN_RELEASE_CHANNEL:-}"
add_build_arg CASEIN_UPDATE_MANIFEST_URL "${CASEIN_UPDATE_MANIFEST_URL:-}"

if "${DOCKER_BIN}" image inspect "${BUILDER_CACHE_TAG}" >/dev/null 2>&1; then
  build_args+=(--cache-from "${BUILDER_CACHE_TAG}")
fi

echo ">>> building '${BUILDER_TAG}' (builder stage of Dockerfile; cache tag '${BUILDER_CACHE_TAG}')"
"${DOCKER_BIN}" build "${build_args[@]}" .

cleanup() {
  if [ "${EXTRACT_CONTAINER_CREATED}" -eq 1 ]; then
    if ! run_bounded_cleanup \
      "${DOCKER_BIN}" rm -f "${EXTRACT_CONTAINER}"; then
      echo "warning: failed or timed out removing extraction container ${EXTRACT_CONTAINER}; release validation is unaffected" >&2
    fi
  fi

  if [ "${BUILDER_TAG}" != "${BUILDER_CACHE_TAG}" ]; then
    run_bounded_cleanup "${DOCKER_BIN}" rmi -f "${BUILDER_TAG}" || true
  fi
}

run_bounded() {
  local timeout_seconds="$1"
  shift

  "$@" &
  local command_pid=$!

  (
    sleep "${timeout_seconds}"
    kill -TERM "${command_pid}" >/dev/null 2>&1 || exit 0
    sleep 1
    kill -KILL "${command_pid}" >/dev/null 2>&1 || true
  ) &
  local watchdog_pid=$!
  local status

  if wait "${command_pid}" 2>/dev/null; then
    status=0
  else
    status=$?
  fi

  kill "${watchdog_pid}" >/dev/null 2>&1 || true
  wait "${watchdog_pid}" >/dev/null 2>&1 || true
  return "${status}"
}

run_bounded_cleanup() {
  run_bounded "${CLEANUP_TIMEOUT_SECONDS}" "$@" >/dev/null 2>&1
}

run_bounded_operation() {
  run_bounded "${OPERATION_TIMEOUT_SECONDS}" "$@"
}

trap cleanup EXIT

if [ -e "${OUTPUT_DIR}" ]; then
  echo ">>> clearing existing ${OUTPUT_DIR}"
  rm -rf "${OUTPUT_DIR}"
fi

echo ">>> extracting release tree to ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
if ! run_bounded_operation \
  "${DOCKER_BIN}" create --name "${EXTRACT_CONTAINER}" "${BUILDER_TAG}" >/dev/null; then
  echo "error: timed out or failed creating extraction container ${EXTRACT_CONTAINER}" >&2
  exit 1
fi
EXTRACT_CONTAINER_CREATED=1
# `docker run --rm | tar` can leave the Docker client waiting indefinitely
# after the short-lived container is removed, even when the pipe consumer has
# already extracted every byte. Copy from a named, stopped container instead so
# cleanup is explicit and the operation has a hard upper bound.
if ! run_bounded_operation \
  "${DOCKER_BIN}" cp \
    "${EXTRACT_CONTAINER}:/app/_build/prod/rel/casein/." \
    "${OUTPUT_DIR}"; then
  echo "error: timed out or failed copying the release from ${EXTRACT_CONTAINER}" >&2
  exit 1
fi

# Sanity-check the release looks right.
if [ ! -x "${OUTPUT_DIR}/bin/casein" ]; then
  echo "error: extracted tree missing bin/casein — build did not produce a usable release" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/casein-runtime" ]; then
  echo "error: extracted tree missing bin/casein-runtime — generated release entrypoint was not preserved" >&2
  exit 1
fi
if [ ! -f "${OUTPUT_DIR}/releases/casein.relmeta.json" ]; then
  echo "error: extracted tree missing releases/casein.relmeta.json — required for LAN update checks" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/migrate" ]; then
  echo "error: extracted tree missing bin/migrate (rel/overlays/bin/migrate) — required by casein.service ExecStartPre" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/clean_casein_socket" ]; then
  echo "error: extracted tree missing bin/clean_casein_socket — required by casein.service ExecStartPre" >&2
  exit 1
fi
STATIC_DIR=""
for candidate in "${OUTPUT_DIR}"/lib/casein-*/priv/static; do
  if [ -d "${candidate}" ]; then
    STATIC_DIR="${candidate}"
    break
  fi
done
if [ "${STATIC_DIR}" = "" ]; then
  echo "error: extracted tree missing Casein priv/static directory" >&2
  exit 1
fi
if [ ! -f "${STATIC_DIR}/cache_manifest.json" ] || \
   [ ! -f "${STATIC_DIR}/assets/css/app.css" ] || \
   [ ! -f "${STATIC_DIR}/assets/js/app.js" ]; then
  echo "error: extracted release is missing compiled Phoenix assets" >&2
  echo "       expected cache_manifest.json, assets/css/app.css, and assets/js/app.js under ${STATIC_DIR}" >&2
  exit 1
fi

echo
echo "release ready at: ${OUTPUT_DIR}"
echo "  bin/casein   $(file -b "${OUTPUT_DIR}/bin/casein" 2>/dev/null || echo 'script')"
echo "  bin/casein-runtime present (OTP release entrypoint)"
echo "  bin/migrate   present"
echo "  bin/clean_casein_socket  present"
echo "size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo
echo "LAN activation from this release:"
echo "  sudo ${OUTPUT_DIR}/bin/casein lan up"
