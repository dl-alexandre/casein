#!/usr/bin/env bash
#
# devide-tmux-janitor-sweep.sh — tmux janitor entrypoints.
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
# The systemd timer runs the release RPC sweep explicitly; humans/agents can run
# the test-leak mode bare to audit leaked test sessions.
#
# Usage:
#   scripts/devide-tmux-janitor-sweep.sh            # dry run (plan only)
#   scripts/devide-tmux-janitor-sweep.sh --apply    # actually reap
#   scripts/devide-tmux-janitor-sweep.sh --release-sweep
#   scripts/devide-tmux-janitor-sweep.sh --dry-run  # release policy dry-run
#   DEVIDE_TMUX_REAP_AGE_MIN=60 scripts/...         # override 30-min threshold
set -euo pipefail

MODE="test-leaks"
APPLY=0
AGE_MIN="${DEVIDE_TMUX_REAP_AGE_MIN:-30}"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/devide/devide.env}"
RELEASE_BIN="${DEVIDE_RELEASE_BIN:-/opt/devide/release/bin/casein}"

usage() {
  sed -n '2,27p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      MODE="test-leaks"
      APPLY=1
      shift
      ;;
    --test-leaks)
      MODE="test-leaks"
      shift
      ;;
    --release-sweep)
      MODE="release-sweep"
      shift
      ;;
    --dry-run|--release-dry-run)
      MODE="release-dry-run"
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

run_test_leak_sweep() {
  command -v tmux >/dev/null 2>&1 || { echo "[tmux-janitor] tmux not found — nothing to do"; exit 0; }

  # Strict test-workspace patterns: alpha-<digits>, <slug>-ws-<digits>, pw-test.
  local test_re='^devide_([a-z]+-)?(alpha-[0-9]+|[a-z0-9]+-ws-[0-9]+|pw-test)'
  # Belt-and-suspenders: never touch a session naming a real owner/workspace.
  local keep_re='dalexandre|mbaldin|msoares|jgiles|integration|devbox|documentation|preview-sandbox|v3-first'
  local now ts n
  local -a cands
  now="$(date +%s)"
  mapfile -t cands < <(
    tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null |
      awk -F'|' -v now="$now" -v age="$AGE_MIN" -v test="$test_re" -v keep="$keep_re" \
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
    local reaped=0
    for s in "${cands[@]}"; do
      tmux kill-session -t "$s" 2>/dev/null && reaped=$((reaped + 1)) || true
    done
    echo "[tmux-janitor] reaped ${reaped}/${n} leaked test sessions"
  else
    echo "[tmux-janitor] would reap (by prefix):"
    printf '%s\n' "${cands[@]}" | sed -E 's/_u-.*//; s/devide_//; s/[0-9]+/N/g' | sort | uniq -c | sort -rn
    echo "[tmux-janitor] DRY RUN — re-run with --apply to reap ${n} sessions"
  fi
}

run_release_sweep() {
  local rpc_mode="$1" unit node cookie expr

  unit="$(
    { systemctl list-units 'devide-*.service' --state=active --no-legend --plain 2>/dev/null || true; } |
      awk '$1 ~ /^devide-[0-9a-f]+\.service$/ {print $1; exit}'
  )"

  if [[ -z "$unit" ]]; then
    echo "devide tmux janitor: no active devide canary unit found" >&2
    exit 1
  fi

  node="$(
    systemctl show "$unit" -p Environment --value |
      tr ' ' '\n' |
      awk -F= '/^RELEASE_NODE=/{print $2; exit}'
  )"

  if [[ -z "$node" ]]; then
    echo "devide tmux janitor: RELEASE_NODE missing from $unit" >&2
    exit 1
  fi

  cookie="$(awk -F= '/^RELEASE_COOKIE=/{print $2}' "$ENV_FILE" | tail -1)"

  if [[ -z "$cookie" ]]; then
    echo "devide tmux janitor: RELEASE_COOKIE missing from $ENV_FILE" >&2
    exit 1
  fi

  case "$rpc_mode" in
    dry-run)
      expr='case Code.ensure_loaded(Casein.Terminals.TmuxWindowJanitor) do
  {:module, Casein.Terminals.TmuxWindowJanitor} ->
    if function_exported?(Casein.Terminals.TmuxWindowJanitor, :dry_run_now, 0) do
      IO.inspect(Casein.Terminals.TmuxWindowJanitor.dry_run_now(), limit: :infinity)
    else
      IO.puts("dry_run_not_available: deploy the checkout with TmuxWindowJanitor.dry_run_now/0 first")
    end

  _ ->
    IO.puts("dry_run_not_available: TmuxWindowJanitor is not loaded in this release")
end'
      ;;
    sweep)
      expr='IO.puts(Casein.Terminals.TmuxWindowJanitor.sweep_now())'
      ;;
  esac

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
  test-leaks) run_test_leak_sweep ;;
  release-sweep) run_release_sweep sweep ;;
  release-dry-run) run_release_sweep dry-run ;;
esac
