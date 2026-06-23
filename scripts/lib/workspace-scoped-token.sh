#!/usr/bin/env bash
# Helpers for workspace-scoped MCP bearer tokens (DEV_IDE_WORKSPACE_API_TOKENS).
# Sourced by setup-devbox-agent-pairing.sh — not executed directly.

# Read DEV_IDE_WORKSPACE_API_TOKENS JSON from an env file (best effort).
workspace_scoped_token_read_json() {
  local env_file="$1"
  local line=""

  if [[ -r "$env_file" ]]; then
    line="$(awk -F= '/^DEV_IDE_WORKSPACE_API_TOKENS=/{sub(/^DEV_IDE_WORKSPACE_API_TOKENS=/, ""); print; exit}' "$env_file")"
  elif sudo test -r "$env_file" 2>/dev/null; then
    line="$(sudo awk -F= '/^DEV_IDE_WORKSPACE_API_TOKENS=/{sub(/^DEV_IDE_WORKSPACE_API_TOKENS=/, ""); print; exit}' "$env_file")"
  else
    printf '{}'
    return 0
  fi

  line="${line#\'}"
  line="${line%\'}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "${line:-{}}"
}

# Ensure env file maps a scoped token → workspace_id.
# Prints two lines: scoped_token, then merged JSON (caller uses mapfile).
# Args: env_file workspace_id
workspace_scoped_token_ensure_for_workspace() {
  local env_file="$1"
  local workspace_id="$2"
  local existing_json

  existing_json="$(workspace_scoped_token_read_json "$env_file")"

  WORKSPACE_ID="$workspace_id" EXISTING_JSON="$existing_json" python3 - <<'PY'
import json, os, secrets, sys

workspace_id = os.environ["WORKSPACE_ID"]
raw = os.environ.get("EXISTING_JSON", "").strip() or "{}"

try:
    tokens = json.loads(raw)
except json.JSONDecodeError:
    tokens = {}

if not isinstance(tokens, dict):
    tokens = {}

for tok, val in tokens.items():
    if val == workspace_id:
        print(tok)
        print(json.dumps(tokens))
        sys.exit(0)
    if isinstance(val, list) and workspace_id in val:
        print(tok)
        print(json.dumps(tokens))
        sys.exit(0)

new_tok = secrets.token_hex(32)
tokens[new_tok] = workspace_id
print(new_tok)
print(json.dumps(tokens))
PY
}

# Merge scoped tokens JSON into env file (sudo when needed). Args: env_file json
workspace_scoped_token_write_env() {
  local env_file="$1"
  local json="$2"

  local tmp
  tmp="$(mktemp)"

  if [[ -r "$env_file" ]]; then
    cp "$env_file" "$tmp" 2>/dev/null || sudo cp "$env_file" "$tmp"
    sudo chown "$(id -u):$(id -g)" "$tmp" 2>/dev/null || true
  else
    echo "error: cannot read ${env_file}" >&2
    rm -f "$tmp"
    return 1
  fi

  if grep -q '^DEV_IDE_WORKSPACE_API_TOKENS=' "$tmp"; then
    sed -i "s|^DEV_IDE_WORKSPACE_API_TOKENS=.*|DEV_IDE_WORKSPACE_API_TOKENS='${json}'|" "$tmp"
  else
    printf "\nDEV_IDE_WORKSPACE_API_TOKENS='%s'\n" "$json" >>"$tmp"
  fi

  if [[ -w "$env_file" ]]; then
    cp "$tmp" "$env_file"
  else
    sudo cp "$tmp" "$env_file"
    sudo chmod 600 "$env_file"
  fi

  rm -f "$tmp"
}