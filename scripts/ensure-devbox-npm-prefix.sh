#!/usr/bin/env bash
#
# Point npm global installs at a user-writable prefix that is separate from
# ~/.local/bin. DevIDE owns ~/.local/bin for agent shims; npm package updates
# (notably `codex update`) must not replace those shims with package symlinks.
#
# Usage:
#   bash scripts/ensure-devbox-npm-prefix.sh
#
set -euo pipefail

PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
mkdir -p "${PREFIX}/bin"

current="$(npm config get prefix 2>/dev/null || true)"
if [[ "$current" == "$PREFIX" ]]; then
  echo "npm global prefix already set to ${PREFIX}"
  exit 0
fi

npm config set prefix "${PREFIX}"
echo "npm global prefix set to ${PREFIX} (was: ${current:-unset})"
