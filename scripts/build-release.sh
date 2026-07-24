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
# (default: dev_ide:builder) and kept as a cache anchor for future builds.
# Extraction still uses a per-run tag so concurrent builds cannot retag the
# image out from under a running extraction.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/release-out}"

cd "${REPO_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required (toolchain runs in a container)" >&2
  exit 1
fi

BUILDER_TAG="dev_ide:builder-$(date +%s)-$$"
BUILDER_CACHE_TAG="${CASEIN_BUILDER_CACHE_TAG:-dev_ide:builder}"

build_args=(--target builder -t "${BUILDER_TAG}" -t "${BUILDER_CACHE_TAG}")

add_build_arg() {
  local name="$1"
  local value="$2"
  if [ -n "${value}" ]; then
    build_args+=(--build-arg "${name}=${value}")
  fi
}

if [ -z "${DEVIDE_GIT_REVISION:-}" ] && command -v git >/dev/null 2>&1; then
  DEVIDE_GIT_REVISION="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
fi

add_build_arg CASEIN_REPO_ADAPTER "${CASEIN_REPO_ADAPTER:-}"
add_build_arg DEVIDE_GIT_REVISION "${DEVIDE_GIT_REVISION:-}"
add_build_arg DEVIDE_RELEASE_PROFILE "${DEVIDE_RELEASE_PROFILE:-}"
add_build_arg DEVIDE_RELEASE_REPO_ADAPTER "${DEVIDE_RELEASE_REPO_ADAPTER:-}"
add_build_arg DEVIDE_RELEASE_TARGET "${DEVIDE_RELEASE_TARGET:-}"
add_build_arg DEVIDE_RELEASE_CHANNEL "${DEVIDE_RELEASE_CHANNEL:-}"
add_build_arg DEVIDE_UPDATE_MANIFEST_URL "${DEVIDE_UPDATE_MANIFEST_URL:-}"

if docker image inspect "${BUILDER_CACHE_TAG}" >/dev/null 2>&1; then
  build_args+=(--cache-from "${BUILDER_CACHE_TAG}")
fi

echo ">>> building '${BUILDER_TAG}' (builder stage of Dockerfile; cache tag '${BUILDER_CACHE_TAG}')"
docker build "${build_args[@]}" .

cleanup() {
  if [ "${BUILDER_TAG}" != "${BUILDER_CACHE_TAG}" ]; then
    docker rmi -f "${BUILDER_TAG}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -e "${OUTPUT_DIR}" ]; then
  echo ">>> clearing existing ${OUTPUT_DIR}"
  rm -rf "${OUTPUT_DIR}"
fi

echo ">>> extracting release tree to ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
docker run --rm "${BUILDER_TAG}" \
  sh -c 'cd /app/_build/prod/rel/dev_ide && tar -cf - .' |
  tar -C "${OUTPUT_DIR}" -xf -

# Sanity-check the release looks right.
if [ ! -x "${OUTPUT_DIR}/bin/casein" ]; then
  echo "error: extracted tree missing bin/casein — build did not produce a usable release" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/devide" ]; then
  echo "error: extracted tree missing bin/devide (rel/overlays/bin/devide) — required by release LAN commands" >&2
  exit 1
fi
if [ ! -f "${OUTPUT_DIR}/releases/casein.relmeta.json" ]; then
  echo "error: extracted tree missing releases/casein.relmeta.json — required for LAN update checks" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/migrate" ]; then
  echo "error: extracted tree missing bin/migrate (rel/overlays/bin/migrate) — required by devide.service ExecStartPre" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/clean_devide_socket" ]; then
  echo "error: extracted tree missing bin/clean_devide_socket — required by devide.service ExecStartPre" >&2
  exit 1
fi
STATIC_DIR="$(find "${OUTPUT_DIR}/lib" -path '*/priv/static' -type d | grep '/dev_ide-' | head -n 1 || true)"
if [ "${STATIC_DIR}" = "" ]; then
  echo "error: extracted tree missing DevIDE priv/static directory" >&2
  exit 1
fi
if [ ! -f "${STATIC_DIR}/cache_manifest.json" ] || \
   [ ! -f "${STATIC_DIR}/assets/css/app.css" ] || \
   [ ! -f "${STATIC_DIR}/assets/js/app.js" ]; then
  echo "error: extracted release is missing compiled Phoenix assets" >&2
  echo "       expected cache_manifest.json, assets/css/app.css, and assets/js/app.js under ${STATIC_DIR}" >&2
  exit 1
fi

# Verify deploy artifacts for devbox activation (rel/overlays/deploy/ + new
# bin/activate_devbox_deploy helper). These are copied into the stable
# /opt/devide/deploy/ by the activation step.
if [ ! -f "${OUTPUT_DIR}/deploy/devide.service" ] || \
   [ ! -f "${OUTPUT_DIR}/deploy/docker-compose.postgres.yml" ]; then
  echo "error: extracted tree missing deploy/ artifacts (devide.service + compose)" >&2
  echo "       required for on-devbox stable layout activation" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/activate_devbox_deploy" ]; then
  echo "warning: activate_devbox_deploy helper missing (non-fatal; activation commands are also documented in deploy/README.md)" >&2
fi

echo
echo "release ready at: ${OUTPUT_DIR}"
echo "  bin/casein   $(file -b "${OUTPUT_DIR}/bin/casein" 2>/dev/null || echo 'script')"
echo "  bin/devide    present (release operator helper)"
echo "  bin/migrate   present"
echo "  bin/clean_devide_socket  present"
echo "  deploy/       present (devide.service, compose, env.example, README.md)"
echo "  bin/activate_devbox_deploy  (optional one-command helper for devbox)"
echo "size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo
echo "Devbox activation (after scp + place under /opt/devide/release):"
echo "  sudo /opt/devide/release/bin/activate_devbox_deploy"
echo "  # or the explicit commands in the release's deploy/README.md"
echo
echo "LAN activation from this release:"
echo "  sudo ${OUTPUT_DIR}/bin/devide lan up"
