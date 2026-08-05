#!/usr/bin/env bash
# Install/enable the host tmux keepalive unit and pin tmux to the cutover
# version. Run on the devbox after deploy or when diagnosing session wipes.
#
# Usage:
#   bash scripts/ensure-casein-tmux.sh           # install + enable (+ start if down)
#   bash scripts/ensure-casein-tmux.sh --disable # stop + disable unit
#   bash scripts/ensure-casein-tmux.sh --reinstall-binary
#   TMUX_VERSION=3.6b bash scripts/ensure-casein-tmux.sh --reinstall-binary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="${ROOT}/scripts/casein-tmux.service"
UNIT_DST="/etc/systemd/system/casein-tmux.service"
# The version pin lives in scripts/install-tmux.sh — do NOT duplicate a default
# here. This script used to default to 3.6b while install-tmux.sh had moved to
# 3.7 (which is what the devbox actually runs), so `--reinstall-binary` — the
# command docs/subsystems/tmux_crash_recovery.md tells operators to run while
# diagnosing a crash — would silently *downgrade* the running server. Leave
# unset to inherit the single pinned version; export TMUX_VERSION to override.
TMUX_VERSION="${TMUX_VERSION:-}"
TMUX_PREFIX="${TMUX_PREFIX:-/usr/local}"

usage() {
  sed -n '2,12p' "$0"
}

disable_unit() {
  sudo systemctl disable --now casein-tmux.service 2>/dev/null || true
  echo "casein-tmux.service disabled"
  exit 0
}

reinstall_binary() {
  echo "Installing tmux ${TMUX_VERSION:-(pinned in install-tmux.sh)} to ${TMUX_PREFIX}…"
  # TMUX_VERSION is exported empty when unset; install-tmux.sh uses `:-` so an
  # empty value falls through to its own pin rather than forcing a version.
  TMUX_VERSION="${TMUX_VERSION}" TMUX_PREFIX="${TMUX_PREFIX}" \
    bash "${ROOT}/scripts/install-tmux.sh"
  "${TMUX_PREFIX}/bin/tmux" -V
}

install_unit() {
  local tmux_bin conf
  tmux_bin="${TMUX_PREFIX}/bin/tmux"
  if [[ ! -x "${tmux_bin}" ]]; then
    tmux_bin="$(command -v tmux)"
  fi

  conf="${ROOT}/priv/tmux/casein.conf"
  if [[ -f /opt/casein/release/lib/casein-0.1.0/priv/tmux/casein.conf ]]; then
    conf=/opt/casein/release/lib/casein-0.1.0/priv/tmux/casein.conf
  fi

  tmp="$(mktemp)"
  sed \
    -e "s|__TMUX_BIN__|${tmux_bin}|g" \
    -e "s|__TMUX_CONF__|${conf}|g" \
    "${UNIT_SRC}" >"${tmp}"
  sudo install -m 0644 "${tmp}" "${UNIT_DST}"
  rm -f "${tmp}"
  sudo systemctl daemon-reload

  # Never `--now` while an unsupervised server is already live.
  #
  # Two independent reasons, both verified on the devbox 2026-08-03:
  #
  #   1. ExecStart is `new-session -d -s __casein_keepalive`. That session
  #      already exists on a live server, so the command exits 1 ("duplicate
  #      session") and Restart=on-failure retries until the start limit trips,
  #      leaving the unit `failed` — i.e. installing it would look like it
  #      armed protection while actually arming nothing. Adding `-A` does NOT
  #      fix this: with `-A` tmux treats the existing session as an attach and
  #      reinterprets `-d` as attach-session's "detach other clients", so it
  #      tries to attach from a non-tty and fails with "open terminal failed".
  #
  #   2. systemd cannot adopt an already-daemonized server. Type=forking picks
  #      MainPID from the process left in the unit cgroup; a server started
  #      outside systemd is not there, and LimitCORE=infinity only applies to
  #      processes systemd itself spawns (the orphan keeps `Max core file
  #      size 0`, which is why the 02:25 crash left no core).
  #
  # So: enable (arm for boot) always, but only start now when the server is
  # actually down. Otherwise supervision begins at the next server start —
  # tell the operator plainly rather than pretending it is already active.
  sudo systemctl enable casein-tmux.service

  if "${tmux_bin}" -L casein has-session 2>/dev/null; then
    echo "casein-tmux.service installed + enabled (starts at next boot)."
    echo
    echo "  NOT started now: a tmux server is already live on -L casein and"
    echo "  systemd cannot adopt it. That server keeps 'Max core file size 0'"
    echo "  and has no auto-restart. To hand it over, restart the cockpit at a"
    echo "  time you choose (this kills live panes; ScrollbackArchive +"
    echo "  SessionOwner recover restore history and layout):"
    echo
    echo "      tmux -L casein kill-server && sudo systemctl start casein-tmux"
    echo
    # Soft apply exit-empty off on the live server so it survives session reaping.
    "${tmux_bin}" -L casein set-option -s exit-empty off 2>/dev/null || true
  else
    sudo systemctl start casein-tmux.service
    echo "casein-tmux.service enabled + started (tmux=$(${tmux_bin} -V))"
  fi

  "${tmux_bin}" -L casein display-message -p 'server=#{socket_path} version=#{version}' 2>/dev/null || true
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --disable) disable_unit ;;
  --reinstall-binary) reinstall_binary; install_unit ;;
  "") install_unit ;;
  *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
esac
