#!/usr/bin/env bash
#
# casein-browser-janitor-sweep.sh — reap orphaned agent-browser Chrome trees.
#
# Headless Chrome launched for agent tooling (playwright/CDP under
# `agent-browser`) does not die with its launcher. When the launching agent
# session exits uncleanly the tree reparents to init and the GPU process
# spins on a swiftshader loop forever: observed 4 trees aged 5.8-20.9 days,
# each pegging 43-95% of a core (~290% total, ~3 of 32 cores) with the
# renderers idle at 0%. Nothing else sweeps this — casein-tmp-cleanup only
# ages out files, and the worktree/grok janitors do not know about browsers.
#
# DETECTION — a whole tree is judged, never a lone process:
#   Chrome spreads one browser over a root plus --type=gpu-process/renderer/
#   utility children and a crashpad handler, all sharing one --user-data-dir.
#   That directory is the tree identity. A tree is ORPHANED only when no
#   member has a supervising parent *outside* the tree — i.e. every member's
#   parent is either init (reparented) or another member. A live browser
#   always has its launcher as an external parent, so it can never match.
#   Judging the group (not `ppid == 1` on one process) matters because
#   crashpad and GPU children routinely show ppid 1 while the browser is
#   healthy; killing on that signal alone would shoot live sessions.
#
# SAFETY:
#   - Only trees whose --user-data-dir matches an agent-browser root are
#     considered (see USER_DATA_PATTERNS); an unrelated Chrome is never
#     touched, whatever its parentage.
#   - The tree's NEWEST process must exceed the age threshold, so a tree that
#     is still being built up is never raced.
#   - Every PID is re-verified (alive, still carrying the same
#     --user-data-dir) immediately before each signal and killed by exact
#     PID — never by pattern.
#   - SIGTERM first, then SIGKILL only for what survives the grace period.
#   - Profile directories are removed only under /tmp (throwaway per-launch
#     dirs), only when no live process references them, and only past a
#     separate, longer age threshold. Persistent profiles under a workspace
#     (…/agent-browser/profile) are never removed.
#
# DRY RUN BY DEFAULT — prints the plan and kills nothing. Pass --apply.
#
# Usage:
#   scripts/casein-browser-janitor-sweep.sh             # dry run (plan only)
#   scripts/casein-browser-janitor-sweep.sh --apply     # reap
#   CASEIN_BROWSER_REAP_AGE_MIN=180 scripts/...         # override 60-min threshold
#   CASEIN_BROWSER_PROFILE_AGE_MIN=2880 scripts/...     # override 1440-min dir threshold
set -euo pipefail

APPLY=0
AGE_MIN="${CASEIN_BROWSER_REAP_AGE_MIN:-60}"
PROFILE_AGE_MIN="${CASEIN_BROWSER_PROFILE_AGE_MIN:-1440}"
TERM_GRACE_SEC="${CASEIN_BROWSER_TERM_GRACE_SEC:-5}"

# Only trees whose --user-data-dir matches one of these are in scope.
USER_DATA_PATTERNS=(
  '/tmp/agent-browser-chrome-*'
  '*/agent-browser/*'
  '*/.agent-browser/*'
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

AGE_SEC=$((AGE_MIN * 60))

in_scope() {
  local dir="$1" pat
  for pat in "${USER_DATA_PATTERNS[@]}"; do
    # shellcheck disable=SC2053  # intentional glob match, not string equality
    [[ "$dir" == $pat ]] && return 0
  done
  return 1
}

# --user-data-dir for a pid, or empty.
#
# Two passes on purpose. Chrome's own child processes (zygote, renderer,
# gpu-process) rewrite argv into one contiguous space-separated string rather
# than the NUL-separated vector, so a per-argument parse sees a single blob
# and matches nothing — which silently reduced every tree to just its root.
# Try the exact NUL-separated form first (it tolerates spaces in the path),
# then fall back to splitting the blob on whitespace.
#
# `tr` reads /proc/<pid>/cmdline directly rather than via a captured variable:
# command substitution silently discards NUL bytes, which would collapse a
# properly NUL-separated argv into one unsplittable token and hide the browser
# root while its space-mangled children still matched.
udd_of() {
  local pid="$1" value awk_prog

  # Killing a tree makes its siblings exit underneath us, so the file can
  # vanish between listing and reading. Check first: the `<file` redirect is
  # performed by the shell, so a missing path would print its own error
  # regardless of any 2>/dev/null on the command being redirected into.
  [[ -r "/proc/${pid}/cmdline" ]] || return 0

  awk_prog='
    /^--user-data-dir=/ { sub(/^--user-data-dir=/, ""); print; exit }
    prev == "--user-data-dir" { print; exit }
    { prev = $0 }
  '

  value="$(tr '\0' '\n' <"/proc/${pid}/cmdline" 2>/dev/null | awk "$awk_prog")"

  if [[ -z "$value" ]] && [[ -r "/proc/${pid}/cmdline" ]]; then
    value="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null |
      tr ' ' '\n' | awk "$awk_prog")"
  fi

  printf '%s' "$value"
}

# Collect chrome-ish pids -> user-data-dir. Keyed on the binary name so a
# stray process merely mentioning the path is never swept in.
declare -A PID_UDD=()
declare -A PID_PPID=()
declare -A PID_AGE=()

while read -r pid ppid etimes comm; do
  [[ "$comm" == chrome* ]] || continue
  [[ -r "/proc/${pid}/cmdline" ]] || continue
  udd="$(udd_of "$pid")"
  [[ -n "$udd" ]] || continue
  in_scope "$udd" || continue
  PID_UDD["$pid"]="$udd"
  PID_PPID["$pid"]="$ppid"
  PID_AGE["$pid"]="$etimes"
done < <(ps -eo pid=,ppid=,etimes=,comm= 2>/dev/null | awk '{print $1, $2, $3, $4}')

if [[ "${#PID_UDD[@]}" -eq 0 ]]; then
  log "no in-scope agent-browser processes found; nothing to do"
  exit 0
fi

# Group pids by tree (user-data-dir).
declare -A TREE_PIDS=()
for pid in "${!PID_UDD[@]}"; do
  TREE_PIDS["${PID_UDD[$pid]}"]+="${pid} "
done

reaped_trees=0
reaped_pids=0
skipped_live=0
skipped_young=0

for udd in "${!TREE_PIDS[@]}"; do
  read -ra pids <<<"${TREE_PIDS[$udd]}"

  # Live if ANY member's parent is a real process outside this tree.
  external_parent=""
  newest=999999999
  for pid in "${pids[@]}"; do
    ppid="${PID_PPID[$pid]}"
    age="${PID_AGE[$pid]}"
    [[ "$age" -lt "$newest" ]] && newest="$age"
    if [[ "$ppid" != "1" && -z "${PID_UDD[$ppid]:-}" ]] && kill -0 "$ppid" 2>/dev/null; then
      external_parent="$ppid"
      break
    fi
  done

  if [[ -n "$external_parent" ]]; then
    skipped_live=$((skipped_live + 1))
    log "SKIP  live tree ${udd} (${#pids[@]} procs, supervised by pid ${external_parent})"
    continue
  fi

  if [[ "$newest" -lt "$AGE_SEC" ]]; then
    skipped_young=$((skipped_young + 1))
    log "SKIP  orphaned but young tree ${udd} (newest proc ${newest}s < ${AGE_SEC}s)"
    continue
  fi

  cpu="$(ps -o pcpu= -p "$(IFS=,; echo "${pids[*]}")" 2>/dev/null |
    awk '{s += $1} END {printf "%.0f", s}')"
  log "REAP  orphaned tree ${udd} (${#pids[@]} procs, newest ${newest}s, ~${cpu:-0}% CPU)"

  if [[ "$APPLY" -eq 0 ]]; then
    reaped_trees=$((reaped_trees + 1))
    continue
  fi

  # Re-verify identity immediately before signalling; kill by exact pid.
  survivors=()
  for pid in "${pids[@]}"; do
    [[ -d "/proc/${pid}" ]] || continue
    [[ "$(udd_of "$pid")" == "$udd" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    survivors+=("$pid")
    reaped_pids=$((reaped_pids + 1))
  done

  sleep "$TERM_GRACE_SEC"

  for pid in "${survivors[@]}"; do
    [[ -d "/proc/${pid}" ]] || continue
    [[ "$(udd_of "$pid")" == "$udd" ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done

  reaped_trees=$((reaped_trees + 1))
done

# Throwaway per-launch profile dirs under /tmp, once nothing references them.
# Persistent workspace profiles are deliberately out of scope.
removed_dirs=0
while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  referenced=0
  for pid in "${!PID_UDD[@]}"; do
    if [[ "${PID_UDD[$pid]}" == "$dir" && -d "/proc/${pid}" ]]; then
      referenced=1
      break
    fi
  done
  [[ "$referenced" -eq 1 ]] && continue

  size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
  log "RM    stale profile dir ${dir} (${size:-?})"
  if [[ "$APPLY" -eq 1 ]]; then
    rm -rf -- "$dir" || log "warning: failed to remove ${dir}"
  fi
  removed_dirs=$((removed_dirs + 1))
done < <(find /tmp -maxdepth 1 -type d -name 'agent-browser-chrome-*' \
  -mmin "+${PROFILE_AGE_MIN}" 2>/dev/null)

if [[ "$APPLY" -eq 1 ]]; then
  log "reaped ${reaped_trees} tree(s) / ${reaped_pids} process(es); removed ${removed_dirs} profile dir(s)"
else
  log "DRY RUN — would reap ${reaped_trees} tree(s), remove ${removed_dirs} profile dir(s); re-run with --apply"
fi
log "skipped ${skipped_live} live tree(s), ${skipped_young} orphaned-but-young tree(s)"
