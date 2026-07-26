#!/usr/bin/env bash
#
# Remove stale Casein agent worktrees under the configured worktree root.
# Safe to run from cron or a systemd timer (nightly).
#
# Usage:
#   bash scripts/prune-old-worktrees.sh [--dry-run] [--days N]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/agent-worktree.sh
source "${ROOT}/scripts/lib/agent-worktree.sh"

DRY_RUN=0
MAX_AGE_DAYS="${DEVIDE_AGENT_WORKTREE_MAX_AGE_DAYS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --days)
      MAX_AGE_DAYS="${2:?--days requires a number}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '>>> [prune-worktrees] %s\n' "$*"; }

wt_root="$(agent_worktree_root)"
primary="$(agent_worktree_primary_repo 2>/dev/null || git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ ! -d "$wt_root" ]]; then
  log "nothing to prune (${wt_root} missing)"
  exit 0
fi

log "scanning ${wt_root} (max age ${MAX_AGE_DAYS}d)"

while IFS= read -r -d '' dir; do
  if [[ ! -d "$dir" ]]; then
    continue
  fi

  if [[ -n "$primary" ]] && [[ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)" == "$primary" ]] && ! agent_worktree_is_linked "$dir"; then
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would remove ${dir}"
  else
    log "removing ${dir}"
    if [[ -n "$primary" ]] && agent_worktree_is_linked "$dir"; then
      git -C "$primary" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
    else
      rm -rf "$dir"
    fi
  fi
done < <(find "$wt_root" -mindepth 1 -maxdepth 1 -type d -mtime "+${MAX_AGE_DAYS}" -print0 2>/dev/null || true)

if [[ -n "$primary" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would run: git -C ${primary} worktree prune"
  else
    git -C "$primary" worktree prune 2>/dev/null || true
  fi
fi

log "done"