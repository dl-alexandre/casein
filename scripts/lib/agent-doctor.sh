#!/usr/bin/env bash
#
# DevIDE agent pairing health check.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"
# shellcheck source=lib/agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"

PASS=0
WARN=0
FAIL=0

pass() { printf 'OK   %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN %s\n' "$*" >&2; WARN=$((WARN + 1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

check_shims() {
  local runtime bin
  for runtime in grok claude codex opencode agent devide; do
    bin="${HOME}/.local/bin/${runtime}"
    if [[ -x "$bin" ]]; then
      pass "shim installed: ${runtime}"
    else
      warn "shim missing: ${runtime} (run scripts/install-agent-shims.sh)"
    fi
  done
}

check_token() {
  local token="${DEV_IDE_API_TOKEN:-}"
  if [[ -z "$token" ]]; then
    fail "DEV_IDE_API_TOKEN is not set"
    return
  fi

  if [[ "$token" == \'*\' || "$token" == \"*\" ]]; then
    fail "DEV_IDE_API_TOKEN has literal shell quotes — run repair-tmux-env.sh"
  else
    pass "DEV_IDE_API_TOKEN is set (unquoted)"
  fi
}

check_bad_redirects() {
  if [[ -n "${GROK_HOME:-}" ]]; then
    fail "GROK_HOME is set (${GROK_HOME}) — unset to keep Grok auth"
  else
    pass "GROK_HOME unset"
  fi

  check_provider_home CLAUDE_CONFIG_DIR claude
  check_provider_home CODEX_HOME codex
}

check_provider_home() {
  local var="$1"
  local runtime="$2"
  local value="${!var:-}"
  local workspace="${DEVIDE_WORKSPACE_NAME:-}"
  local expected=""
  local profile_exists=1

  if [[ -n "$workspace" ]]; then
    expected="$(bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --dir "$workspace" "$runtime" 2>/dev/null || true)"
    if [[ -n "$expected" && -d "$expected" ]]; then
      profile_exists=0
    fi
  fi

  if [[ -z "$value" ]]; then
    if [[ "$profile_exists" -eq 0 ]]; then
      warn "${runtime} auth profile exists but ${var} is not active — run repair-tmux-env.sh or relaunch the agent"
    else
      pass "${runtime} uses global auth"
    fi
    return
  fi

  if [[ "$profile_exists" -eq 0 && "$value" == "$expected" ]]; then
    pass "${runtime} uses workspace auth profile"
  elif agent_auth_profile_under_root "$value"; then
    fail "${var} points at an unknown or missing DevIDE auth profile (${value})"
  else
    fail "${var} is set (${value}) — unset it for global auth or create a DevIDE auth profile"
  fi
}

check_tidewave_mcp() {
  local tidewave_url="${DEVIDE_TIDEWAVE_MCP_URL:-}"
  [[ -n "$tidewave_url" ]] || return 0

  local status
  status="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$tidewave_url" 2>/dev/null || echo 000)"

  if [[ "$status" == "200" ]]; then
    pass "tidewave MCP initialize → 200"
  else
    warn "tidewave MCP initialize → ${status} (${tidewave_url})"
  fi
}

check_mcp_endpoints() {
  local token="${DEV_IDE_API_TOKEN:-}"
  local terminal_url="${DEVIDE_TERMINAL_MCP_URL:-}"
  local preview_url="${DEVIDE_PREVIEW_MCP_URL:-}"

  if [[ -z "$token" || -z "$terminal_url" || -z "$preview_url" ]]; then
    warn "skipping MCP HTTP checks (env incomplete)"
    return
  fi

  local status
  status="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$terminal_url" 2>/dev/null || echo 000)"

  if [[ "$status" == "200" ]]; then
    pass "terminal MCP initialize → 200"
  else
    fail "terminal MCP initialize → ${status}"
  fi

  status="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$preview_url" 2>/dev/null || echo 000)"

  if [[ "$status" == "200" ]]; then
    pass "preview MCP initialize → 200"
  else
    fail "preview MCP initialize → ${status}"
  fi

  local tidewave_url="${DEVIDE_TIDEWAVE_MCP_URL:-}"
  if [[ -z "$tidewave_url" ]]; then
    return
  fi

  status="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"agent-doctor","version":"1.0"}}}' \
    "$tidewave_url" 2>/dev/null || echo 000)"

  if [[ "$status" == "200" ]]; then
    pass "tidewave MCP initialize → 200 (${tidewave_url})"
  else
    warn "tidewave MCP initialize → ${status} (${tidewave_url})"
  fi
}

check_grok_workspace_urls() {
  local workspace_name="${DEVIDE_WORKSPACE_NAME:-}"
  local grok_config="${HOME}/.grok/config.toml"

  [[ -n "$workspace_name" && -f "$grok_config" ]] || return 0

  local slug terminal_key preview_key
  slug="$(
    DEVIDE_WORKSPACE_NAME="$workspace_name" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ['DEVIDE_WORKSPACE_NAME']).strip('-').lower()
print(slug or 'workspace')
"
  )"
  terminal_key="devide-terminal-${slug}"
  preview_key="devide-preview-${slug}"

  if grep -q "\\[mcp_servers\\.${terminal_key}\\]" "$grok_config" 2>/dev/null &&
     grep -q "enabled = true" "$grok_config" 2>/dev/null; then
    if grep -A3 "\\[mcp_servers\\.${terminal_key}\\]" "$grok_config" | grep -q "${DEVIDE_WORKSPACE_ID:-}"; then
      pass "grok config has enabled workspace-keyed terminal MCP"
    else
      warn "grok terminal MCP URL may not match workspace ${workspace_name}"
    fi
  else
    warn "grok config missing enabled ${terminal_key} — run devide mcp ensure"
  fi

  if ! grep -q "\\[mcp_servers\\.${preview_key}\\]" "$grok_config" 2>/dev/null; then
    warn "grok config missing ${preview_key}"
  fi
}

check_auth_files() {
  [[ -f "${HOME}/.grok/auth.json" ]] && pass "grok auth.json present" || warn "grok auth.json missing"

  local codex_auth="${CODEX_HOME:-${HOME}/.codex}/auth.json"
  [[ -f "$codex_auth" ]] && pass "codex auth.json present" || warn "codex auth.json missing (${codex_auth})"

  local claude_auth="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
  [[ -f "$claude_auth" ]] && pass "claude credentials present" || warn "claude credentials missing (${claude_auth})"
}

main() {
  echo "==> DevIDE agent doctor"

  if agent_env_resolve 2>/dev/null; then
    pass "agent env resolved"
  else
    warn "agent env not fully resolved (continuing with partial checks)"
  fi

  check_shims
  check_token
  check_bad_redirects
  check_mcp_endpoints
  check_tidewave_mcp
  check_grok_workspace_urls
  check_auth_files

  if [[ -n "${TMUX:-}" ]]; then
    if bash "${ROOT}/scripts/lib/repair-tmux-env.sh" >/dev/null 2>&1; then
      pass "tmux session env repaired"
    else
      warn "tmux session env repair skipped or failed"
    fi
  fi

  echo "==> summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failures"
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
