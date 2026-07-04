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
  NODE_ENV=development npm test
)

log "checking deploy script syntax and copied deploy artifacts"
bash -n scripts/deploy-devbox-release.sh
./scripts/check-deploy-sync.sh

log "checking agent shim shell regressions"
bash scripts/test-agent-shims.sh

log "fetching Elixir dependencies"
mise exec -- mix deps.get

log "running read-only precommit checks"
mise exec -- mix precommit.ci

log "checking doc citations resolve (docs/subsystems, docs/reference)"
./scripts/check-doc-citations.sh

if [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
  preview_json="$(
    bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true
  )"
  if [[ -n "$preview_json" ]]; then
    log "optional tidewave smoke check (${preview_json})"
    status="$(curl -fsS -o /dev/null -w '%{http_code}' \
      -H "content-type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      "$preview_json" 2>/dev/null || echo 000)"
    if [[ "$status" == "200" ]]; then
      log "tidewave MCP initialize → 200"
    else
      log "warn: tidewave MCP initialize → ${status} (preview env may still be booting)"
    fi
  fi
fi

log "pre-push checks passed"
