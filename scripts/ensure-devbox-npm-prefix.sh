#!/usr/bin/env bash
#
# Point npm global installs at ~/.local so user CLIs (codex update, npm install -g)
# do not try to write under /usr (root-owned on devbox).
#
# Usage:
#   bash scripts/ensure-devbox-npm-prefix.sh
#
set -euo pipefail

PREFIX="${HOME}/.local"
mkdir -p "${PREFIX}/bin"

current="$(npm config get prefix 2>/dev/null || true)"
if [[ "$current" == "$PREFIX" ]]; then
  echo "npm global prefix already set to ${PREFIX}"
  exit 0
fi

npm config set prefix "${PREFIX}"
echo "npm global prefix set to ${PREFIX} (was: ${current:-unset})"