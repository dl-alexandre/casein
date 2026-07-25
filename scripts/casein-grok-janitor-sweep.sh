#!/usr/bin/env bash
#
# casein-grok-janitor-sweep.sh — reap orphaned Grok leaders and stale state.
#
# Every managed Grok launch derives its private leader id from
# (workspace_id, checkout). Ad-hoc agent worktrees get a unique checkout per
# launch, so their leader dirs, sandbox bundles, and — when the worktree is
# deleted while the leader lingers (`--no-exit-on-disconnect`) — the leader
# node processes themselves can never be reused and accumulate without bound
# (observed: 270+ orphaned leader processes, ~14k leader dirs, ~4G of
# content-addressed bundles across the casein and legacy devide roots).
#
# SAFETY:
#   - Leader processes are matched by exact cmdline signature
#     (`--leader-socket <path> ... agent leader`), re-verified immediately
#     before each signal, and killed by exact PID — never by pattern.
#   - Only leaders whose working directory no longer exists are reaped.
#   - Leader dirs/bundles are removed only when they are (a) not referenced by
#     a surviving leader and (b) older than the age threshold, so in-flight
#     launches are never raced.
#
# DRY RUN BY DEFAULT — prints the plan and removes nothing. Pass --apply.
#
# Usage:
#   scripts/casein-grok-janitor-sweep.sh            # dry run (plan only)
#   scripts/casein-grok-janitor-sweep.sh --apply    # reap + remove
#   CASEIN_GROK_REAP_AGE_MIN=240 scripts/...        # override 120-min threshold
set -euo pipefail

APPLY=0
AGE_MIN="${CASEIN_GROK_REAP_AGE_MIN:-120}"
FLOCK_AGE_MIN="${CASEIN_GROK_FLOCK_AGE_MIN:-1440}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

UID_NUM="$(id -u)"
LEADER_ROOTS=(
  "${HOME}/.casein/grok-leaders"
  "${HOME}/.devide/grok-leaders"
  "/dev/shm/devide-grok-leaders-${UID_NUM}"
  "/tmp/devide-grok-leaders-${UID_NUM}"
)
BUNDLE_ROOTS=(
  "${HOME}/.casein/grok-bundles"
  "${HOME}/.devide/grok-bundles"
)
SANDBOX_TOMLS=()
for toml in "${HOME}/.grok/sandbox.toml" \
  "${HOME}"/.casein/grok-homes/*/sandbox.toml \
  "${HOME}"/.devide/grok-homes/*/sandbox.toml; do
  [[ -f "$toml" ]] && SANDBOX_TOMLS+=("$toml")
done

log() { echo "[grok-janitor] $*"; }

# ---- Phase 1: enumerate managed leader processes by exact cmdline signature.
# A leader looks like: node .../grok --sandbox <profile> ...
#   --leader-socket <path> agent leader --no-exit-on-disconnect ...
leader_signature() { # <pid> -> "sock<TAB>cwd" on stdout, rc 1 if not a leader
  local pid="$1" sock="" prev="" arg="" sub="" cwd=""
  local -a args=()
  while IFS= read -r -d '' arg; do args+=("$arg"); done \
    2>/dev/null <"/proc/${pid}/cmdline" || return 1
  ((${#args[@]})) || return 1
  for arg in "${args[@]}"; do
    [[ "$prev" == "--leader-socket" ]] && sock="$arg"
    [[ "$prev" == "agent" && "$arg" == "leader" ]] && sub="agent-leader"
    prev="$arg"
  done
  [[ -n "$sock" && "$sub" == "agent-leader" ]] || return 1
  cwd="$(readlink "/proc/${pid}/cwd" 2>/dev/null)" || cwd=""
  printf '%s\t%s\n' "$sock" "$cwd"
}

declare -a ORPHAN_PIDS=()
declare -A KEEP_SOCKS=() KEEP_IDS=() KEEP_PIDS=()
for piddir in /proc/[0-9]*; do
  pid="${piddir#/proc/}"
  [[ "$pid" == "$$" ]] && continue
  sig="$(leader_signature "$pid")" || continue
  sock="${sig%%$'\t'*}"
  cwd="${sig#*$'\t'}"
  if [[ -n "$cwd" && -d "$cwd" ]]; then
    KEEP_SOCKS["$sock"]=1
    KEEP_PIDS["$pid"]=1
  else
    ORPHAN_PIDS+=("$pid")
  fi
done

log "leader processes: keep=${#KEEP_SOCKS[@]} sockets, orphaned pids=${#ORPHAN_PIDS[@]} (cwd gone)"

# ---- Phase 2: reap orphaned leader processes (TERM, then KILL) by exact PID.
if ((${#ORPHAN_PIDS[@]})); then
  if [[ "$APPLY" == 1 ]]; then
    reaped=0
    for pid in "${ORPHAN_PIDS[@]}"; do
      # Re-verify the signature right before signalling: never kill a PID that
      # was recycled since enumeration.
      leader_signature "$pid" >/dev/null 2>&1 || continue
      kill -TERM "$pid" 2>/dev/null && reaped=$((reaped + 1)) || true
    done
    for _ in $(seq 1 100); do
      alive=0
      for pid in "${ORPHAN_PIDS[@]}"; do
        [[ -d "/proc/${pid}" ]] && leader_signature "$pid" >/dev/null 2>&1 && alive=1
      done
      [[ "$alive" == 0 ]] && break
      sleep 0.1
    done
    for pid in "${ORPHAN_PIDS[@]}"; do
      leader_signature "$pid" >/dev/null 2>&1 || continue
      kill -KILL "$pid" 2>/dev/null || true
    done
    log "reaped ${reaped} orphaned leader processes"
  else
    log "would reap ${#ORPHAN_PIDS[@]} orphaned leader processes (pids: ${ORPHAN_PIDS[*]:0:8}...)"
  fi
fi

# ---- Phase 3: keep-sets for filesystem state owned by surviving leaders.
for sock in "${!KEEP_SOCKS[@]}"; do
  base="$(basename "$sock")"
  if [[ "$base" == "leader.sock" ]]; then
    id="$(basename "$(dirname "$sock")")"
  else
    id="${base%.sock}"
  fi
  [[ "$id" =~ ^[0-9a-f]{24}$ ]] && KEEP_IDS["$id"]=1
done
# Orphaned leaders are intentionally absent from the keep-sets: their state is
# counted as removable in dry-run exactly as --apply would leave it post-reap.

keep_id() { [[ -n "${KEEP_IDS[$1]:-}" ]]; }

# ---- Phase 4: sweep stale leader dirs / root-level leader files / flocks.
dirs_removed=0 files_removed=0
for root in "${LEADER_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    if [[ -d "$entry" ]]; then
      [[ "$name" =~ ^[0-9a-f]{24}$ ]] || continue
      keep_id "$name" && continue
      if [[ "$APPLY" == 1 ]]; then
        chmod -R u+w "$entry" 2>/dev/null || true
        rm -rf "$entry" && dirs_removed=$((dirs_removed + 1))
      else
        dirs_removed=$((dirs_removed + 1))
      fi
    else
      id="${name%%.*}"
      case "$name" in
        .launch-*.flock) ;;
        *) [[ "$id" =~ ^[0-9a-f]{24}$ ]] || continue; keep_id "$id" && continue ;;
      esac
      if [[ "$APPLY" == 1 ]]; then
        rm -f "$entry" && files_removed=$((files_removed + 1))
      else
        files_removed=$((files_removed + 1))
      fi
    fi
  done < <(
    {
      find "$root" -mindepth 1 -maxdepth 1 -type d -mmin "+${AGE_MIN}" -print0
      find "$root" -mindepth 1 -maxdepth 1 -type f,s ! -name ".launch-*.flock" \
        -mmin "+${AGE_MIN}" -print0
      find "$root" -mindepth 1 -maxdepth 1 -type f -name ".launch-*.flock" \
        -mmin "+${FLOCK_AGE_MIN}" -print0
    } 2>/dev/null
  )
done
log "stale leader dirs: ${dirs_removed}, stale leader files/flocks: ${files_removed} (age>${AGE_MIN}m) apply=${APPLY}"

# ---- Phase 5: sweep bundles not referenced by any surviving leader.
declare -A KEEP_BUNDLES=()
# Primary source of truth: the bundle path each surviving leader received at
# spawn, still visible in its environment. (Older launcher versions never
# recorded the bundle in a read_only profile line, so profiles alone miss it.)
for pid in "${!KEEP_PIDS[@]}"; do
  while IFS= read -r bundle; do
    KEEP_BUNDLES["$bundle"]=1
  done < <(
    tr '\0' '\n' <"/proc/${pid}/environ" 2>/dev/null |
      grep -o '/[^=:"]*/grok-bundles/sha256-[0-9a-f]\{64\}' || true
  )
done
for toml in "${SANDBOX_TOMLS[@]}"; do
  while IFS= read -r bundle; do
    KEEP_BUNDLES["$bundle"]=1
  done < <(
    awk -v ids="${!KEEP_IDS[*]}" '
      BEGIN { n = split(ids, arr, " ") }
      /^\[profiles\./ {
        live = 0
        for (i = 1; i <= n; i++) if (index($0, "-" arr[i] "-")) live = 1
      }
      live && /read_only/ { print }
    ' "$toml" | grep -o '"[^"]*/grok-bundles/[^"]*"' | tr -d '"' || true
  )
done

bundles_removed=0 bundles_kept=0
for root in "${BUNDLE_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' bundle; do
    if [[ -n "${KEEP_BUNDLES[$bundle]:-}" ]]; then
      bundles_kept=$((bundles_kept + 1))
      continue
    fi
    if [[ "$APPLY" == 1 ]]; then
      chmod -R u+w "$bundle" 2>/dev/null || true
      rm -rf "$bundle" && bundles_removed=$((bundles_removed + 1))
    else
      bundles_removed=$((bundles_removed + 1))
    fi
  done < <(
    find "$root" -mindepth 1 -maxdepth 1 -type d \
      \( -name 'sha256-*' -o -name '.grok-bundle-*' \) -mmin "+${AGE_MIN}" -print0 \
      2>/dev/null
  )
done
log "stale bundles: ${bundles_removed} removed-or-planned, ${bundles_kept} kept (referenced by live leaders)"

if [[ "$APPLY" == 0 ]]; then
  log "DRY RUN — re-run with --apply to reap and remove"
fi
