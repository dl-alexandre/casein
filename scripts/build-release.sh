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

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/release-out}"

cd "${REPO_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required (toolchain runs in a container)" >&2
  exit 1
fi

BUILDER_TAG="dev_ide:builder-$(date +%s)-$$"

echo ">>> building '${BUILDER_TAG}' (builder stage of Dockerfile)"
docker build --target builder -t "${BUILDER_TAG}" .

# Extract the release tree from the builder image without running it.
# `docker create` makes a stopped container we can `docker cp` from.
container_id="$(docker create "${BUILDER_TAG}")"
cleanup() {
  docker rm -f "${container_id}" >/dev/null 2>&1 || true
  docker rmi -f "${BUILDER_TAG}"  >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -e "${OUTPUT_DIR}" ]; then
  echo ">>> clearing existing ${OUTPUT_DIR}"
  rm -rf "${OUTPUT_DIR}"
fi

echo ">>> extracting release tree to ${OUTPUT_DIR}"
docker cp "${container_id}:/app/_build/prod/rel/dev_ide" "${OUTPUT_DIR}"

# Sanity-check the release looks right.
if [ ! -x "${OUTPUT_DIR}/bin/dev_ide" ]; then
  echo "error: extracted tree missing bin/dev_ide — build did not produce a usable release" >&2
  exit 1
fi
if [ ! -x "${OUTPUT_DIR}/bin/migrate" ]; then
  echo "error: extracted tree missing bin/migrate (rel/overlays/bin/migrate) — required by devide.service ExecStartPre" >&2
  exit 1
fi

echo
echo "release ready at: ${OUTPUT_DIR}"
echo "  bin/dev_ide   $(file -b "${OUTPUT_DIR}/bin/dev_ide" 2>/dev/null || echo 'script')"
echo "  bin/migrate   present"
echo "size: $(du -sh "${OUTPUT_DIR}" | cut -f1)"
