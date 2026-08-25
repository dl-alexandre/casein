#!/usr/bin/env bash
#
# Log a provider CLI into a Casein auth profile.
#
# Usage:
#   scripts/casein agent auth signin <claude|codex|gh>
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

usage() {
  cat <<'EOF'
Usage: agent-auth-login.sh <principal> <claude|codex|gh> [provider args...]

Normally use: casein agent auth signin <claude|codex|gh>

Creates a per-person auth home and launches the CLI inside it. Agents acting as
that principal use the isolated home instead of the host global login.
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 64
fi

OWNER="$1"
RUNTIME="$2"
shift 2

case "$RUNTIME" in
  claude|codex|gh) ;;
  *)
    echo "error: unsupported runtime: ${RUNTIME}" >&2
    usage >&2
    exit 64
    ;;
esac

PROFILE_DIR="$(agent_auth_profile_ensure_named "$OWNER" "$RUNTIME")"

# gh is not an agent runtime, so it has no shim to resolve — take it from PATH.
if [[ "$RUNTIME" == "gh" ]]; then
  BIN="$(command -v gh || true)"
else
  BIN="$(real_agent_bin "$RUNTIME")"
fi

if [[ -z "$BIN" ]]; then
  echo "error: could not find executable for ${RUNTIME} (run scripts/install-agent-shims.sh)" >&2
  exit 1
fi

case "$RUNTIME" in
  codex)
    export CODEX_HOME="$PROFILE_DIR"
    if [[ $# -eq 0 ]]; then
      set -- login
    fi
    ;;
  claude)
    export CLAUDE_CONFIG_DIR="$PROFILE_DIR"
    cat >&2 <<EOF
Launching Claude with CLAUDE_CONFIG_DIR=${PROFILE_DIR}.
Use /login or the first-run login flow inside Claude to authenticate this profile.
EOF
    ;;
  gh)
    export GH_CONFIG_DIR="$PROFILE_DIR"
    # An ambient token silently outranks the config dir, so a login here would
    # appear to succeed while every later `gh` call kept using the token.
    export GH_TOKEN="" GITHUB_TOKEN=""
    if [[ $# -eq 0 ]]; then
      set -- auth login --hostname github.com --git-protocol https --web
    fi
    cat >&2 <<EOF
Logging GitHub CLI into GH_CONFIG_DIR=${PROFILE_DIR}.
Sign in as the GitHub account that should own this principal's commits and PRs.
EOF
    ;;
esac

exec "$BIN" "$@"
