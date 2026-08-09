#!/usr/bin/env bash
#
# Hermetic unit tests for spawn_worker_resolve_env_file cross-session isolation.
# Shadows HOME so staging lives under a temp tree; never touches real agent-mcp
# or opens a tmux window.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/spawn-agent-worker.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/spawn-env-resolve.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
export PATH="/usr/bin:/bin:${PATH:-}"

WS_A="dalexandre-devide"
WS_B="dalexandre-mira"
ENV_A="${HOME}/.casein/agent-mcp/${WS_A}/env.sh"
ENV_B="${HOME}/.casein/agent-mcp/${WS_B}/env.sh"
SESSION_B="casein_${WS_B}_art-142632e1-3f15-4b55-8017-54db1204468a"
SESSION_A="casein_${WS_A}_wt-fbd6fbe9-091b-4a9e-92d7-9d6a7afb56fb"

mkdir -p "$(dirname "$ENV_A")" "$(dirname "$ENV_B")"
printf 'export CASEIN_WORKSPACE_NAME=%q\nexport CASEIN_WORKSPACE_ID=%q\n' "$WS_A" "ws-a" >"$ENV_A"
printf 'export CASEIN_WORKSPACE_NAME=%q\nexport CASEIN_WORKSPACE_ID=%q\n' "$WS_B" "ws-b" >"$ENV_B"

# Pull only the resolver body from spawn-agent-worker.sh (avoid running main).
extract_fn() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\) \\{" {grab=1}
    grab {print}
    grab && $0 == "}" {exit}
  ' "$file"
}

RESOLVER_SRC="$(
  cat <<EOF
set -euo pipefail
# shellcheck source=/dev/null
source "${ROOT}/scripts/lib/agent-env.sh"
$(extract_fn "$SCRIPT" spawn_worker_resolve_env_file)
EOF
)"

run_resolve() {
  local session="${1:-}"
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    CASEIN_AGENT_ENV_FILE="${CASEIN_AGENT_ENV_FILE-}" \
    CASEIN_AGENT_MCP_HOME="${CASEIN_AGENT_MCP_HOME-}" \
    CASEIN_WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME-}" \
    bash -c "$RESOLVER_SRC
spawn_worker_resolve_env_file $(printf '%q' "$session")
"
}

# ── 1. A-orchestrator env + explicit B session → B's env.sh ─────────────────
export CASEIN_AGENT_ENV_FILE="$ENV_A"
export CASEIN_AGENT_MCP_HOME="$(dirname "$ENV_A")"
export CASEIN_WORKSPACE_NAME="$WS_A"

got="$(run_resolve "$SESSION_B")"
[[ "$got" == "$(realpath -m "$ENV_B")" ]] ||
  fail "explicit B session should pick B env, got '${got}' (caller A=${ENV_A})"
ok "A-orchestrator + B-session → B env"

# ── 2. Same with only MCP_HOME set (no CASEIN_AGENT_ENV_FILE) ────────────────
unset CASEIN_AGENT_ENV_FILE
export CASEIN_AGENT_MCP_HOME="$(dirname "$ENV_A")"
export CASEIN_WORKSPACE_NAME="$WS_A"

got="$(run_resolve "$SESSION_B")"
[[ "$got" == "$(realpath -m "$ENV_B")" ]] ||
  fail "MCP_HOME-only caller still must not win over B session, got '${got}'"
ok "caller MCP_HOME ignored when session names B"

# ── 3. No session arg → inherited caller env is the fallback ─────────────────
export CASEIN_AGENT_ENV_FILE="$ENV_A"
got="$(run_resolve "")"
[[ "$got" == "$(realpath -m "$ENV_A")" ]] ||
  fail "empty session should fall back to caller env, got '${got}'"
ok "no session → caller CASEIN_AGENT_ENV_FILE"

# ── 4. Session A with caller A → A (same workspace) ──────────────────────────
got="$(run_resolve "$SESSION_A")"
[[ "$got" == "$(realpath -m "$ENV_A")" ]] ||
  fail "same-workspace session should resolve A, got '${got}'"
ok "A session + A caller → A env"

# ── 5. B session but B env missing → refuse, name both workspaces ────────────
rm -f "$ENV_B"
export CASEIN_AGENT_ENV_FILE="$ENV_A"
export CASEIN_WORKSPACE_NAME="$WS_A"
set +e
err="$(
  env \
    HOME="$HOME" \
    PATH="$PATH" \
    CASEIN_AGENT_ENV_FILE="$CASEIN_AGENT_ENV_FILE" \
    CASEIN_WORKSPACE_NAME="$CASEIN_WORKSPACE_NAME" \
    bash -c "$RESOLVER_SRC
spawn_worker_resolve_env_file $(printf '%q' "$SESSION_B")
" 2>&1 >/dev/null
)"
code=$?
set -e
[[ "$code" -ne 0 ]] || fail "missing target env must fail, exited 0"
printf '%s' "$err" | grep -Fq "target_workspace=${WS_B}" ||
  fail "error must name target workspace, got: $err"
printf '%s' "$err" | grep -Fq "caller_workspace=${WS_A}" ||
  fail "error must name caller workspace, got: $err"
printf '%s' "$err" | grep -Fq "ignoring caller CASEIN_AGENT_ENV_FILE" ||
  fail "error must say caller env was ignored, got: $err"
ok "missing B env refuses with both workspace names"

echo "ALL ${pass} TESTS PASSED"
