#!/usr/bin/env bash
#
# bootstrap-remote-tmux.sh — make a host Casein-ready for labeled tmux (#556).
#
# Minimal, idempotent, user-scoped under ~/.casein/. Implements the Q3
# bootstrap contract for the remote-host track:
#   1. Ensure `tmux` is on PATH (optionally install via apt with --install-tmux)
#   2. Drop labeled config under ~/.casein/tmux/casein.conf
#   3. Start the labeled server (-L casein / casein_dev / casein_test) if down
#
# Dual access after this runs:
#   - Casein UI / MCP drives sessions on -L <label>
#   - From a plain SSH shell: `tmux -L <label> list-sessions` / `attach`
#   - Default `tmux` (no -L) is never touched
#
# WHAT THIS DOES NOT DO (follow-ups, not this slice):
#   - Mini Elixir control agent + SSH tunnel
#   - systemd unit on the remote (systemd cannot adopt a live server anyway)
#   - Control-plane prefer-agent / SSH fallback
#   - Package-manager installs other than opt-in apt
#
# GROUND TRUTH (multi-tenant shared box — do not weaken):
#   - NEVER pkill -f / pattern kills. Exact label + exact socket only.
#   - NEVER infer server state from a bare `tmux` call. Always `tmux -L <label>`.
#     Live servers here often run as `-L devide` with the socket RENAMED to
#     `casein`; a pane's inherited $TMUX can name a dead path while the real
#     server is healthy.
#   - `tmux new-session -A -d` is NOT idempotent for a keepalive session.
#     Check liveness first; only create when the labeled server is down.
#   - Start the server from $HOME (or /tmp), never from a worktree that may
#     later be deleted — a server whose cwd is a deleted path wedges new panes
#     with getcwd failures.
#   - Do not pretend systemd supervises a server it did not spawn.
#   - Compose with scripts/casein-test-tmux-socket-reaper.sh: this tool only
#     ever touches the operator labels (casein / casein_dev / casein_test),
#     never casein_test_<pid> suite sockets.
#
# Usage:
#   bash scripts/bootstrap-remote-tmux.sh                 # this host
#   bash scripts/bootstrap-remote-tmux.sh --check         # report only
#   bash scripts/bootstrap-remote-tmux.sh --label casein_dev
#   bash scripts/bootstrap-remote-tmux.sh --install-tmux  # apt if missing
#   bash scripts/bootstrap-remote-tmux.sh --host user@box # SSH + run remote
#   CASEIN_REMOTE_TMUX_HOME=/tmp/x bash scripts/...      # override ~/.casein
#
set -euo pipefail

LABEL="${CASEIN_REMOTE_TMUX_LABEL:-casein}"
CHECK_ONLY=0
INSTALL_TMUX=0
REMOTE_HOST=""
TMUX_BIN="${CASEIN_TMUX_BIN:-}"
CASEIN_HOME_OVERRIDE="${CASEIN_REMOTE_TMUX_HOME:-}"

usage() {
  sed -n '2,48p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      LABEL="${2:-}"
      if [[ -z "${LABEL}" ]]; then
        echo "error: --label requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --check) CHECK_ONLY=1; shift ;;
    --install-tmux) INSTALL_TMUX=1; shift ;;
    --host)
      REMOTE_HOST="${2:-}"
      if [[ -z "${REMOTE_HOST}" ]]; then
        echo "error: --host requires user@host" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Only the operator labels. Suite sockets (casein_test_<pid>) belong to the
# reaper; never bootstrap those.
case "${LABEL}" in
  casein|casein_dev|casein_test) ;;
  *)
    echo "error: label must be casein, casein_dev, or casein_test (got: ${LABEL})" >&2
    exit 2
    ;;
esac

log() { printf '[bootstrap-remote-tmux] %s\n' "$*"; }

# --- SSH wrapper: re-exec this script on the remote, no agent install --------
if [[ -n "${REMOTE_HOST}" ]]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  remote_args=(--label "${LABEL}")
  [[ "${CHECK_ONLY}" -eq 1 ]] && remote_args+=(--check)
  [[ "${INSTALL_TMUX}" -eq 1 ]] && remote_args+=(--install-tmux)

  # Stream the script over ssh so the remote needs no prior checkout.
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
    "${REMOTE_HOST}" \
    "bash -s -- ${remote_args[*]}" <"${self}"
  exit $?
fi

# --- local / on-remote body -------------------------------------------------

resolve_home() {
  if [[ -n "${CASEIN_HOME_OVERRIDE}" ]]; then
    printf '%s\n' "${CASEIN_HOME_OVERRIDE}"
    return
  fi
  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi
  local ent
  ent="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "${ent}" && -d "${ent}" ]]; then
    printf '%s\n' "${ent}"
    return
  fi
  printf '/tmp\n'
}

CASEIN_USER_HOME="$(resolve_home)"
CASEIN_DIR="${CASEIN_USER_HOME}/.casein"
TMUX_DIR="${CASEIN_DIR}/tmux"
CONF_PATH="${TMUX_DIR}/casein.conf"
# Server start cwd: never a worktree. Prefer real HOME, then /tmp.
START_CWD="${CASEIN_USER_HOME}"
if [[ ! -d "${START_CWD}" ]]; then
  START_CWD="/tmp"
fi

resolve_tmux_bin() {
  if [[ -n "${TMUX_BIN}" && -x "${TMUX_BIN}" ]]; then
    printf '%s\n' "${TMUX_BIN}"
    return 0
  fi
  if command -v tmux >/dev/null 2>&1; then
    command -v tmux
    return 0
  fi
  return 1
}

install_tmux_apt() {
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update -q
    apt-get install -y -q tmux
  else
    sudo apt-get update -q
    sudo apt-get install -y -q tmux
  fi
}

# Embedded conf mirrors priv/tmux/casein.conf. Keep in sync when editing either.
write_conf() {
  mkdir -p "${TMUX_DIR}"
  cat >"${CONF_PATH}.tmp" <<'CONF'
# Casein labeled-tmux defaults (remote + local user bootstrap, issue #556).
# Installed under ~/.casein/tmux/casein.conf. Never touches the default server.

set-option -g mouse on
set-option -s escape-time 0
set-option -g history-limit 50000
set-option -g focus-events on
set-option -g status off
set-option -g pane-border-status off
set-option -g pane-border-lines single
set-option -ga terminal-overrides ",xterm-256color:Tc"
set-option -g renumber-windows on

# Keep the server process alive after the last session is destroyed so a
# transient kill-session storm does not tear down the whole -L server.
set-option -s exit-empty off

bind-key -T prefix w display-message "Casein: use the browser window picker (C-b w)"
bind-key -T prefix s display-message "Casein: use the browser session picker (C-b s)"
CONF
  # Atomic replace so a concurrent reader never sees a partial file.
  mv -f "${CONF_PATH}.tmp" "${CONF_PATH}"
  chmod 0644 "${CONF_PATH}"
}

server_live() {
  local bin="$1"
  # Always probe with an exact -L label. Bare `tmux` is forbidden — inherited
  # $TMUX can name a dead path while the labeled server is healthy.
  #
  # Prefer list-sessions over bare has-session: without -t, has-session talks
  # about the *current* session and fails from a non-attached client even when
  # the server is up. list-sessions exit 0 ⇒ live with sessions; exit 1 with
  # "no server running" / "error connecting" ⇒ down; exit 1 with empty body ⇒
  # live but empty (exit-empty off, no sessions yet).
  local out
  out="$("${bin}" -L "${LABEL}" list-sessions 2>&1 || true)"
  if printf '%s' "${out}" | grep -qiE 'no server running|error connecting|failed to connect|no such file'; then
    return 1
  fi
  # Non-empty listing or empty+silent failure both mean the server answered.
  return 0
}

soft_apply_exit_empty() {
  local bin="$1"
  "${bin}" -L "${LABEL}" set-option -s exit-empty off 2>/dev/null || true
}

start_labeled_server() {
  local bin="$1"
  # Critical: cd to a durable directory before forking the server. A server
  # whose cwd is later deleted wedges new panes (getcwd failures).
  (
    cd "${START_CWD}" || cd /tmp || cd /
    # No -A: new-session -A -d is not idempotent on this box (reattaches /
    # reinterprets -d). Only called when server_live returned false.
    exec "${bin}" -L "${LABEL}" -f "${CONF_PATH}" \
      new-session -d -s __casein_keepalive -c "${START_CWD}"
  )
}

report() {
  local bin_state conf_state server_state
  if bin="$(resolve_tmux_bin 2>/dev/null)"; then
    bin_state="ok path=${bin} version=$("${bin}" -V 2>/dev/null || echo unknown)"
  else
    bin_state="missing"
    bin=""
  fi
  if [[ -f "${CONF_PATH}" ]]; then
    conf_state="ok path=${CONF_PATH}"
  else
    conf_state="missing path=${CONF_PATH}"
  fi
  if [[ -n "${bin}" ]] && server_live "${bin}"; then
    server_state="live label=${LABEL}"
  else
    server_state="down label=${LABEL}"
  fi
  log "tmux:   ${bin_state}"
  log "conf:   ${conf_state}"
  log "server: ${server_state}"
  log "native: tmux -L ${LABEL} list-sessions"
  log "default server: never touched"
}

# --- main -------------------------------------------------------------------

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  report
  if resolve_tmux_bin >/dev/null && [[ -f "${CONF_PATH}" ]]; then
    bin="$(resolve_tmux_bin)"
    if server_live "${bin}"; then
      exit 0
    fi
  fi
  exit 1
fi

if ! bin="$(resolve_tmux_bin)"; then
  if [[ "${INSTALL_TMUX}" -eq 1 ]]; then
    log "tmux missing; installing via apt"
    install_tmux_apt
    bin="$(resolve_tmux_bin)" || {
      echo "error: tmux still missing after install" >&2
      exit 1
    }
  else
    echo "error: tmux not found on PATH. Re-run with --install-tmux (apt) or install tmux first." >&2
    exit 1
  fi
fi

log "using tmux: ${bin} ($("${bin}" -V 2>/dev/null || echo unknown))"
write_conf
log "wrote conf: ${CONF_PATH}"

if server_live "${bin}"; then
  log "labeled server already live (-L ${LABEL}); not restarting"
  soft_apply_exit_empty "${bin}"
  # Soft-load conf options that are safe on a live server.
  "${bin}" -L "${LABEL}" source-file "${CONF_PATH}" 2>/dev/null || true
else
  log "starting labeled server (-L ${LABEL}) from cwd=${START_CWD}"
  start_labeled_server "${bin}"
  # Brief settle; avoid sleep loops — one short wait is enough for forking.
  sleep 0.2
  if ! server_live "${bin}"; then
    echo "error: labeled server did not come up on -L ${LABEL}" >&2
    exit 1
  fi
  soft_apply_exit_empty "${bin}"
  log "labeled server is live"
fi

report
log "done"
exit 0
