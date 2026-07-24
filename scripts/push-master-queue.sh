#!/usr/bin/env bash
# Serialize pushes to origin/master with automatic rebase-and-retry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOCK_FILE="${PUSH_MASTER_QUEUE_LOCK:-/tmp/casein-push-master-queue.lock}"
LOCK_WAIT="${PUSH_MASTER_QUEUE_WAIT:-3600}"
MAX_ATTEMPTS="${PUSH_MASTER_QUEUE_ATTEMPTS:-12}"
SLEEP_SECS="${PUSH_MASTER_QUEUE_SLEEP:-5}"
NO_VERIFY=0
for arg in "$@"; do
  case "$arg" in --no-verify) NO_VERIFY=1 ;; esac
done
log() { printf '>>> [push-master-queue] %s\n' "$*"; }
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" 9; then
  echo "push-master-queue: lock held >${LOCK_WAIT}s" >&2
  exit 1
fi
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  log "attempt ${attempt}/${MAX_ATTEMPTS}"
  git fetch origin master
  if ! git rebase origin/master; then
    git rebase --abort || true
    sleep "$SLEEP_SECS"
    continue
  fi
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "master" && "$NO_VERIFY" != "1" ]]; then
    bash scripts/pre-push-check.sh
  fi
  if git push origin "$branch" ${NO_VERIFY:+--no-verify}; then
    log "push succeeded"
    exit 0
  fi
  sleep "$SLEEP_SECS"
done
echo "push-master-queue: exhausted ${MAX_ATTEMPTS} attempts" >&2
exit 1