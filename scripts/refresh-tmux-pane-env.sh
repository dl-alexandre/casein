#!/usr/bin/env bash
#
# Repair Casein tmux session environment for agent panes.
#
# Usage:
#   bash scripts/refresh-tmux-pane-env.sh                           # all casein_* sessions
#   bash scripts/refresh-tmux-pane-env.sh --workspace-prefix NAME   # casein_NAME_* only
#   bash scripts/refresh-tmux-pane-env.sh <session>                   # one session
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-prefix)
      WORKSPACE_PREFIX="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,9p' "$0"
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
    bash "$REPAIR" "$session"
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
    bash "$REPAIR" "$session"
  done
fi

log "done"