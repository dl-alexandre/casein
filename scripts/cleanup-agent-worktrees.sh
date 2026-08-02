#!/usr/bin/env bash
#
# Remove leftover agent worktrees that are safe to drop: idle (no live tmux
# session running in them, not the current worktree) AND clean (no uncommitted
# changes, on a branch whose commits are already pushed to its upstream).
#
# Dirty worktrees, worktrees with unpushed/local-only commits, live ones, and
# the worktree you are standing in are ALWAYS kept.
#
# Dry-run by default — prints what it would remove. Pass --apply to actually
# remove them.
#
# Usage:
#   bash scripts/cleanup-agent-worktrees.sh            # dry run
#   bash scripts/cleanup-agent-worktrees.sh --apply    # delete clean+idle ones
#
# Env:
#   CASEIN_AGENT_WORKTREE_ROOT  worktree root (default $TMPDIR/casein-agent-worktrees)
#   CASEIN_TMUX_LABEL           tmux server label to probe for live panes (default casein)
set -euo pipefail

WT_ROOT="${CASEIN_AGENT_WORKTREE_ROOT:-${TMPDIR:-/tmp}/casein-agent-worktrees}"
TMUX_LABEL="${CASEIN_TMUX_LABEL:-casein}"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  ""|--dry-run) APPLY=0 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; exit 1 ;;
esac

[[ -d "$WT_ROOT" ]] || { echo "no worktree root at $WT_ROOT"; exit 0; }

# The primary checkout owns `git worktree remove`; resolve it once. Read the
# whole list before picking the first entry so the producer never sees SIGPIPE
# (which `set -o pipefail` would treat as fatal).
mapfile -t _worktrees < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
primary="${_worktrees[0]:-}"
self="$(pwd -P)"

# current_path of every pane in the Casein tmux server = "something is running
# here". This is the safety probe: if we CANNOT reach tmux we must not delete,
# because every worktree would look idle and a live one could be removed.
tmux_ok=0
if live_paths="$(tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_current_path}' 2>/dev/null)"; then
  live_paths="$(sort -u <<<"$live_paths")"
  tmux_ok=1
else
  live_paths=""
fi

if [[ "$APPLY" == "1" && "$tmux_ok" != "1" ]]; then
  echo "error: cannot reach tmux (-L $TMUX_LABEL) to verify which worktrees are live." >&2
  echo "       refusing to delete anything. (set CASEIN_TMUX_LABEL, or run as the tmux owner)" >&2
  exit 3
fi

is_live() { # $1 = worktree path
  [[ -n "$live_paths" ]] && grep -qF -- "$1" <<<"$live_paths"
}

removed=0; kept=0
for wt in "$WT_ROOT"/*/; do
  wt="${wt%/}"
  [[ -d "$wt" ]] || continue
  name="$(basename "$wt")"

  if [[ "$self" == "$wt" || "$self" == "$wt"/* ]]; then
    echo "keep    $name  (current worktree)"; kept=$((kept+1)); continue
  fi
  if is_live "$wt"; then
    echo "keep    $name  (live session)"; kept=$((kept+1)); continue
  fi
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "keep    $name  (not a git worktree)"; kept=$((kept+1)); continue
  fi
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    echo "keep    $name  (dirty — uncommitted changes)"; kept=$((kept+1)); continue
  fi

  upstream="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    # No upstream is NOT evidence of unpushed work. A detached HEAD has none by
    # definition, and detaching is routine here — verifying a merge by checking
    # out origin/master leaves the worktree detached and therefore pinned
    # forever under the old rule, even though it holds nothing.
    #
    # Ask the question that actually matters instead: is every commit reachable
    # from HEAD already present on some remote? `--not --remotes` errs toward
    # keeping (a squash-merged commit still looks unpushed), which is the right
    # direction for a deleter.
    unpushed="$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 1)"
    if [[ "$unpushed" != "0" ]]; then
      echo "keep    $name  (no upstream, $unpushed commit(s) on no remote)"
      kept=$((kept+1)); continue
    fi
    # Detached (or upstream-less) but fully published — fall through to removal.
  else
    ahead="$(git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1)"
    if [[ "$ahead" != "0" ]]; then
      echo "keep    $name  ($ahead unpushed commit(s))"; kept=$((kept+1)); continue
    fi
  fi

  # clean + idle + fully pushed → safe to remove
  if [[ "$APPLY" == "1" ]]; then
    if git -C "${primary:-$wt}" worktree remove "$wt" 2>/dev/null \
       || git -C "${primary:-$wt}" worktree remove --force "$wt" 2>/dev/null; then
      echo "removed $name"
    else
      echo "FAILED  $name  (git worktree remove errored — left in place)"
      kept=$((kept+1)); continue
    fi
  else
    echo "would remove  $name  (clean, idle, pushed)"
  fi
  removed=$((removed+1))
done

git worktree prune 2>/dev/null || true

if [[ "$APPLY" == "1" ]]; then
  echo "--- removed: $removed   kept: $kept ---"
else
  echo "--- would remove: $removed   kept: $kept   (re-run with --apply to delete) ---"
fi
