#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIVE=0
LIVE_ONLY=0

usage() {
  cat <<'EOF'
Usage: scripts/hardening-audit.sh [--live] [--live-only]

Runs the local hardening checks that protect user onboarding:
  - pre-scoped Terminal/Preview MCP workspace isolation
  - workspace safety policy role gates
  - deploy script syntax and release artifact sync

With --live, also smoke-checks the running devbox release. Source
.devbox-agent.env first when checking MCP pairing.

With --live-only, skips local Mix tests and only smoke-checks the running
devbox release. This is intended for post-activation deploy hooks that may run
from a clean release-build worktree without test dependencies installed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --live-only) LIVE=1; LIVE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

if [[ "$LIVE_ONLY" -ne 1 ]]; then
  log "checking deploy script syntax"
  bash -n scripts/deploy-devbox-release.sh
  bash -n scripts/deploy-local.sh
  bash -n scripts/setup-devbox-agent-pairing.sh
  bash -n scripts/verify_agent_pairing.sh
  bash -n scripts/verify_deploy_handoff.sh
  bash -n scripts/workspace-doctor.sh

  log "checking deploy artifacts are in sync"
  ./scripts/check-deploy-sync.sh

  log "running hardening-focused tests"
  mise exec -- mix test \
    test/dev_ide_web/api/terminal_mcp_test.exs \
    test/dev_ide_web/api/preview_mcp_test.exs \
    test/dev_ide_web/controllers/api/terminal_mcp_controller_test.exs \
    test/dev_ide_web/controllers/api/preview_mcp_controller_test.exs \
    test/dev_ide/policy_test.exs \
    test/dev_ide/deployment/drain_test.exs \
    test/dev_ide_web/api/deploy_status_controller_test.exs
fi

if [[ "$LIVE" -eq 1 ]]; then
  log "checking live deploy handoff endpoint"
  scripts/verify_deploy_handoff.sh --ci

  if [[ -n "${WORKSPACE_ID:-${DEVIDE_WORKSPACE_ID:-}}" && -n "${DEV_IDE_API_TOKEN:-}" ]]; then
    log "checking live agent pairing MCP endpoints"
    WORKSPACE_ID="${WORKSPACE_ID:-$DEVIDE_WORKSPACE_ID}" scripts/verify_agent_pairing.sh --ci
  else
    log "skipping live MCP pairing check; source .devbox-agent.env first"
  fi
fi

log "hardening audit passed"
