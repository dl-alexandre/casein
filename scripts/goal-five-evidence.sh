#!/usr/bin/env bash
# Mechanical evidence runner for the top-five crucial improvements goal.
# Run from a clean worktree with empty git status. Writes logs to SCRATCH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/grok-goal-1bbe809758a7/implementer}"
ENV_FILE="${DEVBOX_AGENT_ENV:-${ROOT}/.devbox-agent.env}"
# First parent of the initial goal commit — scopes diff to deliverable files only.
GOAL_BASE="${GOAL_BASE:-9b75d9c^}"

mkdir -p "$SCRATCH"
cd "$ROOT"

log() { printf '>>> %s\n' "$*"; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: worktree must be clean before evidence capture" >&2
  git status --short >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ ! -d "${ROOT}/deps" ]]; then
  log "mix deps.get (clean worktree)"
  mise exec -- mix deps.get >"${SCRATCH}/deps-get.log" 2>&1
fi

log "verify_agent_pairing.sh --ci"
WORKSPACE_ID="${DEVIDE_WORKSPACE_ID}" bash scripts/verify_agent_pairing.sh --ci \
  >"${SCRATCH}/verify.log" 2>&1

log "mcp-dogfood-agent-pair.sh"
SCRATCH="$SCRATCH" DEVBOX_AGENT_ENV="$ENV_FILE" bash scripts/mcp-dogfood-agent-pair.sh \
  >"${SCRATCH}/mcp-dogfood-direct.log" 2>&1

log "mix test policy/audit"
mise exec -- mix test test/casein/policy_test.exs test/casein/audit_test.exs \
  >"${SCRATCH}/policy-audit-tests.log" 2>&1

log "mix test tmux_janitor"
mise exec -- mix test test/casein/terminals/tmux_janitor_test.exs \
  >"${SCRATCH}/tmux-janitor-test.log" 2>&1

log "pre-push-check.sh"
bash scripts/pre-push-check.sh >"${SCRATCH}/precommit-final.log" 2>&1

# pre-push npm ci can delete tracked assets/node_modules; restore for clean tree.
if git status --porcelain | grep -q 'assets/node_modules'; then
  log "restore assets/node_modules after pre-push npm ci"
  git checkout -- assets/node_modules 2>/dev/null || true
fi

log "hardening-audit.sh"
bash scripts/hardening-audit.sh >"${SCRATCH}/hardening.log" 2>&1

log "goal deliverable manifest (${GOAL_BASE}..HEAD)"
{
  echo "# goal commits"
  git log --oneline "${GOAL_BASE}..HEAD"
  echo ""
  echo "# goal files (name-only)"
  git diff --name-only "${GOAL_BASE}..HEAD"
  echo ""
  echo "# goal diff stat"
  git diff --stat "${GOAL_BASE}..HEAD"
  echo ""
  echo "# worktree status (must be empty)"
  git status --porcelain
} >"${SCRATCH}/goal-deliverable-manifest.txt" 2>&1

git diff --name-only "${GOAL_BASE}..HEAD" >"${SCRATCH}/goal-deliverable-files.txt"
git diff --stat "${GOAL_BASE}..HEAD" >"${SCRATCH}/goal-diff-stat.txt" 2>&1
git log --oneline "${GOAL_BASE}..HEAD" >"${SCRATCH}/goal-commits.txt" 2>&1
cp "${SCRATCH}/goal-deliverable-files.txt" "${SCRATCH}/CHANGED_FILES"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: worktree dirty after evidence capture" >&2
  git status --short >&2
  exit 1
fi

log "goal-five evidence passed"
echo "SCRATCH=${SCRATCH}"
echo "GOAL_HEAD=$(git rev-parse --short HEAD)"