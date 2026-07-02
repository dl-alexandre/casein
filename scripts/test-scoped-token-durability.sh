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

printf "DEV_IDE_WORKSPACE_API_TOKENS='%s'\n" "$INITIAL_JSON" >"$TMP_ENV"

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

echo "OK: scoped token durability checks passed"