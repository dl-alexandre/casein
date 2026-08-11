#!/usr/bin/env bash
#
# Remove leftover agent worktrees that are safe to drop: idle (no live tmux
# session running in them, not the current worktree) AND clean (no uncommitted
# product changes, every HEAD commit already present on some remote).
#
# Dirty worktrees, worktrees with unpushed/local-only commits, live ones, and
# the worktree you are standing in are ALWAYS kept.
#
# Unpushed detection is ALWAYS:
#   git rev-list --count HEAD --not --remotes
# Never trust @{u}/ahead alone: a deleted remote-tracking branch leaves @{u}
# stale (or literal "@{u}"), and squash-merged tips can still sit on another
# remote ref. --not --remotes errs toward keeping when a squash tip is unique.
#
# After a successful worktree remove, the local branch is deleted only when it
# is fully merged into the repo default branch (or cherry-equivalent). Otherwise
# the branch is left — `git worktree remove` does not delete branches.
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
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; exit 1 ;;
esac

[[ -d "$WT_ROOT" ]] || { echo "no worktree root at $WT_ROOT"; exit 0; }

# The worktree root is SHARED across repositories (and users): the agent
# worktrees under it may belong to casein, mira, or anything else on the box.
# Resolving the removing repo once from the CURRENT directory was wrong — every
# eligibility check below already asks the worktree's own repo via `git -C`, but
# the removal used the current repo, so a foreign worktree passed every check,
# was advertised as "would remove", and then failed with "is not a working
# tree". A dry run that promises cleanup it cannot deliver is worse than one
# that declines: resolve the owner per worktree instead.
#
# The first entry of `worktree list` is the repo's MAIN worktree, which is the
# one that can remove the others. Read the whole list before taking an entry so
# the producer never sees SIGPIPE (which `set -o pipefail` would treat as fatal).
owner_worktree() { # $1 = worktree path -> main worktree of the owning repo, or ""
  local -a list
  mapfile -t list < <(git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  printf '%s\n' "${list[0]:-}"
}

self_repo="$(owner_worktree .)"
self="$(pwd -P)"
declare -A pruned_repos=()

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
  local p="$1"
  [[ -n "$live_paths" ]] || return 1
  # Exact match or pane cwd inside the worktree.
  grep -qF -- "$p" <<<"$live_paths" && return 0
  while IFS= read -r live; do
    [[ -n "$live" ]] || continue
    [[ "$live" == "$p"/* ]] && return 0
  done <<<"$live_paths"
  return 1
}

# Agent launchers drop ephemeral files that are gitignored in primary checkouts
# but still dirty a worktree when the ignore rule is missing, the file is
# tracked, or a lock was deleted. None of these are product work.
is_noise_status_line() {
  local line="$1" path
  path="${line:3}"
  path="${path#\"}"
  path="${path%\"}"
  case "$path" in
    .cursor|.cursor/*) return 0 ;;
    .claude/scheduled_tasks.lock) return 0 ;;
    .claude/plans/*) return 0 ;;
    .opencode|.opencode/*) return 0 ;;
    native/casein_mob/priv/*) return 0 ;;
    _build|_build/*) return 0 ;;
    deps|deps/*) return 0 ;;
    cover|cover/*) return 0 ;;
    .elixir_ls|.elixir_ls/*) return 0 ;;
    .lexical|.lexical/*) return 0 ;;
    WORKER_BRIEF.md|TASK.md|TASK-*.md|*_HANDOFF.md) return 0 ;;
    .git-grok-reinit-backup|.git-grok-reinit-backup/*) return 0 ;;
    .git-grok-reinit-backup-2|.git-grok-reinit-backup-2/*) return 0 ;;
    .git.worktree-pointer|.git.casein-pointer|.git.casein-gitlink|.agent-base-revision) return 0 ;;
    tmp_*/*|tmp_*) return 0 ;;
  esac
  return 1
}

# Returns 0 when porcelain has any non-noise change (real dirty).
has_real_dirt() { # $1 = worktree
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! is_noise_status_line "$line"; then
      return 0
    fi
  done < <(git -C "$1" status --porcelain 2>/dev/null)
  return 1
}

# Commits on HEAD not present on any remote-tracking ref. The only unpushed
# signal this script trusts (see header).
unpushed_count() { # $1 = worktree
  local n
  n="$(git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo 1)"
  # Non-numeric → treat as unpushed (keep).
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  printf '%s\n' "$n"
}

default_branch_ref() { # $1 = owner main worktree -> origin/master|origin/main|...
  local owner="$1" sym
  sym="$(git -C "$owner" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$sym" ]]; then
    printf '%s\n' "$sym"
    return 0
  fi
  for cand in refs/remotes/origin/master refs/remotes/origin/main refs/remotes/origin/develop; do
    if git -C "$owner" rev-parse -q --verify "$cand" >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# True when branch tip is fully contained in default remote branch OR every
# unique commit is cherry-equivalent (squash-merge safe enough for local -d).
branch_safe_to_delete() { # $1 = owner  $2 = local branch name  $3 = tip sha (optional)
  local owner="$1" branch="$2" tip="${3:-}" def
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 1
  case "$branch" in
    master|main|develop|trunk) return 1 ;;
  esac
  def="$(default_branch_ref "$owner" || true)"
  [[ -n "$def" ]] || return 1
  if [[ -z "$tip" ]]; then
    tip="$(git -C "$owner" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)"
  fi
  [[ -n "$tip" ]] || return 1
  if git -C "$owner" merge-base --is-ancestor "$tip" "$def" 2>/dev/null; then
    return 0
  fi
  # cherry: lines starting with + are unique patches; - are already applied.
  local cherry plus=0
  cherry="$(git -C "$owner" cherry -v "$def" "$tip" 2>/dev/null || true)"
  plus="$(printf '%s\n' "$cherry" | grep -c '^+ ' || true)"
  [[ "$plus" == "0" ]]
}

maybe_delete_branch() { # $1 = owner  $2 = branch  $3 = apply?
  local owner="$1" branch="$2" apply="$3"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 0
  if ! git -C "$owner" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    return 0
  fi
  if branch_safe_to_delete "$owner" "$branch"; then
    if [[ "$apply" == "1" ]]; then
      if git -C "$owner" branch -d "$branch" 2>/dev/null \
         || git -C "$owner" branch -D "$branch" 2>/dev/null; then
        echo "  branch-deleted  $branch"
      else
        echo "  branch-kept     $branch  (delete failed)"
      fi
    else
      echo "  would delete branch  $branch  (merged/cherry-eq into default)"
    fi
  else
    echo "  branch-kept     $branch  (unmerged unique commits — worktree only)"
  fi
}

removed=0; kept=0; branches_deleted=0
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

  # Resolve owner early — also used for common-dir safety.
  owner="$(owner_worktree "$wt")"
  if [[ -z "$owner" ]]; then
    echo "keep    $name  (cannot resolve owning repo)"; kept=$((kept+1)); continue
  fi
  if [[ "$owner" == "$wt" ]]; then
    echo "keep    $name  (main worktree of its repo, not an agent leftover)"
    kept=$((kept+1)); continue
  fi

  if has_real_dirt "$wt"; then
    echo "keep    $name  (dirty — uncommitted changes)"; kept=$((kept+1)); continue
  fi

  unpushed="$(unpushed_count "$wt")"
  if [[ "$unpushed" != "0" ]]; then
    echo "keep    $name  ($unpushed unpushed commit(s) — HEAD not on any remote)"
    kept=$((kept+1)); continue
  fi

  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  tip="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"

  foreign=""
  [[ -n "$self_repo" && "$owner" != "$self_repo" ]] && foreign="  [owner: $owner]"

  # clean + idle + fully pushed → safe to remove worktree
  if [[ "$APPLY" == "1" ]]; then
    if git -C "$owner" worktree remove "$wt" 2>/dev/null \
       || git -C "$owner" worktree remove --force "$wt" 2>/dev/null; then
      echo "removed $name$foreign"
      pruned_repos["$owner"]=1
      # Branch may still exist on owner after worktree remove.
      if [[ "$branch" != "HEAD" ]]; then
        if branch_safe_to_delete "$owner" "$branch" "$tip"; then
          if git -C "$owner" branch -d "$branch" 2>/dev/null \
             || git -C "$owner" branch -D "$branch" 2>/dev/null; then
            echo "  branch-deleted  $branch"
            branches_deleted=$((branches_deleted+1))
          else
            echo "  branch-kept     $branch  (delete failed)"
          fi
        else
          echo "  branch-kept     $branch  (unmerged unique commits — worktree only)"
        fi
      fi
    else
      echo "FAILED  $name  (git worktree remove errored — left in place)$foreign"
      kept=$((kept+1)); continue
    fi
  else
    echo "would remove  $name  (clean, idle, pushed)$foreign"
    if [[ "$branch" != "HEAD" ]]; then
      maybe_delete_branch "$owner" "$branch" 0
    fi
  fi
  removed=$((removed+1))
done

# Prune every repo we touched, not just the current one — a foreign repo would
# otherwise keep a stale administrative entry for a directory we just deleted.
pruned_repos["${self_repo:-$PWD}"]=1
for repo in "${!pruned_repos[@]}"; do
  git -C "$repo" worktree prune 2>/dev/null || true
done

if [[ "$APPLY" == "1" ]]; then
  echo "--- removed: $removed   kept: $kept   branches_deleted: $branches_deleted ---"
else
  echo "--- would remove: $removed   kept: $kept   (re-run with --apply to delete) ---"
fi
