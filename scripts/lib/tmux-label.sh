#!/usr/bin/env bash
#
# tmux-label.sh — portable labeled-tmux discipline for product scripts (#248).
#
# Live Casein servers often run as `-L devide` with the socket RENAMED to
# `casein`. Bare `tmux …` follows inherited $TMUX or the default server and
# hits the wrong place (or a dead path). Product scripts must always address
# the labeled server explicitly.
#
# Source from a product script:
#   # shellcheck source=tmux-label.sh
#   source "${ROOT}/scripts/lib/tmux-label.sh"
#   casein_tmux list-sessions
#
# Env (first non-empty wins):
#   CASEIN_TMUX_LABEL
#   CASEIN_TMUX_SOCKET_LABEL
# Default label: casein
#
# Does not touch the default (unlabeled) tmux server.

# Resolve the Casein tmux server label. Safe to call before `set -u` consumers
# expand other vars; empty env falls through to the portable default.
casein_tmux_label() {
  local label="${CASEIN_TMUX_LABEL:-}"
  if [[ -z "${label}" ]]; then
    label="${CASEIN_TMUX_SOCKET_LABEL:-}"
  fi
  if [[ -z "${label}" ]]; then
    label="casein"
  fi
  printf '%s\n' "${label}"
}

# Drop-in for bare `tmux …` in product scripts. Always passes `-L <label>`.
# Prefer this over hand-rolling `tmux -L "$CASEIN_TMUX_LABEL"` so the resolve
# order stays in one place.
#
# CASEIN_TMUX_BIN overrides the tmux executable (hermetic tests inject a stub).
# The override still receives `-L <label>` so callers stay label-disciplined.
casein_tmux() {
  local label bin
  label="$(casein_tmux_label)"
  bin="${CASEIN_TMUX_BIN:-tmux}"
  if [[ "$bin" == */* ]]; then
    "$bin" -L "${label}" "$@"
  else
    command "$bin" -L "${label}" "$@"
  fi
}
