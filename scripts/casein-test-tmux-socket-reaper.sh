#!/usr/bin/env bash
#
# casein-test-tmux-socket-reaper.sh — inventory + conservative reap of leftover
# test-suite tmux sockets (issue #717 / host dual-plane P4).
#
# Context: every `mix test` run pins `-L casein_test_<pid>` (see
# test/test_helper.exs). When a run is killed before at_exit, or older code
# only called kill-server without unlinking, dead socket files pile up under
# $TMUX_TMPDIR/tmux-<uid>/ (or /tmp/tmux-<uid>/). On a multi-tenant box the
# failure mode is killing something live that belongs to somebody else — so
# this tool is inventory-first and dry-run by default.
#
# HARD RULES (do not weaken):
#   - NEVER pkill -f / pattern kills. Match exact socket basenames and, when
#     signalling a process, the exact PID re-verified from /proc cmdline.
#   - NEVER infer "stale" from a bare `tmux` call. Live servers here often run
#     as `-L devide` with the socket RENAMED to `casein`; a pane's inherited
#     $TMUX can name a dead path while the real server is healthy. Always use
#     `tmux -L <exact-name> ...`.
#   - NEVER touch protected labels: casein, casein_dev, devide, devide_dev,
#     default (and any name that does not match a test pattern).
#   - Suite sockets may be unlinked while the server still runs — treat that
#     as its own state; do not assume "no socket file ⇒ nothing to do" for
#     process cleanup, and do not assume "socket file present ⇒ live".
#   - A server whose cwd is a deleted worktree is a real stuck signal, but
#     killing it is opt-in (see --reap-orphaned-servers): an active mix test
#     can also sit on a deleted tmp home for a few minutes.
#
# WHAT --apply DOES BY DEFAULT:
#   Unlink dead socket *files* only — names matching the test patterns where
#   `tmux -L <name> list-sessions` reports no server AND no process is
#   listening on that exact path. No kill-server. No signals.
#
# WHAT --apply --reap-orphaned-servers ADDS (still never protected labels):
#   For a live tmux server whose -L label matches a test pattern AND whose
#   label pid (casein_test_<pid>) is dead or absent AND which has zero
#   attached clients AND is older than the age threshold: send SIGTERM to
#   that exact server PID (re-verified), then unlink the socket if present.
#   Unlinked-but-running servers are included when they match the same
#   predicates (attach check is skipped when the socket is gone and list-
#   sessions cannot connect — age + dead label pid gate instead).
#
# Usage:
#   scripts/casein-test-tmux-socket-reaper.sh              # inventory + dry plan
#   scripts/casein-test-tmux-socket-reaper.sh --apply      # unlink dead socket files
#   scripts/casein-test-tmux-socket-reaper.sh --apply --reap-orphaned-servers
#   CASEIN_TEST_TMUX_REAP_AGE_MIN=120 scripts/...         # orphan age (default 60)
#   CASEIN_TEST_TMUX_SOCKET_DIR=/tmp/tmux-1001 scripts/... # override scan dir
#
set -euo pipefail

APPLY=0
REAP_ORPHANS=0
AGE_MIN="${CASEIN_TEST_TMUX_REAP_AGE_MIN:-60}"
TERM_GRACE_SEC="${CASEIN_TEST_TMUX_TERM_GRACE_SEC:-3}"
TMUX_BIN="${CASEIN_TMUX_BIN:-tmux}"

# Basename allow-list (anchored). Only these are ever candidates.
#   casein_test
#   casein_test_<digits>     # per-run label from test_helper.exs
#   casein-measure-*         # ad-hoc measure sockets mentioned in #717
#   casein_measure_*
TEST_NAME_RE='^(casein_test|casein_test_[0-9]+|casein-measure-.+|casein_measure_.+)$'

# Never touch — even if someone renames a test pattern to collide, the
# exact-name allow-list above already excludes these. Listed for inventory.
PROTECTED_NAMES=(casein casein_dev devide devide_dev default)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --reap-orphaned-servers) REAP_ORPHANS=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '[test-tmux-socket-reaper] %s\n' "$*"; }

is_protected() {
  local name="$1" p
  for p in "${PROTECTED_NAMES[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

is_test_name() {
  local name="$1"
  [[ "$name" =~ $TEST_NAME_RE ]]
}

# Resolve scan directories. Prefer explicit override, then TMUX_TMPDIR, then
# /tmp and (on macOS) /private/tmp.
socket_dirs() {
  local uid dirs=() d
  uid="$(id -u)"
  if [[ -n "${CASEIN_TEST_TMUX_SOCKET_DIR:-}" ]]; then
    printf '%s\n' "$CASEIN_TEST_TMUX_SOCKET_DIR"
    return
  fi
  if [[ -n "${TMUX_TMPDIR:-}" ]]; then
    dirs+=("${TMUX_TMPDIR}/tmux-${uid}")
  fi
  dirs+=("/tmp/tmux-${uid}")
  # macOS often surfaces the same tree via /private/tmp
  dirs+=("/private/tmp/tmux-${uid}")
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done | awk 'NF && !seen[$0]++'
}

# Exact-path listener PID via ss (Linux) or lsof (macOS), if any.
listener_pid_for_path() {
  local sock="$1" line pid=""
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r line; do
      if [[ "$line" == *"$sock"* ]]; then
        if printf '%s\n' "$line" | awk -v s="$sock" '{for(i=1;i<=NF;i++) if($i==s) exit 0; exit 1}'; then
          if [[ "$line" =~ pid=([0-9]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
          fi
        fi
      fi
    done < <(ss -xlp 2>/dev/null || true)
  elif command -v lsof >/dev/null 2>&1; then
    # lsof -U lists unix sockets; -F p0n for machine parse. Exact path only.
    pid="$(lsof -U -F pn 2>/dev/null | awk -v s="$sock" '
      /^p/ { pid=substr($0,2); next }
      /^n/ { if (substr($0,2)==s) { print pid; exit } }
    ')"
    if [[ -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  return 1
}

# list-sessions against an exact -L name. Prints sessions to stdout.
# rc 0 = server answered; non-zero = no server / connect error.
list_sessions_L() {
  local name="$1"
  "$TMUX_BIN" -L "$name" list-sessions \
    -F '#{session_name}|att=#{session_attached}|created=#{session_created}|windows=#{session_windows}' \
    2>/dev/null
}

attached_count() {
  local name="$1" sessions
  sessions="$(list_sessions_L "$name" || true)"
  if [[ -z "$sessions" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$sessions" | awk -F'|' '
    {
      att=0
      for(i=1;i<=NF;i++) if($i ~ /^att=/) { split($i,a,"="); att=a[2]+0 }
      total+=att
    }
    END { print total+0 }
  '
}

server_etime_sec() {
  local pid="$1" et
  # Linux ps has etimes; macOS does not — fall back to 0 (treat as young /
  # do not orphan-reap without a positive age reading).
  et="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "$et" && "$et" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$et"
  else
    printf '0\n'
  fi
}

cwd_deleted() {
  local raw="$1"
  [[ "$raw" == *'(deleted)'* ]]
}

# Parse every tmux: server for -L <label>. Emits: pid<TAB>label<TAB>cwd.
# Linux /proc only — on macOS this is a no-op and orphan-server reap is
# skipped (dead socket-file unlink still works via list-sessions).
enumerate_tmux_servers() {
  local piddir pid comm prev arg label cwd
  local -a args
  [[ -d /proc ]] || return 0
  for piddir in /proc/[0-9]*; do
    pid="${piddir#/proc/}"
    comm="$(cat "${piddir}/comm" 2>/dev/null || true)"
    [[ "$comm" == "tmux: server" ]] || continue
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done \
      2>/dev/null <"${piddir}/cmdline" || continue
    label=""
    prev=""
    for arg in "${args[@]}"; do
      if [[ "$prev" == "-L" ]]; then
        label="$arg"
      fi
      prev="$arg"
    done
    # No -L means the default socket name "default"
    [[ -n "$label" ]] || label="default"
    cwd="$(readlink "${piddir}/cwd" 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$pid" "$label" "$cwd"
  done
}

# Re-read cmdline and confirm this PID is still tmux: server with -L <label>.
verify_server_pid_label() {
  local pid="$1" want="$2" comm prev arg label=""
  local -a args=()
  [[ -d "/proc/${pid}" ]] || return 1
  comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
  [[ "$comm" == "tmux: server" ]] || return 1
  while IFS= read -r -d '' arg; do args+=("$arg"); done \
    2>/dev/null <"/proc/${pid}/cmdline" || return 1
  prev=""
  for arg in "${args[@]}"; do
    if [[ "$prev" == "-L" ]]; then label="$arg"; fi
    prev="$arg"
  done
  [[ -z "$label" ]] && label="default"
  [[ "$label" == "$want" ]]
}

label_pid_from_name() {
  local name="$1"
  if [[ "$name" =~ ^casein_test_([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

label_pid_alive() {
  local lpid="$1"
  [[ -n "$lpid" && -d "/proc/${lpid}" ]]
}

AGE_SEC=$((AGE_MIN * 60))

# ---- Collect inventory ----------------------------------------------------

declare -a INV_LINES=()
declare -a DEAD_SOCKETS=()       # path
declare -a ORPHAN_SERVERS=()     # pid|label|reason
declare -a SKIP_LIVE_TESTS=()    # label|reason
declare -a PROTECTED_SEEN=()     # name

mapfile -t DIRS < <(socket_dirs)
if ((${#DIRS[@]} == 0)); then
  log "no tmux socket dirs found (uid=$(id -u)); nothing to inventory"
fi

# Index live servers by label
declare -A SERVER_PID_BY_LABEL=()
declare -A SERVER_CWD_BY_LABEL=()
while IFS=$'\t' read -r spid slabel scwd; do
  [[ -n "$slabel" ]] || continue
  SERVER_PID_BY_LABEL["$slabel"]="$spid"
  SERVER_CWD_BY_LABEL["$slabel"]="$scwd"
done < <(enumerate_tmux_servers)

# 1) Socket files on disk
declare -A SEEN_SOCKET_LABEL=()
for dir in "${DIRS[@]+"${DIRS[@]}"}"; do
  [[ -d "$dir" ]] || continue
  for sock in "$dir"/*; do
    [[ -e "$sock" ]] || continue
    name="$(basename "$sock")"
    if [[ ! -S "$sock" ]]; then
      INV_LINES+=("SKIP non-socket path=${sock}")
      continue
    fi
    SEEN_SOCKET_LABEL["$name"]=1

    if is_protected "$name"; then
      PROTECTED_SEEN+=("$name")
      spid="${SERVER_PID_BY_LABEL[$name]:-}"
      live="unknown"
      if sessions="$(list_sessions_L "$name")"; then
        sc=$(printf '%s\n' "$sessions" | grep -c . || true)
        live="LIVE sessions=${sc}"
      else
        live="no-list-sessions"
      fi
      INV_LINES+=("PROTECTED name=${name} path=${sock} pid=${spid:-none} ${live} (never touch)")
      continue
    fi

    if ! is_test_name "$name"; then
      INV_LINES+=("OUT_OF_SCOPE name=${name} path=${sock} (not a test pattern; ignored)")
      continue
    fi

    # Test-pattern socket
    listen_pid="$(listener_pid_for_path "$sock" || true)"
    spid="${SERVER_PID_BY_LABEL[$name]:-${listen_pid:-}}"
    lpid=""
    lpid="$(label_pid_from_name "$name" || true)"
    lpid_state="n/a"
    if [[ -n "$lpid" ]]; then
      if label_pid_alive "$lpid"; then lpid_state="alive"; else lpid_state="dead"; fi
    fi

    if sessions="$(list_sessions_L "$name")"; then
      sc=$(printf '%s\n' "$sessions" | grep -c . || true)
      att="$(attached_count "$name")"
      cwd="${SERVER_CWD_BY_LABEL[$name]:-}"
      del="no"
      cwd_deleted "$cwd" && del="YES"
      et=0
      [[ -n "$spid" ]] && et="$(server_etime_sec "$spid")"
      INV_LINES+=("LIVE_TEST name=${name} path=${sock} server_pid=${spid:-?} label_pid=${lpid:-?}/${lpid_state} attached=${att} sessions=${sc} etime_s=${et} cwd_deleted=${del} cwd=${cwd:-?}")
      # Never auto-unlink a live socket file.
      if [[ "$lpid_state" == "alive" ]] || [[ "$att" != "0" ]] || [[ "$et" -lt "$AGE_SEC" ]]; then
        SKIP_LIVE_TESTS+=("${name}|live suite or young or attached (att=${att} etime_s=${et} label_pid=${lpid_state})")
      else
        # Candidate for orphan server reap only
        ORPHAN_SERVERS+=("${spid}|${name}|aged_unattached label_pid=${lpid_state} etime_s=${et} cwd_deleted=${del}")
      fi
    else
      # No server answered on -L name
      if [[ -n "${listen_pid:-}" ]]; then
        INV_LINES+=("ODD name=${name} path=${sock} list-sessions=fail but ss_listen_pid=${listen_pid} (left alone)")
        SKIP_LIVE_TESTS+=("${name}|ss listener without list-sessions")
      else
        INV_LINES+=("DEAD_SOCKET name=${name} path=${sock} label_pid=${lpid:-?}/${lpid_state} (safe unlink candidate)")
        DEAD_SOCKETS+=("$sock")
      fi
    fi
  done
done

# 2) Live servers with test labels whose socket file is missing (unlinked-but-running)
for label in "${!SERVER_PID_BY_LABEL[@]}"; do
  is_test_name "$label" || continue
  [[ -n "${SEEN_SOCKET_LABEL[$label]:-}" ]] && continue
  spid="${SERVER_PID_BY_LABEL[$label]}"
  cwd="${SERVER_CWD_BY_LABEL[$label]:-}"
  del="no"
  cwd_deleted "$cwd" && del="YES"
  et="$(server_etime_sec "$spid")"
  lpid=""
  lpid="$(label_pid_from_name "$label" || true)"
  lpid_state="n/a"
  if [[ -n "$lpid" ]]; then
    if label_pid_alive "$lpid"; then lpid_state="alive"; else lpid_state="dead"; fi
  fi
  # Try list-sessions anyway (may fail if unlinked)
  if sessions="$(list_sessions_L "$label")"; then
    att="$(attached_count "$label")"
    INV_LINES+=("UNLINKED_BUT_REACHABLE name=${label} server_pid=${spid} attached=${att} etime_s=${et} cwd_deleted=${del} cwd=${cwd}")
    if [[ "$lpid_state" != "alive" && "$att" == "0" && "$et" -ge "$AGE_SEC" ]]; then
      ORPHAN_SERVERS+=("${spid}|${label}|unlinked_reachable label_pid=${lpid_state} etime_s=${et}")
    else
      SKIP_LIVE_TESTS+=("${label}|unlinked but still reachable; not orphan-eligible")
    fi
  else
    INV_LINES+=("UNLINKED_RUNNING name=${label} server_pid=${spid} etime_s=${et} cwd_deleted=${del} cwd=${cwd} label_pid=${lpid:-?}/${lpid_state} (no socket file; list-sessions fail)")
    if [[ "$lpid_state" != "alive" && "$et" -ge "$AGE_SEC" ]]; then
      ORPHAN_SERVERS+=("${spid}|${label}|unlinked_running label_pid=${lpid_state} etime_s=${et} cwd_deleted=${del}")
    else
      SKIP_LIVE_TESTS+=("${label}|unlinked_running but label_pid alive or young")
    fi
  fi
done

# ---- Report ---------------------------------------------------------------

ts="$(date -u +%FT%TZ)"
log "ts=${ts} apply=${APPLY} reap_orphaned_servers=${REAP_ORPHANS} age_min=${AGE_MIN} dirs=${DIRS[*]:-none}"
log "inventory:"
if ((${#INV_LINES[@]} == 0)); then
  log "  (empty)"
else
  for line in "${INV_LINES[@]}"; do
    log "  ${line}"
  done
fi

log "summary: protected=${#PROTECTED_SEEN[@]} dead_socket_files=${#DEAD_SOCKETS[@]} orphan_server_candidates=${#ORPHAN_SERVERS[@]} skipped_live_tests=${#SKIP_LIVE_TESTS[@]}"

if ((${#DEAD_SOCKETS[@]})); then
  log "dead socket files (unlink candidates):"
  for p in "${DEAD_SOCKETS[@]}"; do log "  $p"; done
fi
if ((${#ORPHAN_SERVERS[@]})); then
  log "orphan server candidates (require --reap-orphaned-servers):"
  for o in "${ORPHAN_SERVERS[@]}"; do log "  $o"; done
fi
if ((${#SKIP_LIVE_TESTS[@]})); then
  log "skipped live/young test servers:"
  for s in "${SKIP_LIVE_TESTS[@]}"; do log "  $s"; done
fi

# ---- Apply ----------------------------------------------------------------

unlinked=0
signaled=0

if [[ "$APPLY" == 1 ]]; then
  for sock in "${DEAD_SOCKETS[@]+"${DEAD_SOCKETS[@]}"}"; do
    name="$(basename "$sock")"
    # Re-check immediately before unlink
    is_test_name "$name" || continue
    is_protected "$name" && continue
    if list_sessions_L "$name" >/dev/null 2>&1; then
      log "skip unlink ${sock}: server became reachable"
      continue
    fi
    if listener_pid_for_path "$sock" >/dev/null 2>&1; then
      log "skip unlink ${sock}: listener appeared"
      continue
    fi
    if rm -f -- "$sock" 2>/dev/null; then
      log "unlinked ${sock}"
      unlinked=$((unlinked + 1))
    else
      log "failed to unlink ${sock}"
    fi
  done

  if [[ "$REAP_ORPHANS" == 1 ]]; then
    for o in "${ORPHAN_SERVERS[@]+"${ORPHAN_SERVERS[@]}"}"; do
      spid="${o%%|*}"
      rest="${o#*|}"
      label="${rest%%|*}"
      is_test_name "$label" || continue
      is_protected "$label" && continue
      # Re-verify exact PID/label before any signal
      verify_server_pid_label "$spid" "$label" || {
        log "skip signal pid=${spid} label=${label}: no longer matches"
        continue
      }
      lpid=""
      if lpid="$(label_pid_from_name "$label")"; then
        if label_pid_alive "$lpid"; then
          log "skip signal pid=${spid} label=${label}: label pid ${lpid} is alive again"
          continue
        fi
      fi
      # Prefer attach==0 when reachable
      if list_sessions_L "$label" >/dev/null 2>&1; then
        att="$(attached_count "$label")"
        if [[ "$att" != "0" ]]; then
          log "skip signal pid=${spid} label=${label}: attached=${att}"
          continue
        fi
      fi
      et="$(server_etime_sec "$spid")"
      if [[ "$et" -lt "$AGE_SEC" ]]; then
        log "skip signal pid=${spid} label=${label}: etime_s=${et} < ${AGE_SEC}"
        continue
      fi
      log "SIGTERM pid=${spid} label=${label}"
      if kill -TERM "$spid" 2>/dev/null; then
        signaled=$((signaled + 1))
      fi
    done
    # Grace, then KILL survivors still matching
    if ((signaled > 0)); then
      sleep "$TERM_GRACE_SEC"
      for o in "${ORPHAN_SERVERS[@]+"${ORPHAN_SERVERS[@]}"}"; do
        spid="${o%%|*}"
        rest="${o#*|}"
        label="${rest%%|*}"
        verify_server_pid_label "$spid" "$label" || continue
        log "SIGKILL pid=${spid} label=${label}"
        kill -KILL "$spid" 2>/dev/null || true
        # Unlink socket if it remains and still has no listener
        for dir in "${DIRS[@]+"${DIRS[@]}"}"; do
          sock="${dir}/${label}"
          if [[ -S "$sock" ]] && ! listener_pid_for_path "$sock" >/dev/null 2>&1; then
            if rm -f -- "$sock" 2>/dev/null; then
              unlinked=$((unlinked + 1))
              log "unlinked ${sock}"
            fi
          fi
        done
      done
    fi
  elif ((${#ORPHAN_SERVERS[@]} > 0)); then
    log "note: ${#ORPHAN_SERVERS[@]} orphan server candidate(s) left running (pass --reap-orphaned-servers to signal exact PIDs)"
  fi
  log "done unlinked=${unlinked} signaled=${signaled}"
else
  log "DRY RUN — re-run with --apply to unlink ${#DEAD_SOCKETS[@]} dead socket file(s)"
  if ((${#ORPHAN_SERVERS[@]} > 0)); then
    log "DRY RUN — orphan servers require --apply --reap-orphaned-servers (${#ORPHAN_SERVERS[@]} candidate(s))"
  fi
  log "safe default: report-only / dead-file unlink only; live casein/casein_dev/devide sockets are never candidates"
fi

exit 0
