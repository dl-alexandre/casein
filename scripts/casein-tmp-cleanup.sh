#!/usr/bin/env bash
#
# casein-tmp-cleanup.sh — age-prune Casein ephemeral entries in the temp dir so
# they cannot fill the (small) root filesystem. `/tmp` on the devbox is NOT a
# separate mount, so every leaked temp dir counts against `/`.
#
# Targets (matched at depth 1 under $TMPDIR, default /tmp):
#   credo-diff-*        full working-tree snapshots from credo --diff (~330M each)
#   ghostty_snapshot_*  diagnostic terminal dumps (runtime self-prunes; this is a backstop)
#   <test-artifact-*>   ExUnit workspace roots (tests now clean via on_exit; backstop for
#                       crashed runs — see Casein.TmpWorkspace)
#
# NEVER touches `casein-agent-worktrees` — those are git worktrees with their own
# git-aware janitor (scripts/cleanup-agent-worktrees.sh). Age filtering means
# anything currently in use (recent mtime) is always kept.
#
# Dry-run by default — prints what it would remove and the reclaimable size.
# Pass --apply to actually delete.
#
# Usage:
#   bash scripts/casein-tmp-cleanup.sh            # dry run
#   bash scripts/casein-tmp-cleanup.sh --apply    # delete aged ephemera
#
# Env:
#   TMPDIR                            temp root (default /tmp)
#   CASEIN_TMP_CREDO_AGE_DAYS         credo-diff min age in days (default 2)
#   CASEIN_TMP_ARTIFACT_AGE_DAYS      test/ghostty artifact min age in days (default 1)
set -euo pipefail

TMP_ROOT="${TMPDIR:-/tmp}"
CREDO_AGE_DAYS="${CASEIN_TMP_CREDO_AGE_DAYS:-2}"
ARTIFACT_AGE_DAYS="${CASEIN_TMP_ARTIFACT_AGE_DAYS:-1}"

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  ""|--dry-run) APPLY=0 ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; exit 1 ;;
esac

[[ -d "$TMP_ROOT" ]] || { echo "no temp root at $TMP_ROOT"; exit 0; }

# Pure-ephemera glob prefixes (test artifacts + runtime diagnostic dumps +
# leftover agent/build scratch). Each is a `find -name` glob at maxdepth 1.
# NEVER include `casein-agent-worktrees` — those have a git-aware janitor.
ARTIFACT_GLOBS=(
  'ghostty_snapshot_*'
  'preview-pane-*'
  'preview-panes-*'
  'preview-panes-offload-*'
  'file-pane-events-*'
  'file-pane-beh-*'
  'file-panes-*'
  'file-panes-offload-*'
  'file-server-*'
  'pane-events-*'
  'mcp-open-file-*'
  'uat-vis-*'
  'uat-artifacts-*'
  'uat-scn-*'
  'casein-tmux-test-*'
  'casein-test-instances-*'
  'casein-scrollback-test-*'
  'summary-transcript-*'
  # Devbox root-fs pressure: orphaned agent/build scratch under /tmp.
  'ruby-build.*'
  'onebackend-*'
  'one-pr*'
  'one-dev-*'
  'pr-[0-9]*'
  'pr[0-9]*'
  'ob3-*'
  'facility-*'
  'site_setup_*'
  'arch-commit-*'
  'mtinker-*'
  'casein-codex-*'
  'casein-deploy-*'
  'casein-integrate-*'
  'casein-pr*'
  'casein-rebase-*'
  'casein-release-*'
  'casein-autodeploy-*'
  'devide-agent-worktrees'
  'tmp.*'
)

total_kb=0
count=0

sweep() { # $1 = glob   $2 = min age (days)
  local glob="$1" age="$2" p sz
  while IFS= read -r -d '' p; do
    sz="$(du -sk "$p" 2>/dev/null | cut -f1)"
    total_kb=$((total_kb + ${sz:-0}))
    count=$((count + 1))
    if [[ "$APPLY" == "1" ]]; then
      # Best-effort: some trees mix root-owned sandbox mounts; skip failures.
      if rm -rf "$p" 2>/dev/null; then
        :
      else
        echo "skip    $p  (permission denied or busy)" >&2
        total_kb=$((total_kb - ${sz:-0}))
        count=$((count - 1))
        continue
      fi
    else
      echo "would remove  $p  (${sz:-0} KB)"
    fi
  done < <(find "$TMP_ROOT" -maxdepth 1 -mindepth 1 -name "$glob" -mtime "+$age" -print0 2>/dev/null)
}

sweep 'credo-diff-*' "$CREDO_AGE_DAYS"
for g in "${ARTIFACT_GLOBS[@]}"; do
  sweep "$g" "$ARTIFACT_AGE_DAYS"
done

verb="would remove"
[[ "$APPLY" == "1" ]] && verb="removed"
printf -- '--- %s: %d entries, %d MB (%s) ---\n' \
  "$verb" "$count" "$((total_kb / 1024))" "$TMP_ROOT"
