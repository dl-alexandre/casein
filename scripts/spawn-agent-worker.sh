#!/usr/bin/env bash
#
# Spawn a dedicated agent worker in a new tmux window and print its pane id.
#
# The launcher execs the agent in the *current* pane, so workers need a fresh
# window. Worktrees are created from the primary checkout (DEVIDE_CHECKOUT).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"

usage() {
  cat <<'EOF'
Usage: spawn-agent-worker.sh <runtime> <task-slug> [session]

Spawn an external agent in a new tmux window on the workspace session.

Arguments:
  runtime     grok | codex | claude | opencode | agent
  task-slug   short slug for branch/worktree naming (DEVIDE_AGENT_TASK)
  session     optional devide_* tmux session; defaults to DEVIDE_TMUX_SESSION
              or the current attached session

Prints the new pane id (e.g. %42) on stdout — use it for explicit-pane MCP calls.

Environment: same as launch-casein-agent.sh (resolve via .devbox-agent.env or tmux).
EOF
}

warn_degraded() {
  echo "warn: $*" >&2
}

spawn_worker_sanitize_slug() {
  local slug="$1"
  slug="${slug//[^A-Za-z0-9_-]/}"
  if [[ -z "$slug" ]]; then
    slug="adhoc"
  fi
  printf '%s\n' "${slug:0:48}"
}

spawn_worker_resolve_session() {
  local explicit="${1:-}"

  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  if [[ -n "${DEVIDE_TMUX_SESSION:-}" ]]; then
    printf '%s\n' "${DEVIDE_TMUX_SESSION}"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#{session_name}' 2>/dev/null || true
    return 0
  fi

  return 1
}

spawn_worker_window_name() {
  local slug="$1"
  printf 'worker-%s\n' "$(spawn_worker_sanitize_slug "$slug")"
}

# Resolve the primary (main) working tree for a candidate checkout.
#
# In an agent's environment DEVIDE_CHECKOUT points at *that agent's own* linked
# worktree, not the primary repo. Launching a worker there is a trap:
# agent_worktree_ensure adopts any linked worktree it is started inside instead
# of branching a fresh one (see scripts/lib/agent-worktree.sh), so the worker
# would silently share the orchestrator's checkout and branch. git lists the
# main working tree first in `worktree list`, so resolve to that — worktrees
# must be branched from the primary.
spawn_worker_resolve_primary_checkout() {
  local candidate="$1"
  local primary
  if primary="$(git -C "$candidate" worktree list --porcelain 2>/dev/null |
    awk '/^worktree /{print $2; exit}')" &&
    [[ -n "$primary" && -d "$primary" ]]; then
    printf '%s\n' "$primary"
    return 0
  fi
  printf '%s\n' "$candidate"
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 1
fi

RUNTIME="$1"
TASK_SLUG="$(spawn_worker_sanitize_slug "$2")"
SESSION_ARG="${3:-}"

case "$RUNTIME" in
  grok | codex | claude | opencode | agent) ;;
  *)
    echo "error: unsupported runtime '${RUNTIME}' (expected grok|codex|claude|opencode|agent)" >&2
    exit 1
    ;;
esac

agent_env_resolve

SESSION="$(spawn_worker_resolve_session "$SESSION_ARG")" || {
  echo "error: could not resolve tmux session — pass session explicitly" >&2
  exit 1
}

if [[ -z "$SESSION" ]]; then
  echo "error: empty tmux session name" >&2
  exit 1
fi

if [[ "$SESSION" != devide_* ]]; then
  warn_degraded "session '${SESSION}' does not look like a Casein session (expected devide_* prefix)"
fi

CHECKOUT="${DEVIDE_CHECKOUT:-$ROOT}"
if [[ ! -d "$CHECKOUT" ]]; then
  echo "error: checkout not found at ${CHECKOUT}" >&2
  exit 1
fi

# DEVIDE_CHECKOUT may point at the orchestrator's own linked worktree; the
# worker must branch off the primary repo, not launch inside it.
CHECKOUT="$(spawn_worker_resolve_primary_checkout "$CHECKOUT")"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "error: tmux session not found: ${SESSION}" >&2
  exit 1
fi

WINDOW_NAME="$(spawn_worker_window_name "$TASK_SLUG")"
# Clear stale worktree pointers and pin DEVIDE_CHECKOUT to the primary so each
# spawn gets a fresh agent/<runtime>/<slug>-<stamp> worktree off the primary
# checkout. Both matter: launch-casein-agent.sh keys worktree creation off the
# cwd *and* DEVIDE_CHECKOUT, and an inherited value would point back at the
# orchestrator's linked worktree. DEVIDE_AGENT_FORCE_FRESH_WORKTREE makes
# agent_worktree_ensure refuse to adopt whatever tree the launcher lands in
# (the cwd heuristic has proven unreliable from nested worktrees) and always
# branch a fresh one — so a worker can never operate in a shared checkout.
LAUNCH_CMD="cd $(printf '%q' "$CHECKOUT") && unset DEVIDE_AGENT_WORKTREE_PATH DEVIDE_WORKTREE DEVIDE_GIT_DIR && export DEVIDE_CHECKOUT=$(printf '%q' "$CHECKOUT") DEVIDE_AGENT_FORCE_FRESH_WORKTREE=1 && DEVIDE_AGENT_TASK=$(printf '%q' "$TASK_SLUG") bash $(printf '%q' "${CHECKOUT}/scripts/launch-casein-agent.sh") $(printf '%q' "$RUNTIME")"

if [[ "${DEVIDE_SPAWN_DRY_RUN:-0}" == "1" ]]; then
  printf 'session=%s\ncheckout=%s\nwindow=%s\nlaunch=%s\n' \
    "$SESSION" "$CHECKOUT" "$WINDOW_NAME" "$LAUNCH_CMD"
  exit 0
fi

PANE_ID="$(
  tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -P -F '#{pane_id}' "$LAUNCH_CMD" 2>/dev/null ||
    tmux new-window -t "$SESSION" -P -F '#{pane_id}' "$LAUNCH_CMD"
)"

if [[ -z "$PANE_ID" ]]; then
  echo "error: tmux new-window did not return a pane id" >&2
  exit 1
fi

printf '%s\n' "$PANE_ID"