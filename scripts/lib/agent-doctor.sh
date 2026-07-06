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
  local runtime bin resolved bin_target resolved_target
  for runtime in grok claude codex opencode agent devide; do
    bin="${HOME}/.local/bin/${runtime}"
    if [[ ! -x "$bin" ]]; then
      warn "shim missing: ${runtime} (run scripts/install-agent-shims.sh)"
      continue
    fi
    pass "shim installed: ${runtime}"

    # An installed shim that loses PATH resolution is worse than a missing
    # one: agents launch fine but silently skip MCP injection.
    resolved="$(command -v "$runtime" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      fail "shim unreachable: ${runtime} not on PATH (add ${HOME}/.local/bin to PATH)"
      continue
    fi
    bin_target="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
    resolved_target="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    if [[ "$resolved_target" == "$bin_target" ]]; then
      pass "shim wins PATH resolution: ${runtime}"
    else
      fail "shim shadowed: ${runtime} resolves to ${resolved} — MCP injection will not run (put ${HOME}/.local/bin first on PATH)"
    fi
  done
}

# Each shim embeds the absolute path of scripts/devide at install time; if the
# checkout moves or a deploy worktree is cleaned up, every agent command dies
# at once. The sed pattern must match the install-agent-shims.sh template
# (pinned by scripts/test-agent-shims.sh).
check_shim_targets() {
  local runtime shim cli missing=0 checked=0
  for runtime in grok claude codex opencode agent; do
    shim="${HOME}/.local/bin/${runtime}"
    [[ -f "$shim" ]] || continue
    cli="$(sed -n 's/^exec "\(.*\)" agent launch .*/\1/p' "$shim" | head -n 1)"
    [[ -n "$cli" ]] || continue
    checked=$((checked + 1))
    if [[ ! -x "$cli" ]]; then
      fail "shim target missing: ${runtime} → ${cli} (checkout moved? re-run scripts/install-agent-shims.sh)"
      missing=1
    fi
  done

  if [[ "$checked" -gt 0 && "$missing" -eq 0 ]]; then
    pass "shim targets executable (embedded devide CLI paths resolve)"
  fi
}

# Self-updating agents (grok records a versioned binary path) can strand the
# recorded symlink; launch falls back to a PATH search, so this is a warning.
check_real_bins() {
  local real_dir="${HOME}/.devide/real-bins"
  [[ -d "$real_dir" ]] || return 0

  local link dangling=0
  for link in "$real_dir"/*; do
    [[ -L "$link" || -e "$link" ]] || continue
    if [[ ! -e "$link" ]]; then
      warn "dangling real-bin symlink: $(basename "$link") → $(readlink "$link" 2>/dev/null || echo '?') (re-run scripts/install-agent-shims.sh)"
      dangling=1
    fi
  done

  if [[ "$dangling" -eq 0 ]]; then
    pass "real-bins symlinks resolve"
  fi
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
  local credential=""

  if [[ -n "$workspace" ]]; then
    expected="$(bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --dir "$workspace" "$runtime" 2>/dev/null || true)"
    if [[ -n "$expected" ]]; then
      credential="$(agent_auth_profile_credential_file "$expected" "$runtime" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$value" ]]; then
    if [[ -n "$credential" && -f "$credential" ]]; then
      warn "${runtime} owner profile is signed in but ${var} is not active — run repair-tmux-env.sh or relaunch the agent"
    else
      pass "${runtime} uses global auth (no signed-in owner profile)"
    fi
    return
  fi

  if [[ -n "$expected" && "$value" == "$expected" ]]; then
    pass "${runtime} uses DevIDE owner auth profile"
    if [[ -n "$credential" && -f "$credential" ]]; then
      pass "${runtime} profile credentials present"
    else
      warn "${runtime} profile is active but not signed in — next launch falls back to global auth (run devide agent auth signin ${runtime})"
    fi
  elif agent_auth_profile_under_root "$value"; then
    fail "${var} points at the wrong DevIDE auth profile (${value}; expected ${expected:-unknown})"
  else
    fail "${var} points at a non-DevIDE provider home (${value}) — repair or relaunch before using this pane"
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
  local artifact_url="${DEVIDE_ARTIFACT_MCP_URL:-}"

  if [[ -z "$token" || -z "$terminal_url" || -z "$preview_url" || -z "$artifact_url" ]]; then
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

  status="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
    "$artifact_url" 2>/dev/null || echo 000)"

  if [[ "$status" == "200" ]]; then
    pass "artifact MCP initialize → 200"
  else
    fail "artifact MCP initialize → ${status}"
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

  local slug terminal_key preview_key artifact_key
  slug="$(
    DEVIDE_WORKSPACE_NAME="$workspace_name" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ['DEVIDE_WORKSPACE_NAME']).strip('-').lower()
print(slug or 'workspace')
"
  )"
  terminal_key="devide-terminal-${slug}"
  preview_key="devide-preview-${slug}"
  artifact_key="devide-artifact-${slug}"

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

  if ! grep -q "\\[mcp_servers\\.${artifact_key}\\]" "$grok_config" 2>/dev/null; then
    warn "grok config missing ${artifact_key}"
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
  check_shim_targets
  check_real_bins
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
