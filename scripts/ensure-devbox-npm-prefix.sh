#!/usr/bin/env bash
#
# Point npm global installs at a user-writable prefix that is separate from
# the DevIDE agent shim dir (~/.devide/agent-shims) and ~/.local/bin; npm
# package updates (notably `codex update`) must not clobber launcher shims
# or user binaries with package symlinks.
#
# Usage:
#   bash scripts/ensure-devbox-npm-prefix.sh
#
set -euo pipefail

# Same boundary rule as install-agent-shims.sh: repointing the npm global
# prefix affects all of the user's `npm -g` installs, so only do it on
# DevIDE-managed hosts (or with an explicit DEV_IDE_MANAGE_NPM_PREFIX=1).
case "${DEV_IDE_MANAGE_NPM_PREFIX:-}" in
  1) ;;
  0)
    echo "npm global prefix left alone (DEV_IDE_MANAGE_NPM_PREFIX=0)"
    exit 0
    ;;
  *)
    if [[ ! -f /etc/devide/devide.env ]]; then
      echo "npm global prefix left alone (not a DevIDE-managed host; set DEV_IDE_MANAGE_NPM_PREFIX=1 to opt in)"
      exit 0
    fi
    ;;
esac

PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
mkdir -p "${PREFIX}/bin"

current="$(npm config get prefix 2>/dev/null || true)"
if [[ "$current" == "$PREFIX" ]]; then
  echo "npm global prefix already set to ${PREFIX}"
  exit 0
fi

npm config set prefix "${PREFIX}"
echo "npm global prefix set to ${PREFIX} (was: ${current:-unset})"
