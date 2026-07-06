#!/usr/bin/env bash
#
# Local mirror of the checks that must pass before a push to master can deploy.
# This intentionally uses read-only Mix checks so it is safe in a dirty worktree
# with unrelated edits.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '>>> %s\n' "$*"; }

cd "${ROOT}"

# Elixir runs through mise (reads .tool-versions) locally and on the self-hosted
# runner, but GitHub-hosted runners have no mise. Fall back to plain `mix` when
# mise is absent so one script drives both.
if command -v mise >/dev/null 2>&1; then
  MIX=(mise exec -- mix)
else
  MIX=(mix)
fi

# --- Cheap checks first: fail fast on trivial breakage (seconds, not minutes)
# before paying for npm and the test suite. ---

log "checking staged/worktree whitespace"
git diff --check

log "checking deploy script syntax"
bash -n scripts/deploy-devbox-release.sh

log "running hermetic shell unit tests (scoped-token validation/durability)"
bash scripts/test-scoped-token-durability.sh

log "running hermetic shell unit tests (agent shim install/resolution/passthrough)"
bash scripts/test-agent-shims.sh

log "shellcheck (warning+) on agent shim/launch scripts"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning -x \
    scripts/devide \
    scripts/install-agent-shims.sh \
    scripts/launch-devide-agent.sh \
    scripts/lib/real-agent-bin.sh \
    scripts/lib/agent-doctor.sh \
    scripts/test-agent-shims.sh
else
  log "shellcheck not installed — skipping (GitHub-hosted CI runners have it)"
fi

log "linting JS hooks"
(
  cd assets
  # Skip the (slow) `npm ci` when package-lock.json is unchanged since the last
  # successful install — a sha256 stamp inside node_modules records what was
  # installed. Benefits the local hook and the self-hosted runner, which now
  # persists node_modules across runs (checkout clean:false). npm ci wipes
  # node_modules, so the stamp is written *after* it succeeds.
  stamp="node_modules/.package-lock.sha256"
  want="$(sha256sum package-lock.json | awk '{print $1}')"
  if [[ -d node_modules && -f "${stamp}" && "$(cat "${stamp}")" == "${want}" ]]; then
    log "node_modules up to date (package-lock.json unchanged) — skipping npm ci"
  else
    NODE_ENV=development npm ci --include=dev
    printf '%s\n' "${want}" >"${stamp}"
  fi
  NODE_ENV=development npm run lint
  NODE_ENV=development npm test
)

log "fetching Elixir dependencies"
"${MIX[@]}" deps.get

# precommit.ci also runs ./scripts/check-deploy-sync.sh (via the mix.exs alias),
# so it is not invoked standalone here — deploy-devbox.yml relies on the alias too.
log "running read-only precommit checks"
"${MIX[@]}" precommit.ci

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
