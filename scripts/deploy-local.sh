#!/usr/bin/env bash
#
# Fast local devbox deploy: build the current checkout, package, and activate
# the systemd release. No pairing setup, workspace SQL, MCP materialization,
# or verification — use setup-devbox-agent-pairing.sh for first-time pairing.
#
# Intended workflow (git-backed, minimal restart overhead):
#   mix precommit
#   git commit && git push origin master
#   bash scripts/deploy-local.sh
#
# Run on the devbox host from the dev_ide checkout:
#   bash scripts/deploy-local.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"

log() { printf '>>> %s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker required to build release" >&2
  exit 1
fi

if ! sudo test -f "$ENV_FILE"; then
  echo "error: missing $ENV_FILE — run devbox first-deploy first" >&2
  exit 1
fi

REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo local)"

log "building release from ${REVISION}"
./scripts/build-release.sh

TARBALL="/tmp/dev_ide-release-$(date +%s).tgz"
tar -C release-out -czf "$TARBALL" .

log "deploying ${TARBALL}"
bash scripts/deploy-devbox-release.sh "$TARBALL" "$REVISION"

if [ "${DEVIDE_SKIP_HARDENING_AUDIT:-0}" != "1" ]; then
  log "running live hardening audit"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  scripts/hardening-audit.sh --live
fi

log "deployed ${REVISION} to /opt/devide/release"
