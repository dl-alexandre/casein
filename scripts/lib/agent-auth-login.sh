#!/usr/bin/env bash
#
# Log a provider CLI into a Casein auth profile.
#
# Usage:
#   scripts/devide agent auth signin <claude|codex>
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

usage() {
  cat <<'EOF'
Usage: agent-auth-login.sh <owner> <claude|codex> [provider args...]

Normally use: devide agent auth signin <claude|codex>

Creates an owner auth home and launches the provider CLI inside it. Workspaces
for the same owner use that isolated home instead of the host global provider auth.
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
  claude|codex) ;;
  *)
    echo "error: unsupported runtime: ${RUNTIME}" >&2
    usage >&2
    exit 64
    ;;
esac

PROFILE_DIR="$(agent_auth_profile_ensure_named "$OWNER" "$RUNTIME")"
BIN="$(real_agent_bin "$RUNTIME")"

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
esac

exec "$BIN" "$@"
