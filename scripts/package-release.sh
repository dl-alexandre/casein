#!/usr/bin/env bash
#
# Build and package a profile-specific DevIDE release for LAN distribution.
#
# Usage:
#   ./scripts/package-release.sh --profile lan --target linux-x86_64
#
# Produces (under dist/):
#   devide-lan-linux-x86_64-<shortsha>.tar.gz
#   devide-lan-linux-x86_64-<shortsha>.tar.gz.sha256
#   devide-canary.json
#
# Does not publish to GitHub Releases — generate locally, verify, then publish
# separately once the format is proven.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${REPO_DIR}/dist}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/release-out}"
CHANNEL="${DEVIDE_RELEASE_CHANNEL:-canary}"

PROFILE=""
TARGET=""

usage() {
  cat <<'EOF'
Usage: package-release.sh --profile lan --target <triplet>

Options:
  --profile lan        Release profile (required; only lan is packaged in v1)
  --target <triplet>   Release target (required; e.g. linux-x86_64)

Environment:
  DIST_DIR                  Output directory (default: ./dist)
  OUTPUT_DIR                Release tree directory (default: ./release-out)
  DEVIDE_RELEASE_CHANNEL    Manifest channel (default: canary)
  DEVIDE_UPDATE_MANIFEST_URL  Embedded manifest URL override
EOF
}

log() {
  printf '>>> %s\n' "$*"
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

[ -n "${PROFILE}" ] || die "--profile is required"
[ -n "${TARGET}" ] || die "--target is required"

case "${PROFILE}" in
  lan)
    REPO_ADAPTER=sqlite
    ;;
  *)
    die "unsupported profile: ${PROFILE}; v1 packaging supports only --profile lan"
    ;;
esac

if ! command -v git >/dev/null 2>&1; then
  die "git is required to pin DEVIDE_GIT_REVISION"
fi

REVISION="$(git -C "${REPO_DIR}" rev-parse HEAD)"
SHORT_SHA="$(printf '%s' "${REVISION}" | cut -c1-7)"
ARTIFACT_BASENAME="devide-${PROFILE}-${TARGET}-${SHORT_SHA}"
TARBALL="${DIST_DIR}/${ARTIFACT_BASENAME}.tar.gz"
SHA_FILE="${TARBALL}.sha256"
PREVIOUS_REVISION=""

if [ -f "${DIST_DIR}/devide-${CHANNEL}.json" ]; then
  PREVIOUS_REVISION="$(
    python3 - "${DIST_DIR}/devide-${CHANNEL}.json" "${PROFILE}" "${TARGET}" <<'PY' 2>/dev/null || true
import json, sys
path, profile, target = sys.argv[1:4]
with open(path) as fh:
    data = json.load(fh)
for art in data.get("artifacts", []):
    if art.get("profile") == profile and art.get("target") == target:
        print(art.get("revision", ""))
        break
PY
  )"
fi

log "building ${PROFILE}/${TARGET} release at ${REVISION}"

export DEV_IDE_REPO_ADAPTER="${REPO_ADAPTER}"
export DEVIDE_GIT_REVISION="${REVISION}"
export DEVIDE_RELEASE_PROFILE="${PROFILE}"
export DEVIDE_RELEASE_REPO_ADAPTER="${REPO_ADAPTER}"
export DEVIDE_RELEASE_TARGET="${TARGET}"
export DEVIDE_RELEASE_CHANNEL="${CHANNEL}"

(
  cd "${REPO_DIR}"
  OUTPUT_DIR="${OUTPUT_DIR}" ./scripts/build-release.sh
)

[ -f "${OUTPUT_DIR}/releases/dev_ide.relmeta.json" ] ||
  die "release tree missing releases/dev_ide.relmeta.json"

log "packaging ${TARBALL}"
mkdir -p "${DIST_DIR}"
tar -C "${OUTPUT_DIR}" -czf "${TARBALL}" .

(
  cd "${DIST_DIR}"
  sha256sum "$(basename "${TARBALL}")" > "$(basename "${SHA_FILE}")"
)

log "writing dist/devide-${CHANNEL}.json"
WRITE_CODE="$(cat <<EOF
alias Casein.Release.Package
prev = System.get_env("DEVIDE_PACKAGE_PREVIOUS_REVISION")
opts = [
  release_root: System.get_env("DEVIDE_PACKAGE_RELEASE_ROOT"),
  tarball: System.get_env("DEVIDE_PACKAGE_TARBALL"),
  dist_dir: System.get_env("DEVIDE_PACKAGE_DIST_DIR"),
  channel: System.get_env("DEVIDE_PACKAGE_CHANNEL")
]
opts = if prev in [nil, ""], do: opts, else: Keyword.put(opts, :previous_revision, prev)
result = Package.write_dist_manifest!(opts)
IO.puts(result.manifest_path)
EOF
)"

export DEVIDE_PACKAGE_RELEASE_ROOT="${OUTPUT_DIR}"
export DEVIDE_PACKAGE_TARBALL="${TARBALL}"
export DEVIDE_PACKAGE_DIST_DIR="${DIST_DIR}"
export DEVIDE_PACKAGE_CHANNEL="${CHANNEL}"
export DEVIDE_PACKAGE_PREVIOUS_REVISION="${PREVIOUS_REVISION}"

if command -v mise >/dev/null 2>&1; then
  (cd "${REPO_DIR}" && mise exec -- mix run --no-start -e "${WRITE_CODE}")
else
  (cd "${REPO_DIR}" && mix run --no-start -e "${WRITE_CODE}")
fi

log "artifact:  ${TARBALL}"
log "sha256:      ${SHA_FILE}"
log "manifest:    ${DIST_DIR}/devide-${CHANNEL}.json"
log "verify with: tar -tzf ${TARBALL} | head && (cd ${DIST_DIR} && sha256sum -c $(basename "${SHA_FILE}"))"
