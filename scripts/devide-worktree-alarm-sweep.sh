#!/usr/bin/env bash
#
# devide-worktree-alarm-sweep.sh — detect stale agent worktrees needing attention.
#
# Alarms (log + audit) on worktrees that are dirty or unreported, have no live
# agent process, are older than the TTL (default 24h), and lack an exit handoff
# (push/PR, wip: commit, or terminal_report_worktree exit_status). Never deletes.
#
# Usage:
#   scripts/devide-worktree-alarm-sweep.sh              # release RPC sweep
#   scripts/devide-worktree-alarm-sweep.sh --dry-run    # same, explicit
#   DEVIDE_WORKTREE_ALARM_TTL_SECONDS=86400 scripts/...
#
set -euo pipefail

MODE="sweep"
TTL_SECONDS="${DEVIDE_WORKTREE_ALARM_TTL_SECONDS:-86400}"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
RELEASE_BIN="${DEVIDE_RELEASE_BIN:-/opt/devide/release/bin/dev_ide}"

usage() {
  sed -n '2,13p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--sweep)
      MODE="sweep"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

run_release_sweep() {
  local unit node cookie expr

  unit="$(
    { systemctl list-units 'devide-*.service' --state=active --no-legend --plain 2>/dev/null || true; } |
      awk '$1 ~ /^devide-[0-9a-f]+\.service$/ {print $1; exit}'
  )"

  if [[ -z "$unit" ]]; then
    echo "devide worktree alarm: no active devide canary unit found" >&2
    exit 1
  fi

  node="$(
    systemctl show "$unit" -p Environment --value |
      tr ' ' '\n' |
      awk -F= '/^RELEASE_NODE=/{print $2; exit}'
  )"

  if [[ -z "$node" ]]; then
    echo "devide worktree alarm: RELEASE_NODE missing from $unit" >&2
    exit 1
  fi

  cookie="$(awk -F= '/^RELEASE_COOKIE=/{print $2}' "$ENV_FILE" | tail -1)"

  if [[ -z "$cookie" ]]; then
    echo "devide worktree alarm: RELEASE_COOKIE missing from $ENV_FILE" >&2
    exit 1
  fi

  expr="IO.inspect(DevIDE.Runtimes.WorktreeAlarm.sweep_now(ttl_seconds: ${TTL_SECONDS}), limit: :infinity)"

  local rpc_env=(
    RELEASE_NODE="$node"
    RELEASE_COOKIE="$cookie"
    RELEASE_DISTRIBUTION=sname
  )

  if [[ "$(id -un)" == "devbox" ]]; then
    env "${rpc_env[@]}" "$RELEASE_BIN" rpc "$expr"
  else
    runuser -u devbox -- env "${rpc_env[@]}" "$RELEASE_BIN" rpc "$expr"
  fi
}

case "$MODE" in
  sweep) run_release_sweep ;;
esac