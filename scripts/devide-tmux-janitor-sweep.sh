#!/usr/bin/env bash
#
# devide-tmux-janitor-sweep.sh — reap LEAKED test tmux sessions.
#
# Test runs (WorkspacePaneSplitTest's `alpha-<N>`, the `*-ws-<N>` preview/header
# fixtures, PaneWorker's `pw-test`) create real tmux sessions and reap them in
# `on_exit`. When a test crashes or is killed (common under full-suite load on
# this shared box), the session leaks. The in-app TmuxWindowJanitor cleans
# WINDOWS, not whole orphaned sessions, so they accumulate — 250+ observed,
# which itself adds tmux-server contention that worsens the very flakiness that
# leaks them. This sweep reaps them.
#
# SAFETY: only sessions that (a) match a strict TEST workspace-name pattern,
# (b) are UNATTACHED, and (c) are older than the age threshold are touched —
# and any name carrying a real owner/workspace token is hard-excluded. Real
# multi-tenant workspaces (dalexandre-*, jgiles-*, mbaldin-*, msoares-*, the
# preview-sandbox) are never matched.
#
# DRY RUN BY DEFAULT — prints the plan and kills nothing. Pass --apply to reap.
# The systemd timer runs it with --apply; humans/agents can run it bare to audit.
#
# Usage:
#   scripts/devide-tmux-janitor-sweep.sh            # dry run (plan only)
#   scripts/devide-tmux-janitor-sweep.sh --apply    # actually reap
#   DEVIDE_TMUX_REAP_AGE_MIN=60 scripts/...         # override 30-min threshold
set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
AGE_MIN="${DEVIDE_TMUX_REAP_AGE_MIN:-30}"

command -v tmux >/dev/null 2>&1 || { echo "[tmux-janitor] tmux not found — nothing to do"; exit 0; }

# Strict test-workspace patterns: alpha-<digits>, <slug>-ws-<digits>, pw-test.
TEST_RE='^devide_([a-z]+-)?(alpha-[0-9]+|[a-z0-9]+-ws-[0-9]+|pw-test)'
# Belt-and-suspenders: never touch a session naming a real owner/workspace.
KEEP_RE='dalexandre|mbaldin|msoares|jgiles|integration|devbox|documentation|preview-sandbox|v3-first'

now="$(date +%s)"
mapfile -t cands < <(
  tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null |
    awk -F'|' -v now="$now" -v age="$AGE_MIN" -v test="$TEST_RE" -v keep="$KEEP_RE" \
      '$2==0 && (now-$3)>(age*60) && $1 ~ test && $1 !~ keep {print $1}'
)

n=${#cands[@]}
ts="$(date -u +%FT%TZ)"
echo "[tmux-janitor] ${ts} candidates=${n} (unattached, >${AGE_MIN}m, test-pattern) apply=${APPLY}"

if [ "$n" -eq 0 ]; then
  echo "[tmux-janitor] nothing to reap"
  exit 0
fi

if [ "$APPLY" = 1 ]; then
  reaped=0
  for s in "${cands[@]}"; do
    tmux kill-session -t "$s" 2>/dev/null && reaped=$((reaped + 1)) || true
  done
  echo "[tmux-janitor] reaped ${reaped}/${n} leaked test sessions"
else
  echo "[tmux-janitor] would reap (by prefix):"
  printf '%s\n' "${cands[@]}" | sed -E 's/_u-.*//; s/devide_//; s/[0-9]+/N/g' | sort | uniq -c | sort -rn
  echo "[tmux-janitor] DRY RUN — re-run with --apply to reap ${n} sessions"
fi
