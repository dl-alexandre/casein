#!/usr/bin/env bash
# Shared DevIDE agent env resolution — sourced by devide CLI and launch scripts.
# Resolution order (first match wins):
#   1. DEV_IDE_API_TOKEN + DEVIDE_WORKSPACE_ID already exported
#   2. DEVIDE_AGENT_ENV_FILE (explicit env.sh path)
#   3. Walk up from cwd for .devbox-agent.env
#   4. tmux show-environment (DevIDE pane injection)
#   5. tmux session name → ~/.devide/agent-mcp/<workspace>/env.sh
#   6. Host /etc/devide/devide.env + workspace API lookup from tmux session name

agent_env_load_file() {
  local file="$1"
  export DEVIDE_AGENT_BOOTSTRAP_FILE="$(realpath -m "$file")"
  # shellcheck source=/dev/null
  source "$file"
}

agent_env_find_devbox_file() {
  local dir="${PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/.devbox-agent.env" ]]; then
      printf '%s\n' "${dir}/.devbox-agent.env"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

agent_env_tmux_session_id() {
  if [[ -z "${TMUX:-}" ]]; then
    return 1
  fi
  if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null || true
  else
    tmux display-message -p '#{session_id}' 2>/dev/null || true
  fi
}

agent_env_tmux_session_name() {
  if [[ -z "${TMUX:-}" ]]; then
    return 1
  fi
  if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true
  else
    tmux display-message -p '#{session_name}' 2>/dev/null || true
  fi
}

# Bind managed-runtime MCP URLs to the tmux session that is actually launching
# the agent. Exported/persisted pairing env can be older than the current pane,
# and capability bundles are immutable once materialized, so this must happen
# before bundle generation rather than during the later best-effort tmux repair.
agent_env_bind_current_tmux_session() {
  local session_name workspace_id key url bound
  session_name="$(agent_env_tmux_session_name)" || return 1
  workspace_id="${DEVIDE_WORKSPACE_ID:-}"

  [[ -n "$session_name" && -n "$workspace_id" ]] || return 1

  for key in DEVIDE_TERMINAL_MCP_URL DEVIDE_PREVIEW_MCP_URL; do
    url="${!key:-}"
    [[ -n "$url" ]] || return 1

    bound="$(
      MCP_URL="$url" DEVIDE_WORKSPACE_ID="$workspace_id" \
        DEVIDE_TMUX_SESSION="$session_name" python3 - <<'PY'
import os
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

url = urlsplit(os.environ["MCP_URL"])
if url.scheme not in {"http", "https"} or not url.netloc:
    raise SystemExit(1)

query = [
    (key, value)
    for key, value in parse_qsl(url.query, keep_blank_values=True)
    if key not in {"workspace_id", "tmux_session"}
]
query.extend([
    ("workspace_id", os.environ["DEVIDE_WORKSPACE_ID"]),
    ("tmux_session", os.environ["DEVIDE_TMUX_SESSION"]),
])
print(urlunsplit((url.scheme, url.netloc, url.path, urlencode(query), url.fragment)))
PY
    )" || return 1

    printf -v "$key" '%s' "$bound"
    export "$key"
  done

  export DEVIDE_TMUX_SESSION="$session_name"
}

# Prefer the repository the operator actually launched from over a checkout
# path inherited from the tmux session. Session env is shared and can lag (or
# be changed by another pane) while a pane's cwd remains the local authority.
agent_env_bind_current_checkout() {
  local checkout
  checkout="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  export DEVIDE_CHECKOUT="$(realpath -m "$checkout")"
}

agent_env_parse_workspace_name() {
  local session_name="$1"
  if [[ "$session_name" =~ ^devide_([^_]+)_ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

agent_env_staging_env_file() {
  local workspace_name="$1"
  printf '%s\n' "${HOME}/.devide/agent-mcp/${workspace_name}/env.sh"
}

agent_env_load_tmux_session_env() {
  local session_id
  session_id="$(agent_env_tmux_session_id)" || return 1
  [[ -n "$session_id" ]] || return 1

  local line key value
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      DEV_IDE_API_TOKEN|DEVIDE_WORKSPACE_ID|DEVIDE_WORKSPACE_NAME|DEVIDE_TMUX_SESSION|DEVIDE_API_BASE_URL|DEVIDE_TERMINAL_MCP_URL|DEVIDE_PREVIEW_MCP_URL|DEVIDE_ARTIFACT_MCP_URL|DEVIDE_TIDEWAVE_MCP_URL|DEVIDE_PREVIEW_ENV_ID|DEVIDE_CHECKOUT|DEVIDE_AGENT_MCP_HOME|DEVIDE_SCRIPTS|DEVIDE_AGENT_ENV_FILE|DEV_IDE_TERMINAL_SCHEME|DEV_IDE_TERMINAL_PRESET|COLORFGBG|CLAUDE_CONFIG_DIR|CODEX_HOME|PATH)
        if [[ -z "${!key:-}" ]]; then
          export "${key}=${value}"
        fi
        ;;
    esac
  done < <(tmux show-environment -t "$session_id" 2>/dev/null || true)

  [[ -n "${DEV_IDE_API_TOKEN:-}" && -n "${DEVIDE_WORKSPACE_ID:-}" ]]
}

agent_env_load_staged_env() {
  local workspace_name="${1:-}"
  local env_file
  env_file="$(agent_env_staging_env_file "$workspace_name")"
  if [[ -f "$env_file" ]]; then
    agent_env_load_file "$env_file"
    return 0
  fi
  return 1
}

agent_env_load_host_devide_env() {
  local host_env="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
  if [[ ! -r "$host_env" ]]; then
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$host_env"
  set +a
  export DEVIDE_URL="${DEVIDE_URL:-http://127.0.0.1:4000}"
  [[ -n "${DEV_IDE_API_TOKEN:-}" ]]
}

agent_env_default_checkout() {
  local workspace_name="$1"

  case "$workspace_name" in
    dalexandre-devide | dev_ide)
      printf '%s\n' "/data/workspaces/dalexandre/dev_ide"
      ;;
    *)
      if [[ -d "/data/workspaces/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/${workspace_name}"
      elif [[ -d "/data/workspaces/dalexandre/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/dalexandre/${workspace_name}"
      else
        printf '%s\n' "/data/workspaces/${workspace_name}"
      fi
  esac
}

agent_env_resolve_workspace_id_from_api() {
  local workspace_name="$1"
  local base_url="${DEVIDE_URL:-http://127.0.0.1:4000}"
  local token="${DEV_IDE_API_TOKEN:-}"

  [[ -n "$token" && -n "$workspace_name" ]] || return 1

  local workspace_id
  workspace_id="$(
    curl -fsS -H "authorization: Bearer ${token}" "${base_url}/api/workspaces" 2>/dev/null |
      WORKSPACE_NAME="$workspace_name" python3 -c "
import json, os, sys
name = os.environ['WORKSPACE_NAME']
for ws in json.load(sys.stdin):
    if ws.get('name') == name or ws.get('id') == name:
        print(ws.get('id', ''))
        break
" 2>/dev/null || true
  )"

  if [[ -n "$workspace_id" ]]; then
    local tmux_session query_suffix
    tmux_session="$(agent_env_tmux_session_name 2>/dev/null || true)"
    query_suffix="workspace_id=${workspace_id}"
    if [[ -n "$tmux_session" ]]; then
      query_suffix="${query_suffix}&tmux_session=${tmux_session}"
      export DEVIDE_TMUX_SESSION="$tmux_session"
    fi

    export DEVIDE_WORKSPACE_ID="$workspace_id"
    export DEVIDE_WORKSPACE_NAME="$workspace_name"
    export DEVIDE_CHECKOUT="$(agent_env_default_checkout "$workspace_name")"
    export DEVIDE_API_BASE_URL="${DEVIDE_API_BASE_URL:-$base_url}"
    export DEVIDE_TERMINAL_MCP_URL="${base_url}/api/terminals/mcp?${query_suffix}"
    export DEVIDE_PREVIEW_MCP_URL="${base_url}/api/preview/mcp?${query_suffix}"
    export DEVIDE_ARTIFACT_MCP_URL="${base_url}/api/artifacts/mcp?workspace_id=${workspace_id}"
    return 0
  fi

  return 1
}

agent_env_resolve_from_tmux_session_name() {
  local session_name workspace_name
  session_name="$(agent_env_tmux_session_name)" || return 1
  workspace_name="$(agent_env_parse_workspace_name "$session_name")" || return 1

  if agent_env_load_staged_env "$workspace_name"; then
    return 0
  fi

  export DEVIDE_WORKSPACE_NAME="$workspace_name"

  if agent_env_load_host_devide_env && agent_env_resolve_workspace_id_from_api "$workspace_name"; then
    return 0
  fi

  return 1
}

agent_env_resolve() {
  if [[ -n "${DEV_IDE_API_TOKEN:-}" ]] && [[ -n "${DEVIDE_WORKSPACE_ID:-}" ]]; then
    return 0
  fi

  if [[ -n "${DEVIDE_AGENT_ENV_FILE:-}" && -f "${DEVIDE_AGENT_ENV_FILE}" ]]; then
    agent_env_load_file "${DEVIDE_AGENT_ENV_FILE}"
    return 0
  fi

  local env_file=""
  if env_file="$(agent_env_find_devbox_file)"; then
    agent_env_load_file "$env_file"
    return 0
  fi

  if agent_env_load_tmux_session_env; then
    return 0
  fi

  if agent_env_resolve_from_tmux_session_name; then
    return 0
  fi

  echo "error: could not resolve DevIDE agent env (run inside a DevIDE tmux pane or source .devbox-agent.env)" >&2
  return 1
}

# Record pairing state on the tmux pane (@devide_paired / @devide_paired_reason)
# so the viewer can badge unpaired agent panes without any terminal output.
# Best-effort: plain terminals (no $TMUX / $TMUX_PANE) skip silently, and a
# failing tmux never blocks the launch.
agent_env_stamp_pane_pairing() {
  local paired="$1" reason="${2:-}"
  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  tmux set-option -p -t "$TMUX_PANE" @devide_paired "$paired" 2>/dev/null || true
  tmux set-option -p -t "$TMUX_PANE" @devide_paired_reason "$reason" 2>/dev/null || true
}

agent_env_export_runtime_paths() {
  # Deliberately not requiring DEVIDE_AGENT_MCP_HOME: a degraded launch (MCP
  # materialization failed) must still put the launcher shims and the real
  # agent binaries on PATH. The npm prefix rides along so `codex update`
  # installs stay reachable; ~/.local/bin covers user-installed real bins.
  export DEV_IDE_NPM_PREFIX="${DEV_IDE_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
  export PATH="${DEV_IDE_AGENT_BIN_DIR:-${HOME}/.devide/agent-shims}:${DEV_IDE_NPM_PREFIX}/bin:${HOME}/.local/bin:${PATH:-/usr/bin:/bin}"
}
