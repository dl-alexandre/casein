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
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"

PASS=0
WARN=0
FAIL=0

pass() { printf 'OK   %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARN %s\n' "$*" >&2; WARN=$((WARN + 1)); }
fail() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

devide_shims_expected() {
  # Agent processes launched through launch-devide-agent.sh carry one of these
  # markers. The worktree marker covers the normal path; the explicit launch
  # marker covers deliberate DEVIDE_AGENT_SKIP_WORKTREE launches.
  if [[ -n "${DEVIDE_AGENT_LAUNCH_CONTEXT:-}" || "${DEVIDE_WORKTREE:-0}" == "1" ]]; then
    return 0
  fi

  # A plain shell may source the workspace env file while intentionally keeping
  # launcher shims off PATH. Only classify tmux as paired when the live session
  # itself is a DevIDE session.
  if [[ -n "${TMUX:-}" ]]; then
    local session
    session="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    [[ -n "$session" ]] || session="${DEVIDE_TMUX_SESSION:-}"
    [[ "$session" == devide_* ]]
    return
  fi

  return 1
}

check_shims() {
  local shim_dir="${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}"
  local runtime bin resolved bin_target resolved_target missing_runtimes=()
  local shims_expected=0
  if devide_shims_expected; then
    shims_expected=1
  fi

  for runtime in grok claude codex opencode agent devide; do
    bin="${shim_dir}/${runtime}"
    if [[ ! -x "$bin" ]]; then
      missing_runtimes+=("$runtime")
    fi
  done

  # Partial missing sets (claude gone, grok present) have bitten operators after
  # deploys/npm updates — self-heal once, then hard-fail if still incomplete.
  if [[ "${#missing_runtimes[@]}" -gt 0 ]]; then
    warn "shim(s) missing: ${missing_runtimes[*]} — reinstalling via install-agent-shims.sh"
    if bash "${ROOT}/scripts/install-agent-shims.sh" >/dev/null 2>&1; then
      pass "reinstalled agent shims after detecting missing: ${missing_runtimes[*]}"
    else
      fail "could not reinstall agent shims (missing: ${missing_runtimes[*]})"
    fi
  fi

  for runtime in grok claude codex opencode agent devide; do
    bin="${shim_dir}/${runtime}"
    if [[ ! -x "$bin" ]]; then
      fail "shim missing: ${runtime} (run scripts/install-agent-shims.sh)"
      continue
    fi
    pass "shim installed: ${runtime}"

    # An installed shim that loses PATH resolution is worse than a missing
    # one: agents launch fine but silently skip MCP injection. The shim dir
    # is only injected inside DevIDE contexts — outside them, real binaries
    # winning is the intended zero-footprint behavior.
    resolved="$(command -v "$runtime" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      if [[ "$shims_expected" == "1" ]]; then
        fail "shim unreachable in paired context: ${runtime} not on PATH (run repair-tmux-env.sh or open a fresh DevIDE pane)"
      else
        pass "plain-shell isolation: ${runtime} launcher shim is not on PATH"
      fi
      continue
    fi
    bin_target="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
    resolved_target="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    if [[ "$resolved_target" == "$bin_target" ]]; then
      pass "shim wins PATH resolution: ${runtime}"
    elif [[ "$shims_expected" == "0" ]]; then
      pass "plain-shell isolation: ${runtime} resolves outside DevIDE shims (${resolved})"
    else
      fail "shim shadowed: ${runtime} resolves to ${resolved} — MCP injection will not run (put ${shim_dir} first on PATH; repair-tmux-env.sh does this)"
    fi
  done

  # Pane PATH must include both launcher shims and the npm package bin dir so
  # a missing shim still surfaces a real binary error rather than "not found"
  # from a release-only PATH — and so reinstall finds package candidates.
  local npm_prefix npm_bin
  npm_prefix="${CASEIN_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
  npm_bin="${npm_prefix}/bin"
  case ":${PATH:-}:" in
    *":${shim_dir}:"*) pass "PATH includes ${shim_dir}" ;;
    *)
      if [[ "$shims_expected" == "1" ]]; then
        fail "paired-context PATH missing ${shim_dir} — run repair-tmux-env.sh or relaunch the agent"
      else
        pass "plain-shell PATH intentionally excludes ${shim_dir}"
      fi
      ;;
  esac
  case ":${PATH:-}:" in
    *":${npm_bin}:"*) pass "PATH includes npm agent bin (${npm_bin})" ;;
    *)
      if [[ "$shims_expected" == "1" ]]; then
        warn "paired-context PATH missing ${npm_bin} — set CASEIN_NPM_PREFIX / repair-tmux-env"
      else
        pass "plain-shell PATH does not require npm agent bin (${npm_bin})"
      fi
      ;;
  esac
}

# Each shim embeds the absolute path of scripts/devide at install time; if the
# checkout moves or a deploy worktree is cleaned up, every agent command dies
# at once. The sed pattern must match the install-agent-shims.sh template
# (pinned by scripts/test-agent-shims.sh).
check_shim_targets() {
  local shim_dir="${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}"
  local runtime shim cli target_missing=0 checked=0
  for runtime in grok claude codex opencode agent; do
    shim="${shim_dir}/${runtime}"
    [[ -f "$shim" ]] || continue
    cli="$(sed -n 's/^exec "\(.*\)" agent launch .*/\1/p' "$shim" | head -n 1)"
    [[ -n "$cli" ]] || continue
    checked=$((checked + 1))
    if [[ ! -x "$cli" ]]; then
      fail "shim target missing: ${runtime} → ${cli} (checkout moved? re-run scripts/install-agent-shims.sh)"
      target_missing=1
    fi
  done

  if [[ "$checked" -gt 0 && "$target_missing" -eq 0 ]]; then
    pass "shim targets executable (embedded devide CLI paths resolve)"
  fi
}

# Self-updating agents (grok records a versioned binary path) can strand the
# recorded symlink; launch falls back to a PATH search, so this is a warning.
check_real_bins() {
  local real_dir="${HOME}/.casein/real-bins"
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
  local token="${CASEIN_API_TOKEN:-}"
  if [[ -z "$token" ]]; then
    fail "CASEIN_API_TOKEN is not set"
    return
  fi

  if [[ "$token" == \'*\' || "$token" == \"*\" ]]; then
    fail "CASEIN_API_TOKEN has literal shell quotes — run repair-tmux-env.sh"
  else
    pass "CASEIN_API_TOKEN is set (unquoted)"
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
  local token="${CASEIN_API_TOKEN:-}"
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

grok_inspect_rows() {
  local inspect_file="$1"
  shift

  EXPECTED_CWD="${PWD}" \
    EXPECTED_WORKSPACE_ID="${DEVIDE_WORKSPACE_ID:-}" \
    python3 - "$inspect_file" "$@" <<'PY'
import json
import os
import re
import sys
from urllib.parse import parse_qs, urlsplit

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

if not isinstance(report, dict):
    raise SystemExit(1)

version = report.get("grokVersion")
if not isinstance(version, str) or not re.fullmatch(r"[0-9A-Za-z._+\-]{1,64}", version):
    version = "unknown"
print(f"META\tversion\t{version}")

reported_cwd = report.get("cwd")
expected_cwd = os.path.realpath(os.environ["EXPECTED_CWD"])
cwd_status = "ok" if isinstance(reported_cwd, str) and os.path.realpath(reported_cwd) == expected_cwd else "mismatch"
print(f"META\tcwd\t{cwd_status}")

servers = report.get("mcpServers")
if servers is None:
    servers = []
elif not isinstance(servers, list):
    raise SystemExit(1)

workspace_id = os.environ["EXPECTED_WORKSPACE_ID"]

def workspace_matches(server):
    target = server.get("target")
    if not isinstance(target, str) or not workspace_id:
        return False
    try:
        return workspace_id in parse_qs(urlsplit(target).query).get("workspace_id", [])
    except ValueError:
        return False

for expected_name in sys.argv[2:]:
    candidates = [server for server in servers if isinstance(server, dict) and server.get("name") == expected_name]
    if not candidates:
        status = "missing"
    elif any(workspace_matches(server) for server in candidates):
        status = "ok"
    else:
        status = "wrong-workspace"
    print(f"SERVER\t{expected_name}\t{status}")
PY
}

grok_bundle_contract() {
  local managed="$1"
  local bundle="${DEVIDE_GROK_BUNDLE_DIR:-}"
  local digest="${DEVIDE_GROK_BUNDLE_DIGEST:-}"

  if [[ -z "$bundle" && -z "$digest" ]]; then
    if [[ "$managed" == "1" ]]; then
      fail "Grok managed launch is missing DEVIDE_GROK_BUNDLE_DIR and DEVIDE_GROK_BUNDLE_DIGEST"
    else
      warn "no session-scoped Grok capability bundle is active in this shell"
    fi
    return 1
  fi

  if [[ -z "$bundle" || -z "$digest" ]]; then
    fail "Grok capability bundle metadata is incomplete"
    return 1
  fi

  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    fail "Grok capability bundle digest is not 64 lowercase hexadecimal characters"
    return 1
  fi

  local bundle_real bundle_root bundle_root_real
  bundle_real="$(realpath -m "$bundle")"
  bundle_root="${DEVIDE_GROK_BUNDLE_ROOT:-${HOME}/.casein/grok-bundles}"
  bundle_root_real="$(realpath -m "$bundle_root")"

  if [[ "$(dirname "$bundle_real")" != "$bundle_root_real" ]] ||
     [[ "$(basename "$bundle_real")" != "sha256-${digest}" ]]; then
    fail "Grok capability bundle is outside its content-addressed bundle root"
    return 1
  fi

  if [[ ! -f "${bundle_real}/plugin.json" ||
        ! -f "${bundle_real}/.mcp.json" ||
        ! -f "${bundle_real}/hooks/hooks.json" ||
        ! -d "${bundle_real}/skills" ]]; then
    fail "Grok capability bundle is missing its plugin, MCP, hooks, or skills contract"
    return 1
  fi

  local hooks_mode
  if ! hooks_mode="$(python3 - "$bundle_real" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
try:
    plugin = json.loads((root / "plugin.json").read_text(encoding="utf-8"))
    mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
    hooks = json.loads((root / "hooks" / "hooks.json").read_text(encoding="utf-8"))
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

if not isinstance(plugin, dict) or not isinstance(mcp, dict) or not isinstance(hooks, dict):
    raise SystemExit(1)
if plugin.get("mcpServers") != "./.mcp.json" or plugin.get("hooks") != "./hooks/hooks.json" or plugin.get("skills") != "./skills":
    raise SystemExit(1)
hook_map = hooks.get("hooks")
if not isinstance(hook_map, dict):
    raise SystemExit(1)
print("enabled" if hook_map else "disabled")
PY
  )"; then
    fail "Grok capability bundle metadata is not valid JSON or has an unexpected manifest"
    return 1
  fi

  if [[ "$hooks_mode" == "enabled" && ! -x "${bundle_real}/hooks/devide-agent-state.sh" ]]; then
    fail "Grok capability bundle enables hooks without its executable state reporter"
    return 1
  fi

  if ! python3 "${ROOT}/scripts/lib/grok-capability-bundle.py" verify \
      "$bundle_real" --digest "$digest" >/dev/null 2>&1; then
    fail "Grok capability bundle failed immutable digest verification"
    return 1
  fi

  pass "Grok capability bundle verified (digest sha256-${digest})"
  return 0
}

grok_leader_contract() {
  local managed="$1"
  local _grok_bin="$2"
  local socket="${DEVIDE_GROK_LEADER_SOCKET:-}"
  local leader_root="${DEVIDE_GROK_LEADER_ROOT:-${HOME}/.casein/grok-leaders}"

  if [[ -z "$socket" ]]; then
    if [[ "$managed" == "1" ]]; then
      fail "Grok managed launch is missing DEVIDE_GROK_LEADER_SOCKET"
    else
      warn "no private Grok leader socket is active in this shell"
    fi
    return 1
  fi

  local socket_real leader_root_real
  socket_real="$(realpath -m "$socket")"
  leader_root_real="$(realpath -m "$leader_root")"

  if [[ "$(dirname "$socket_real")" != "$leader_root_real" ]] ||
     [[ "$(basename "$socket_real")" != "leader.sock" ]] ||
     [[ ! "$(basename "$leader_root_real")" =~ ^[0-9a-f]{24}$ ]] ||
     [[ "${#socket_real}" -gt 100 ]]; then
    fail "Grok leader socket is outside the private leader root or has an invalid name"
    return 1
  fi

  if ! python3 - "$leader_root_real" "$socket_real" <<'PY' >/dev/null 2>&1
import os
import stat
import sys

root, socket_path = sys.argv[1:]
root_stat = os.stat(root, follow_symlinks=False)
socket_stat = os.stat(socket_path, follow_symlinks=False)
if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.getuid() or root_stat.st_mode & 0o077:
    raise SystemExit(1)
if not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_uid != os.getuid():
    raise SystemExit(1)
PY
  then
    if [[ "$managed" == "1" ]]; then
      fail "Grok managed launch private leader socket is absent or not owner-isolated"
    else
      warn "Grok private leader socket is not currently active"
    fi
    return 1
  fi

  local leader_pid timeout_seconds="${DEVIDE_GROK_DOCTOR_TIMEOUT_SECONDS:-15}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=15
  if leader_pid="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity \
      "${leader_root_real}/.devide-launcher" 2>/dev/null)" &&
     python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" probe \
       "$socket_real" "$leader_pid" "$timeout_seconds" >/dev/null 2>&1; then
    pass "Grok private leader socket is active and healthy"
    return 0
  fi

  if [[ "$managed" == "1" ]]; then
    fail "Grok private leader probe failed (details redacted)"
  else
    warn "Grok private leader probe failed (details redacted)"
  fi
  return 1
}

check_grok_runtime() {
  local workspace_name="${DEVIDE_WORKSPACE_NAME:-}"
  local workspace_id="${DEVIDE_WORKSPACE_ID:-}"
  local managed=0
  [[ "${DEVIDE_AGENT_LAUNCH_CONTEXT:-}" == "grok" ]] && managed=1

  grok_bundle_contract "$managed" || true

  local grok_bin
  grok_bin="$(real_agent_bin grok 2>/dev/null || true)"
  if [[ -z "$grok_bin" || ! -x "$grok_bin" ]]; then
    fail "Grok runtime discovery unavailable: real Grok executable not found"
    return 0
  fi

  grok_leader_contract "$managed" "$grok_bin" || true

  if [[ "$managed" == "1" ]]; then
    case "${DEVIDE_GROK_PROVIDER_AUTH_MODE:-unknown}" in
      api-key)
        pass "Grok managed provider auth is durable (dedicated API key)"
        ;;
      oauth-inline-refresh)
        pass "Grok managed provider auth is isolated refreshable OAuth (in-memory renewal)"
        ;;
      *)
        warn "Grok managed provider auth mode is unknown; relaunch through the DevIDE Grok shim"
        ;;
    esac
  fi

  if ! "$grok_bin" inspect --help 2>/dev/null | grep -q -- '--json'; then
    warn "installed Grok does not support 'grok inspect --json'; update Grok to diagnose resolved launch configuration"
    return 0
  fi

  local expected_servers=()
  if [[ -n "$workspace_name" && -n "$workspace_id" ]]; then
    local slug
    slug="$(
      DEVIDE_WORKSPACE_NAME="$workspace_name" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ['DEVIDE_WORKSPACE_NAME']).strip('-').lower()
print(slug or 'workspace')
"
    )"
    expected_servers=(
      "devide-terminal-${slug}"
      "devide-preview-${slug}"
      "devide-artifact-${slug}"
    )
  else
    warn "Grok MCP scope diagnostics skipped because workspace pairing env is incomplete"
  fi

  local inspect_out inspect_rows
  inspect_out="$(mktemp)"
  if ! "$grok_bin" inspect --json >"$inspect_out" 2>/dev/null; then
    rm -f "$inspect_out"
    fail "Grok could not inspect the resolved configuration for ${PWD} (details redacted; run 'grok inspect --json' directly)"
    return 0
  fi

  if ! inspect_rows="$(grok_inspect_rows "$inspect_out" "${expected_servers[@]}")"; then
    rm -f "$inspect_out"
    fail "Grok inspect returned unrecognized JSON (raw output redacted)"
    return 0
  fi
  rm -f "$inspect_out"

  local kind name status missing_count=0
  local discovered=()
  while IFS=$'\t' read -r kind name status; do
    case "${kind}:${name}:${status}" in
      META:version:*) pass "Grok inspect resolved version ${status}" ;;
      META:cwd:ok) pass "Grok inspect used paired launch cwd ${PWD}" ;;
      META:cwd:*) fail "Grok inspect did not use the requested launch cwd ${PWD}" ;;
      SERVER:*:ok)
        pass "Grok inspect discovered ${name} with matching workspace scope"
        discovered+=("$name")
        ;;
      SERVER:*:missing)
        missing_count=$((missing_count + 1))
        ;;
      SERVER:*:wrong-workspace)
        fail "Grok discovered ${name}, but its target is scoped to a different workspace"
        ;;
    esac
  done <<<"$inspect_rows"

  if [[ "$missing_count" -gt 0 ]]; then
    warn "standalone Grok inspect does not expose ${missing_count} session-scoped DevIDE MCP server(s); ACP pluginDirs and the verified bundle are authoritative"
  fi

  [[ "${#expected_servers[@]}" -gt 0 ]] || return 0
  if ! "$grok_bin" mcp doctor --help 2>/dev/null | grep -q -- '--json'; then
    warn "installed Grok does not support 'grok mcp doctor --json'; MCP servers were not live-probed"
    return 0
  fi

  local timeout_seconds="${DEVIDE_GROK_DOCTOR_TIMEOUT_SECONDS:-15}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=15

  local server command_status
  local unresolved=()
  for server in "${expected_servers[@]}"; do
    command_status=0
    if command -v timeout >/dev/null 2>&1; then
      timeout "${timeout_seconds}s" "$grok_bin" mcp doctor --json "$server" >/dev/null 2>&1 || command_status=$?
    else
      "$grok_bin" mcp doctor --json "$server" >/dev/null 2>&1 || command_status=$?
    fi

    if [[ "$command_status" == "0" ]]; then
      pass "Grok MCP handshake healthy: ${server}"
    else
      unresolved+=("$server")
    fi
  done

  if [[ "${#unresolved[@]}" -gt 0 ]]; then
    warn "standalone Grok MCP doctor could not resolve session-scoped server(s): ${unresolved[*]} (details redacted; direct MCP checks remain authoritative)"
  fi
}

check_auth_files() {
  [[ -f "${HOME}/.grok/auth.json" ]] && pass "grok auth.json present" || warn "grok auth.json missing"

  local codex_auth="${CODEX_HOME:-${HOME}/.codex}/auth.json"
  [[ -f "$codex_auth" ]] && pass "codex auth.json present" || warn "codex auth.json missing (${codex_auth})"

  local claude_auth="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
  [[ -f "$claude_auth" ]] && pass "claude credentials present" || warn "claude credentials missing (${claude_auth})"
}

check_codex_capabilities() {
  local codex_bin version help schema_dir schema_hash hook_script
  codex_bin="$(real_agent_bin codex)"

  if [[ -z "$codex_bin" || ! -x "$codex_bin" ]]; then
    fail "Codex executable not found"
    return
  fi

  version="$($codex_bin --version 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    pass "Codex version: ${version}"
  else
    fail "Codex version probe failed"
  fi

  help="$($codex_bin exec --help 2>/dev/null || true)"
  if [[ "$help" == *"--json"* && "$help" == *"--output-schema"* ]]; then
    pass "codex exec supports JSONL and structured output"
  else
    fail "codex exec is missing --json or --output-schema"
  fi

  help="$($codex_bin app-server --help 2>/dev/null || true)"
  if [[ "$help" == *"generate-json-schema"* ]]; then
    pass "codex app-server and schema generation available"
  else
    fail "codex app-server schema generation unavailable"
  fi

  schema_dir="$(mktemp -d)"
  if "$codex_bin" app-server generate-json-schema --out "$schema_dir" >/dev/null 2>&1; then
    schema_hash="$({ find "$schema_dir" -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum | awk '{print $1}')"
    pass "app-server schema hash: ${schema_hash}"
  else
    fail "app-server schema generation failed"
  fi
  rm -rf "$schema_dir"

  if "$codex_bin" \
      -c 'hooks.SessionStart=[{matcher="*",hooks=[{type="command",command="/bin/true",timeout=1}]}]' \
      features list >/dev/null 2>&1; then
    pass "Codex lifecycle hook config accepted"
  else
    fail "Codex lifecycle hook config rejected"
  fi

  if "$codex_bin" plugin --help >/dev/null 2>&1; then
    pass "Codex plugin commands available"
  else
    warn "Codex plugin commands unavailable"
  fi

  hook_script="${DEVIDE_AGENT_MCP_HOME:-${DEVIDE_SCRIPTS:-${ROOT}/scripts}}/devide-codex-notify.sh"
  if [[ -x "$hook_script" ]]; then
    pass "DevIDE Codex hook receiver staged"
  else
    warn "DevIDE Codex hook receiver missing (${hook_script})"
  fi

  if command -v bwrap >/dev/null 2>&1 && bwrap --dev-bind / / --unshare-net true >/dev/null 2>&1; then
    pass "Codex Linux sandbox can create an isolated namespace"
  elif [[ "$(uname -s)" == "Linux" ]]; then
    warn "Codex Linux sandbox probe failed (run ensure-devbox-codex-sandbox.sh)"
  else
    pass "Linux bubblewrap sandbox probe not applicable"
  fi
}

main() {
  local target="${1:-all}"
  echo "==> DevIDE agent doctor${target:+ (${target})}"

  if agent_env_resolve 2>/dev/null; then
    pass "agent env resolved"
  else
    warn "agent env not fully resolved (continuing with partial checks)"
  fi

  case "$target" in
    codex)
      check_token
      check_mcp_endpoints
      check_codex_capabilities
      ;;
    all|"")
      check_shims
      check_shim_targets
      check_real_bins
      check_token
      check_bad_redirects
      check_mcp_endpoints
      check_tidewave_mcp
      check_grok_runtime
      check_auth_files
      check_codex_capabilities
      ;;
    *)
      fail "unknown doctor target: ${target} (expected codex or all)"
      ;;
  esac

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
