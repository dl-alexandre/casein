#!/usr/bin/env bash
#
# End-to-end smoke test for scripts/spawn-agent-worker.sh: spawn a real worker,
# prove an agent process is actually running in the window it printed, then take
# the window and its worktree back down.
#
# The unit tests drive the readiness logic against stub tmux/ps. This drives the
# real thing, and verifies the result *independently* of the code under test —
# it re-reads the pane's process tree itself rather than trusting the exit code —
# so a readiness check that silently stops checking still fails here.
#
# Usage: smoke-spawn-agent-worker.sh [runtime] [--keep]
#
#   runtime   grok | codex | claude | opencode | agent (default: claude)
#   --keep    leave the worker window and worktree in place
#
# Requires a paired Casein tmux session (run it from an agent pane, or export
# CASEIN_TMUX_SESSION). Exits 0 only when the spawned window holds a live agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Labeled tmux only — bare tmux follows $TMUX / default server (#248).
# shellcheck source=lib/tmux-label.sh
source "${ROOT}/scripts/lib/tmux-label.sh"

RUNTIME="claude"
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) RUNTIME="$arg" ;;
  esac
done

say() { printf 'smoke: %s\n' "$*" >&2; }
fail() {
  printf 'smoke: FAIL — %s\n' "$*" >&2
  exit 1
}

SLUG="smoke-$(date +%H%M%S)"
say "spawning a ${RUNTIME} worker as ${SLUG}"

START="$(date +%s)"
if ! PANE_ID="$(bash "${ROOT}/scripts/spawn-agent-worker.sh" "$RUNTIME" "$SLUG")"; then
  fail "spawn-agent-worker.sh exited non-zero (see its stderr above)"
fi
ELAPSED=$(($(date +%s) - START))

[[ "$PANE_ID" == %* ]] || fail "expected a pane id on stdout, got: ${PANE_ID}"
say "got ${PANE_ID} after ${ELAPSED}s"

cleanup() {
  if ((KEEP == 1)); then
    say "--keep: leaving ${PANE_ID} and its worktree in place"
    return 0
  fi

  local worktree=""
  worktree="$(casein_tmux display-message -p -t "$PANE_ID" '#{pane_current_path}' 2>/dev/null || true)"
  casein_tmux kill-window -t "$PANE_ID" 2>/dev/null || true

  # Only worktrees this smoke run created, and only when clean — `git worktree
  # remove` without --force is the second net.
  if [[ "$worktree" == *"/agent-${RUNTIME}-${SLUG}-"* && -d "$worktree" ]]; then
    git -C "$worktree" worktree remove "$worktree" >/dev/null 2>&1 ||
      git -C "$ROOT" worktree remove "$worktree" >/dev/null 2>&1 || true
  fi
  say "cleaned up ${PANE_ID}"
}
trap cleanup EXIT

# Independent verification: walk the pane's own process tree and look for
# something that is plainly the agent rather than a shell. Deliberately does not
# reuse the helpers in spawn-agent-worker.sh — this is the check on that check.
PANE_PID="$(casein_tmux display-message -p -t "$PANE_ID" '#{pane_pid}' 2>/dev/null || true)"
[[ -n "$PANE_PID" ]] || fail "pane ${PANE_ID} is gone — spawn printed a dead pane id"

TREE="$(
  ps -eww -o pid=,ppid=,args= |
    PANE_PID="$PANE_PID" awk '
      BEGIN { root = ENVIRON["PANE_PID"] }
      { parent[$1] = $2; line[$1] = $0; pids[++n] = $1 }
      END {
        for (i = 1; i <= n; i++) {
          cursor = pids[i]
          for (depth = 0; depth < 64 && (cursor in parent); depth++) {
            if (cursor == root) { print line[pids[i]]; break }
            cursor = parent[cursor]
          }
        }
      }
    '
)"

say "pane process tree:"
printf '%s\n' "$TREE" | sed 's/^/  /' | cut -c1-160 >&2

if ! printf '%s\n' "$TREE" | grep -qE "(^|/)(${RUNTIME}|claude[.]exe|codex[.]js|grok)( |\$)"; then
  fail "no ${RUNTIME} process under pane ${PANE_ID} — spawn reported success for a window that holds only a shell"
fi

CURRENT="$(casein_tmux display-message -p -t "$PANE_ID" '#{pane_current_command}' 2>/dev/null || true)"
say "pane_current_command=${CURRENT}"
case "$CURRENT" in
  bash | sh | zsh | fish | dash)
    fail "pane ${PANE_ID} is sitting at a shell prompt (${CURRENT})"
    ;;
esac

say "PASS — ${PANE_ID} is running ${RUNTIME}"
