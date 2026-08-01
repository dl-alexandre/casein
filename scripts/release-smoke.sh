#!/usr/bin/env bash
# Build, package, extract, and inspect a production release without publishing
# or activating it. All disposable output stays inside this checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${ROOT}/_build/prod"
RELEASE_DIR="${BUILD_ROOT}/rel/casein"
STATIC_ASSETS="${ROOT}/priv/static/assets"
STATIC_MANIFEST="${ROOT}/priv/static/cache_manifest.json"
ASSET_MODULES="${ROOT}/assets/node_modules"
PREVIEW_MODULES="${ROOT}/priv/scripts/node_modules"

cd "${ROOT}"
mkdir -p "${ROOT}/_build"
SMOKE_ROOT="$(mktemp -d "${ROOT}/_build/release-smoke.XXXXXX")"
ARCHIVE="${SMOKE_ROOT}/casein-release.tgz"
EXTRACTED="${SMOKE_ROOT}/extracted"

had_release=0
had_static_assets=0
had_static_manifest=0
had_asset_modules=0
had_preview_modules=0
[[ -e "${RELEASE_DIR}" ]] && had_release=1
[[ -e "${STATIC_ASSETS}" ]] && had_static_assets=1
[[ -e "${STATIC_MANIFEST}" ]] && had_static_manifest=1
[[ -e "${ASSET_MODULES}" ]] && had_asset_modules=1
[[ -e "${PREVIEW_MODULES}" ]] && had_preview_modules=1

cleanup() {
  rm -rf -- "${SMOKE_ROOT}"
  [[ "${had_release}" -eq 1 ]] || rm -rf -- "${RELEASE_DIR}"
  [[ "${had_static_assets}" -eq 1 ]] || rm -rf -- "${STATIC_ASSETS}"
  [[ "${had_static_manifest}" -eq 1 ]] || rm -f -- "${STATIC_MANIFEST}"
  [[ "${had_asset_modules}" -eq 1 ]] || rm -rf -- "${ASSET_MODULES}"
  [[ "${had_preview_modules}" -eq 1 ]] || rm -rf -- "${PREVIEW_MODULES}"
}
trap cleanup EXIT

if [[ -n "${MIX:-}" ]]; then
  read -r -a mix_command <<<"${MIX}"
elif command -v mise >/dev/null 2>&1; then
  mix_command=(mise exec -- mix)
else
  mix_command=(mix)
fi

echo ">>> building production release with casein.release.lan"
MIX_ENV=prod "${mix_command[@]}" casein.release.lan

[[ -x "${RELEASE_DIR}/bin/casein" ]] || {
  echo "error: release missing executable bin/casein" >&2
  exit 1
}

echo ">>> packaging release inside workspace"
tar -C "${RELEASE_DIR}" -czf "${ARCHIVE}" .

if tar -tzf "${ARCHIVE}" | awk '/^(\/|.*(^|\/)\.\.($|\/))/ { bad=1 } END { exit !bad }'; then
  echo "error: release archive contains an absolute or parent-traversing path" >&2
  exit 1
fi

mkdir -p "${EXTRACTED}"
tar -xzf "${ARCHIVE}" -C "${EXTRACTED}"

require_executable() {
  local relative="$1"
  [[ -x "${EXTRACTED}/${relative}" ]] || {
    echo "error: extracted release missing executable ${relative}" >&2
    exit 1
  }
}

require_file() {
  local relative="$1"
  [[ -f "${EXTRACTED}/${relative}" ]] || {
    echo "error: extracted release missing ${relative}" >&2
    exit 1
  }
}

require_executable bin/casein
require_executable bin/casein-runtime
require_executable bin/migrate
require_executable bin/clean_casein_socket
require_file releases/casein.relmeta.json
require_file README.md

casein_lib="$(find "${EXTRACTED}/lib" -mindepth 1 -maxdepth 1 -type d -name 'casein-*' -print -quit)"
[[ -n "${casein_lib}" ]] || {
  echo "error: extracted release missing lib/casein-*" >&2
  exit 1
}

static_dir="${casein_lib}/priv/static"
scripts_dir="${casein_lib}/priv/scripts"
for path in \
  "${static_dir}/cache_manifest.json" \
  "${static_dir}/assets/css/app.css" \
  "${static_dir}/assets/js/app.js" \
  "${scripts_dir}/preview_playwright.mjs" \
  "${scripts_dir}/node_modules/playwright/cli.js"; do
  [[ -f "${path}" ]] || {
    echo "error: extracted release missing ${path#"${EXTRACTED}/"}" >&2
    exit 1
  }
done

node "${scripts_dir}/node_modules/playwright/cli.js" --version >/dev/null

if [[ -d "${EXTRACTED}/docs" ]]; then
  echo "error: private source docs unexpectedly shipped in the release" >&2
  exit 1
fi

echo ">>> release smoke passed"
