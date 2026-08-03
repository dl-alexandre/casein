#!/usr/bin/env bash
#
# Retire duplicate agent-worktree runtime rows, keeping the newest row per
# worktree path.
#
# Backlog reaper for the insert loop fixed in Runtimes.list_agent_worktree_runtimes/2:
# `observe_worktree/2` used to look for the row it should update through an
# oldest-first, 500-row page of `list_runtimes/1`. Once a workspace's history
# filled that window the lookup always missed, so every worktree reconcile
# (every 15s, per worktree) inserted a fresh row instead of updating one. The
# duplicates are inert once the code fix ships — they just inflate
# `runtime_count` and the table — so this cleanup is hygiene, not a hotfix.
#
# Rows are marked `cleaned`, never deleted: `runtime_lifecycle_events` holds the
# append-only history that references them.
#
# Usage:
#   bash scripts/cleanup-duplicate-worktree-runtimes.sh              # dry run
#   bash scripts/cleanup-duplicate-worktree-runtimes.sh --apply
#
# Reads DATABASE_URL, or falls back to the casein-postgres-1 container.
#
set -euo pipefail

APPLY=0
CONTAINER="${CASEIN_POSTGRES_CONTAINER:-casein-postgres-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

psql_run() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "${DATABASE_URL/ecto:\/\//postgresql://}" -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "${CONTAINER}" psql -U "${POSTGRES_USER:-casein}" \
      -d "${POSTGRES_DB:-casein_prod}" -v ON_ERROR_STOP=1 "$@"
  fi
}

# A duplicate is a live agent-worktree row for a (workspace_id, worktree_path)
# that has a newer live sibling. The newest row per path always survives.
DUPLICATES_CTE="
  WITH ranked AS (
    SELECT id,
           workspace_id,
           worktree_path,
           row_number() OVER (
             PARTITION BY workspace_id, worktree_path
             ORDER BY created_at DESC, id DESC
           ) AS rank
    FROM workspace_runtimes
    WHERE isolation_mode = 'worktree'
      AND status NOT IN ('cleaned', 'expired')
      AND worktree_path IS NOT NULL
      AND (metadata->>'kind' = 'agent_worktree'
           OR metadata->>'provisioning_model' = 'agent_worktree')
  ),
  duplicates AS (SELECT * FROM ranked WHERE rank > 1)
"

echo "== duplicate agent-worktree runtime rows =="
psql_run -c "${DUPLICATES_CTE}
  SELECT workspace_id, worktree_path, count(*) AS duplicates
  FROM duplicates
  GROUP BY workspace_id, worktree_path
  ORDER BY duplicates DESC
  LIMIT 25;"

psql_run -tAc "${DUPLICATES_CTE} SELECT count(*) FROM duplicates;" \
  | xargs -I{} echo "total duplicate rows: {}"

if [[ "${APPLY}" -eq 0 ]]; then
  echo
  echo "dry run — re-run with --apply to mark these rows cleaned."
  exit 0
fi

echo
echo "marking duplicates as cleaned..."
psql_run -c "${DUPLICATES_CTE}
  UPDATE workspace_runtimes r
  SET status = 'cleaned',
      cleaned_at = now(),
      updated_at = now(),
      metadata = r.metadata || jsonb_build_object('cleaned_by', 'duplicate_worktree_runtime_cleanup')
  FROM duplicates d
  WHERE r.id = d.id;"

echo "done."
