#!/usr/bin/env bash
#
# Log a provider CLI into a workspace-scoped or shared DevIDE auth profile.
#
# Usage:
#   scripts/lib/agent-auth-login.sh <workspace> <claude|codex> [provider args...]
#   scripts/lib/agent-auth-login.sh --profile <profile> <claude|codex> [provider args...]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

usage() {
  cat <<'EOF'
Usage: agent-auth-login.sh <workspace> <claude|codex> [provider args...]
       agent-auth-login.sh --profile <profile> <claude|codex> [provider args...]

Creates a workspace or shared auth home and launches the provider CLI inside it.
This keeps normal global provider auth unchanged.
EOF
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 64
fi

MODE="workspace"

if [[ "${1:-}" == "--profile" ]]; then
  MODE="profile"
  shift
fi

SUBJECT="$1"
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

case "$MODE" in
  profile)
    PROFILE_DIR="$(agent_auth_profile_ensure_named "$SUBJECT" "$RUNTIME")"
    ;;
  *)
    PROFILE_DIR="$(agent_auth_profile_ensure "$SUBJECT" "$RUNTIME")"
    ;;
esac
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
