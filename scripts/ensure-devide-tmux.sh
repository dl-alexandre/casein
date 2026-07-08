#!/usr/bin/env bash
# Install/enable the host tmux keepalive unit and pin tmux to the cutover
# version (default 3.6b). Run on the devbox after deploy or when diagnosing
# session wipes.
#
# Usage:
#   bash scripts/ensure-devide-tmux.sh           # install + enable + start
#   bash scripts/ensure-devide-tmux.sh --disable # stop + disable unit
#   TMUX_VERSION=3.6b bash scripts/ensure-devide-tmux.sh --reinstall-binary
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="${ROOT}/scripts/devide-tmux.service"
UNIT_DST="/etc/systemd/system/devide-tmux.service"
TMUX_VERSION="${TMUX_VERSION:-3.6b}"
TMUX_PREFIX="${TMUX_PREFIX:-/usr/local}"

usage() {
  sed -n '2,12p' "$0"
}

disable_unit() {
  sudo systemctl disable --now devide-tmux.service 2>/dev/null || true
  echo "devide-tmux.service disabled"
  exit 0
}

reinstall_binary() {
  echo "Installing tmux ${TMUX_VERSION} to ${TMUX_PREFIX}…"
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

  conf="${ROOT}/priv/tmux/devide.conf"
  if [[ -f /opt/devide/release/lib/dev_ide-0.1.0/priv/tmux/devide.conf ]]; then
    conf=/opt/devide/release/lib/dev_ide-0.1.0/priv/tmux/devide.conf
  fi

  tmp="$(mktemp)"
  sed \
    -e "s|__TMUX_BIN__|${tmux_bin}|g" \
    -e "s|__TMUX_CONF__|${conf}|g" \
    "${UNIT_SRC}" >"${tmp}"
  sudo install -m 0644 "${tmp}" "${UNIT_DST}"
  rm -f "${tmp}"
  sudo systemctl daemon-reload
  sudo systemctl enable --now devide-tmux.service
  echo "devide-tmux.service enabled (tmux=$(${tmux_bin} -V))"
  # Soft apply exit-empty off on a live server if one is already running.
  "${tmux_bin}" -L devide set-option -s exit-empty off 2>/dev/null || true
  "${tmux_bin}" -L devide display-message -p 'server=#{socket_path} version=#{version}' 2>/dev/null || true
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --disable) disable_unit ;;
  --reinstall-binary) reinstall_binary; install_unit ;;
  "") install_unit ;;
  *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
esac
