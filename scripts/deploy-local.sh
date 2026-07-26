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
# Run on the devbox host from the casein checkout:
#   bash scripts/deploy-local.sh
#
set -euo pipefail

ALLOW_DRIFT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-drift)
      ALLOW_DRIFT=1
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"

log() { printf '>>> %s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker required to build release" >&2
  exit 1
fi

if ! sudo test -f "$ENV_FILE"; then
  echo "error: missing $ENV_FILE — run devbox first-deploy first" >&2
  exit 1
fi

REVISION="$(git rev-parse HEAD 2>/dev/null || echo local)"

log "building release from ${REVISION}"
./scripts/build-release.sh

TARBALL="/tmp/casein-release-$(date +%s).tgz"
tar -C release-out -czf "$TARBALL" .

log "deploying ${TARBALL}"
if [[ "$ALLOW_DRIFT" -eq 1 ]]; then
  CASEIN_ALLOW_DEPLOY_DRIFT=1 bash scripts/deploy-devbox-release.sh "$TARBALL" "$REVISION"
else
  bash scripts/deploy-devbox-release.sh "$TARBALL" "$REVISION"
fi

if [ "${CASEIN_SKIP_HARDENING_AUDIT:-0}" != "1" ]; then
  log "running live hardening audit"
  # shellcheck source=/dev/null
  set -a
  source "$ENV_FILE"
  set +a
  scripts/hardening-audit.sh --live-only
fi

log "deployed ${REVISION} to /opt/casein/release"
