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

Environment: same as launch-devide-agent.sh (resolve via .devbox-agent.env or tmux).
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
  warn_degraded "session '${SESSION}' does not look like a DevIDE session (expected devide_* prefix)"
fi

CHECKOUT="${DEVIDE_CHECKOUT:-$ROOT}"
if [[ ! -d "$CHECKOUT" ]]; then
  echo "error: checkout not found at ${CHECKOUT}" >&2
  exit 1
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "error: tmux session not found: ${SESSION}" >&2
  exit 1
fi

WINDOW_NAME="$(spawn_worker_window_name "$TASK_SLUG")"
# Clear stale worktree pointers from tmux session env so each spawn gets a
# fresh agent/grok/<slug>-<stamp> worktree off the primary checkout.
LAUNCH_CMD="cd $(printf '%q' "$CHECKOUT") && unset DEVIDE_AGENT_WORKTREE_PATH DEVIDE_WORKTREE DEVIDE_GIT_DIR && DEVIDE_AGENT_TASK=$(printf '%q' "$TASK_SLUG") bash $(printf '%q' "${CHECKOUT}/scripts/launch-devide-agent.sh") $(printf '%q' "$RUNTIME")"

PANE_ID="$(
  tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -P -F '#{pane_id}' "$LAUNCH_CMD" 2>/dev/null ||
    tmux new-window -t "$SESSION" -P -F '#{pane_id}' "$LAUNCH_CMD"
)"

if [[ -z "$PANE_ID" ]]; then
  echo "error: tmux new-window did not return a pane id" >&2
  exit 1
fi

printf '%s\n' "$PANE_ID"