#!/usr/bin/env bash
# Tests agent_env_resolve against inherited server tokens and tmux session env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/grok-goal-7faf284f3c94/implementer}"
mkdir -p "$SCRATCH"

WORKSPACE_NAME="dalexandre-user-investigation"
WORKSPACE_ID="e7c18b93-688b-4bb0-904d-ac93d61e9372"
SESSION_NAME="devide_${WORKSPACE_NAME}_u-test"
STAGED_TOKEN="staged-token-from-env-sh"
TMUX_TOKEN="tmux-supplied-token"
TMUX_WORKSPACE_ID="tmux-supplied-workspace-id"

TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
STAGED_ENV="${HOME}/.casein/agent-mcp/${WORKSPACE_NAME}/env.sh"

MOCK_BIN="$(mktemp -d)"
cat >"${MOCK_BIN}/tmux" <<'MOCKTMUX'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "${3:-}" in
      '#{session_id}')
        printf '%%0\n'
        ;;
      '#{session_name}')
        printf '%s\n' "${FAKE_TMUX_SESSION_NAME:-}"
        ;;
    esac
    ;;
  show-environment)
    if [[ "${FAKE_TMUX_ENV_MODE:-empty}" == "complete" ]]; then
      printf 'CASEIN_API_TOKEN=%s\n' "${FAKE_TMUX_TOKEN:-}"
      printf 'DEVIDE_WORKSPACE_ID=%s\n' "${FAKE_TMUX_WORKSPACE_ID:-}"
    fi
    ;;
esac
MOCKTMUX
chmod +x "${MOCK_BIN}/tmux"

setup_staged_env() {
  mkdir -p "$(dirname "$STAGED_ENV")"
  cat >"$STAGED_ENV" <<EOF
export CASEIN_API_TOKEN="${STAGED_TOKEN}"
export DEVIDE_WORKSPACE_NAME="${WORKSPACE_NAME}"
export DEVIDE_WORKSPACE_ID="${WORKSPACE_ID}"
export DEVIDE_TERMINAL_MCP_URL="http://127.0.0.1:4000/api/terminals/mcp?workspace_id=${WORKSPACE_ID}"
export DEVIDE_PREVIEW_MCP_URL="http://127.0.0.1:4000/api/preview/mcp?workspace_id=${WORKSPACE_ID}"
export DEVIDE_ARTIFACT_MCP_URL="http://127.0.0.1:4000/api/artifacts/mcp?workspace_id=${WORKSPACE_ID}"
export DEVIDE_AGENT_MCP_HOME="${HOME}/.casein/agent-mcp/${WORKSPACE_NAME}"
export DEVIDE_CHECKOUT="${TEST_HOME}/checkout"
EOF
  mkdir -p "${TEST_HOME}/checkout"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

assert_nonempty() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "FAIL: ${label} is empty" >&2
    exit 1
  fi
}

run_test_a_inherited_token_falls_through_to_staged_env() (
  echo "== Test A: inherited server token falls through to staged env.sh =="
  setup_staged_env
  cd "$TEST_HOME"

  export TMUX="/tmp/fake-tmux-socket"
  export FAKE_TMUX_SESSION_NAME="$SESSION_NAME"
  export FAKE_TMUX_ENV_MODE="empty"
  export PATH="${MOCK_BIN}:${PATH}"

  export CASEIN_API_TOKEN="inherited-server-token"
  unset DEVIDE_WORKSPACE_ID DEVIDE_WORKSPACE_NAME DEVIDE_AGENT_ENV_FILE

  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/agent-env.sh"
  agent_env_resolve

  assert_nonempty "DEVIDE_WORKSPACE_NAME" "${DEVIDE_WORKSPACE_NAME:-}"
  assert_nonempty "DEVIDE_WORKSPACE_ID" "${DEVIDE_WORKSPACE_ID:-}"
  assert_eq "DEVIDE_WORKSPACE_NAME" "$WORKSPACE_NAME" "${DEVIDE_WORKSPACE_NAME}"
  assert_eq "DEVIDE_WORKSPACE_ID" "$WORKSPACE_ID" "${DEVIDE_WORKSPACE_ID}"
  assert_eq "CASEIN_API_TOKEN" "$STAGED_TOKEN" "${CASEIN_API_TOKEN}"

  echo "PASS: Test A"
)

run_test_b_complete_tmux_env_succeeds_at_step_4() (
  echo "== Test B: complete tmux session env succeeds at step 4 =="
  rm -rf "${HOME}/.casein"
  cd "$TEST_HOME"

  export TMUX="/tmp/fake-tmux-socket-b"
  export FAKE_TMUX_SESSION_NAME="$SESSION_NAME"
  export FAKE_TMUX_ENV_MODE="complete"
  export FAKE_TMUX_TOKEN="$TMUX_TOKEN"
  export FAKE_TMUX_WORKSPACE_ID="$TMUX_WORKSPACE_ID"
  export PATH="${MOCK_BIN}:${PATH}"

  unset CASEIN_API_TOKEN DEVIDE_WORKSPACE_ID DEVIDE_WORKSPACE_NAME DEVIDE_AGENT_ENV_FILE

  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/agent-env.sh"
  agent_env_resolve

  assert_eq "CASEIN_API_TOKEN" "$TMUX_TOKEN" "${CASEIN_API_TOKEN}"
  assert_eq "DEVIDE_WORKSPACE_ID" "$TMUX_WORKSPACE_ID" "${DEVIDE_WORKSPACE_ID}"
  if [[ -f "$STAGED_ENV" ]]; then
    echo "FAIL: staged env.sh was read when tmux session env was complete" >&2
    exit 1
  fi

  echo "PASS: Test B"
)

run_test_materialize_after_inherited_token_resolve() (
  echo "== Test C: materialize-agent-mcp.sh after inherited-token resolve =="
  setup_staged_env
  cd "$TEST_HOME"

  export TMUX="/tmp/fake-tmux-socket-c"
  export FAKE_TMUX_SESSION_NAME="$SESSION_NAME"
  export FAKE_TMUX_ENV_MODE="empty"
  export PATH="${MOCK_BIN}:${PATH}"

  export CASEIN_API_TOKEN="inherited-server-token"
  unset DEVIDE_WORKSPACE_ID DEVIDE_WORKSPACE_NAME DEVIDE_AGENT_ENV_FILE DEVIDE_CHECKOUT

  # shellcheck source=/dev/null
  source "${ROOT}/scripts/lib/agent-env.sh"
  agent_env_resolve

  local export_log="${SCRATCH}/materialize-after-resolve.log"
  bash "${ROOT}/scripts/materialize-agent-mcp.sh" --export >"$export_log"
  if grep -q 'HEAD is now at' "$export_log"; then
    echo "FAIL: materialize --export polluted DEVIDE_CHECKOUT from inherited env" >&2
    cat "$export_log" >&2
    exit 1
  fi
  if ! grep -Fq "export DEVIDE_CHECKOUT=${TEST_HOME}/checkout" "$export_log"; then
    echo "FAIL: materialize --export did not emit staged DEVIDE_CHECKOUT" >&2
    cat "$export_log" >&2
    exit 1
  fi

  echo "PASS: Test C"
)

main() {
  local log="${SCRATCH}/agent-env-resolve-test.log"
  {
    run_test_a_inherited_token_falls_through_to_staged_env
    run_test_b_complete_tmux_env_succeeds_at_step_4
    run_test_materialize_after_inherited_token_resolve
    echo "ALL TESTS PASSED"
  } 2>&1 | tee "$log"

  if ! grep -q "ALL TESTS PASSED" "$log"; then
    exit 1
  fi
}

main "$@"
