#!/usr/bin/env bash
#
# Repair Casein tmux session environment for agent panes.
#
# Usage:
#   bash scripts/refresh-tmux-pane-env.sh                           # all casein_* sessions
#   bash scripts/refresh-tmux-pane-env.sh --workspace-prefix NAME   # casein_NAME_* only
#   bash scripts/refresh-tmux-pane-env.sh <session>                   # one session
#
# Visits every matching session even when one cannot be repaired. Exit 0
# only when every session was repaired or was a benign non-casein skip.
# A casein session that skipped (unknown workspace / missing token) or
# failed listing makes this command exit 1 so a fleet refresh cannot
# report "done" while leaving panes unrepaired.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Labeled tmux only — bare tmux follows $TMUX / default server (#248).
# shellcheck source=lib/tmux-label.sh
source "${ROOT}/scripts/lib/tmux-label.sh"
REPAIR="${ROOT}/scripts/lib/repair-tmux-env.sh"

log() { printf '>>> %s\n' "$*"; }

WORKSPACE_PREFIX=""
SESSIONS=()
UNREPAIRED=0

# Capture repair status per session. A bare `bash "$REPAIR"` under `set -e`
# would abort the loop on the first actionable skip (exit 2/3) and hide the
# rest of the fleet. Continue, then fail the command if any casein session
# that should have been repaired was not.
run_repair() {
  local session="$1"
  local out err status outcome
  out="$(mktemp)"
  err="$(mktemp)"
  set +e
  bash "$REPAIR" "$session" >"$out" 2>"$err"
  status=$?
  set -e
  outcome="$(tr -d '\n' <"$out")"
  if [[ -s "$err" ]]; then
    cat "$err" >&2
  fi
  rm -f "$out" "$err"

  if [[ "$status" -ne 0 ]]; then
    log "unrepaired ${session} (${outcome:-exit ${status}})"
    UNREPAIRED=$((UNREPAIRED + 1))
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-prefix)
      WORKSPACE_PREFIX="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      SESSIONS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#SESSIONS[@]} -gt 0 ]]; then
  for session in "${SESSIONS[@]}"; do
    run_repair "$session"
  done
else
  pattern='^casein_'
  if [[ -n "$WORKSPACE_PREFIX" ]]; then
    pattern="^casein_${WORKSPACE_PREFIX}_"
  fi

  mapfile -t sessions < <(casein_tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "$pattern" || true)
  if [[ ${#sessions[@]} -eq 0 ]]; then
    log "no matching casein tmux sessions found"
    exit 0
  fi

  for session in "${sessions[@]}"; do
    run_repair "$session"
  done
fi

if [[ "$UNREPAIRED" -ne 0 ]]; then
  log "done (${UNREPAIRED} session(s) unrepaired)"
  exit 1
fi

log "done"