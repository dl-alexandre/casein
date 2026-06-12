#!/usr/bin/env bash
#
# Local mirror of the checks that must pass before a push to master can deploy.
# This intentionally uses read-only Mix checks so it is safe in a dirty worktree
# with unrelated edits.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '>>> %s\n' "$*"; }

cd "${ROOT}"

log "checking staged/worktree whitespace"
git diff --check

log "linting JS hooks"
(
  cd assets
  NODE_ENV=development npm ci --include=dev
  NODE_ENV=development npm run lint
)

log "checking deploy script syntax and copied deploy artifacts"
bash -n scripts/deploy-devbox-release.sh
./scripts/check-deploy-sync.sh

log "running read-only precommit checks"
mise exec -- mix precommit.ci

log "pre-push checks passed"
