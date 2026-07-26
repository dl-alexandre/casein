#!/usr/bin/env bash
#
# Verify workspace_scoped_token_ensure_for_workspace preserves existing tokens
# instead of minting a new one on every refresh (the redeploy footgun).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/workspace-scoped-token.sh
source "${ROOT}/scripts/lib/workspace-scoped-token.sh"

TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT

WORKSPACE_ID="ws-durability-test"
EXISTING_TOKEN="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
INITIAL_JSON="{\"${EXISTING_TOKEN}\":\"${WORKSPACE_ID}\"}"

printf "CASEIN_WORKSPACE_API_TOKENS='%s'\n" "$INITIAL_JSON" >"$TMP_ENV"

mapfile -t lines < <(workspace_scoped_token_ensure_for_workspace "$TMP_ENV" "$WORKSPACE_ID")
token="${lines[0]:-}"
merged="${lines[1]:-}"

if [[ "$token" != "$EXISTING_TOKEN" ]]; then
  echo "FAIL: expected preserved token, got ${token}" >&2
  exit 1
fi

if [[ "$merged" != "$INITIAL_JSON" ]]; then
  echo "FAIL: merged JSON changed unexpectedly: ${merged}" >&2
  exit 1
fi

# Second call must still return the same token (idempotent).
mapfile -t lines2 < <(workspace_scoped_token_ensure_for_workspace "$TMP_ENV" "$WORKSPACE_ID")
if [[ "${lines2[0]:-}" != "$EXISTING_TOKEN" ]]; then
  echo "FAIL: second ensure minted a new token" >&2
  exit 1
fi

# Unknown workspace should mint without disturbing the existing mapping.
OTHER_ID="ws-other"
mapfile -t lines3 < <(workspace_scoped_token_ensure_for_workspace "$TMP_ENV" "$OTHER_ID")
new_token="${lines3[0]:-}"
merged3="${lines3[1]:-}"

if [[ -z "$new_token" || "$new_token" == "$EXISTING_TOKEN" ]]; then
  echo "FAIL: expected a distinct token for other workspace" >&2
  exit 1
fi

if ! grep -q "$EXISTING_TOKEN" <<<"$merged3"; then
  echo "FAIL: original token mapping dropped when adding other workspace" >&2
  exit 1
fi

# --- workspace_scoped_token_is_registered_for -------------------------------
# The materializer trusts this to decide whether an inherited CASEIN_API_TOKEN
# may be written as-is or must be swapped/fail-closed. Exercise it hermetically
# against a temp env-file registry and a temp runtime store.
VAL_ENV="$(mktemp)"
VAL_STORE="$(mktemp)"
trap 'rm -f "$TMP_ENV" "$VAL_ENV" "$VAL_STORE"' EXIT

ENV_TOKEN="1111111111111111111111111111111111111111111111111111111111111111"
STORE_TOKEN="2222222222222222222222222222222222222222222222222222222222222222"
OTHER_TOKEN="3333333333333333333333333333333333333333333333333333333333333333"
LIST_TOKEN="4444444444444444444444444444444444444444444444444444444444444444"
WS="ws-validate"

printf "CASEIN_WORKSPACE_API_TOKENS='%s'\n" \
  "{\"${ENV_TOKEN}\":\"${WS}\",\"${OTHER_TOKEN}\":\"ws-different\",\"${LIST_TOKEN}\":[\"ws-a\",\"${WS}\"]}" \
  >"$VAL_ENV"
printf '{"%s":"%s"}\n' "$STORE_TOKEN" "$WS" >"$VAL_STORE"
export CASEIN_WORKSPACE_TOKENS_STORE="$VAL_STORE"

assert_registered() { # label token expect_rc
  local label="$1" token="$2" expect="$3" rc=0
  workspace_scoped_token_is_registered_for "$VAL_ENV" "$WS" "$token" || rc=$?
  if [[ "$rc" -ne "$expect" ]]; then
    echo "FAIL: is_registered_for ${label}: rc=${rc} expected ${expect}" >&2
    exit 1
  fi
}

assert_registered "env-file token"          "$ENV_TOKEN"   0
assert_registered "runtime-store token"     "$STORE_TOKEN" 0
assert_registered "list-valued mapping"     "$LIST_TOKEN"  0
assert_registered "other-workspace token"   "$OTHER_TOKEN" 1
assert_registered "unknown token"           "deadbeef"     1
assert_registered "empty token"             ""             1

echo "OK: scoped token durability + registry-validation checks passed"
