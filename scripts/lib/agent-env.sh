#!/usr/bin/env bash
# Shared Casein agent env resolution — sourced by casein CLI and launch scripts.
# Resolution order (first match wins):
#   1. CASEIN_API_TOKEN + CASEIN_WORKSPACE_ID already exported
#   2. CASEIN_AGENT_ENV_FILE (explicit env.sh path)
#   3. Walk up from cwd for .devbox-agent.env
#   4. tmux show-environment (Casein pane injection)
#   5. tmux session name → ~/.casein/agent-mcp/<workspace>/env.sh
#   6. Host /etc/casein/casein.env + workspace API lookup from tmux session name

agent_env_load_file() {
  local file="$1"
  export CASEIN_AGENT_BOOTSTRAP_FILE="$(realpath -m "$file")"
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

# A tmux server bakes its socket path into the $TMUX every pane inherits, and
# never revisits it. Rename or replace that socket file underneath a live
# server — the devide → casein cutover did exactly that — and each pane keeps
# pointing at a path with no server behind it, so every plain `tmux` call from
# inside a perfectly healthy pane fails "no server running". The pane itself is
# fine; only the inherited path is wrong. Find the live socket that actually
# owns this pane and rewrite $TMUX so tmux works again for this process and
# everything it spawns (agent hooks, repair-tmux-env.sh, the agent's own CLI).
agent_env_tmux_probe_socket() {
  local socket="$1" name
  local -a args=()
  [[ -n "$socket" ]] && args=(-S "$socket")

  if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    name="$(tmux "${args[@]}" display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" ||
      return 1
  else
    name="$(tmux "${args[@]}" display-message -p '#{session_name}' 2>/dev/null)" || return 1
  fi

  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

agent_env_tmux_adopt_socket() {
  local socket="$1" pid session_id

  pid="$(tmux -S "$socket" display-message -p '#{pid}' 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1

  if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    session_id="$(tmux -S "$socket" display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null)" ||
      return 1
  else
    session_id="$(tmux -S "$socket" display-message -p '#{session_id}' 2>/dev/null)" || return 1
  fi

  export TMUX="${socket},${pid},${session_id#\$}"
}

agent_env_ensure_tmux_socket() {
  [[ -n "${TMUX:-}" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1

  # Memoized: the scan probes every socket in the directory, and callers below
  # ask for the session name repeatedly during a single launch.
  if [[ -n "${CASEIN_TMUX_SOCKET_RESOLVED:-}" ]]; then
    [[ "$CASEIN_TMUX_SOCKET_RESOLVED" == "ok" ]]
    return
  fi
  export CASEIN_TMUX_SOCKET_RESOLVED=failed

  # Fast path: the inherited socket still answers for this pane.
  if agent_env_tmux_probe_socket "" >/dev/null; then
    export CASEIN_TMUX_SOCKET_RESOLVED=ok
    return 0
  fi

  # Look for the renamed socket only as a sibling of the dead one, and only
  # inside the canonical per-user tmux socket directory. Widening the search
  # buys nothing real — a server cannot be renamed into another directory —
  # and costs a lot: a $TMUX pointing anywhere else (a hermetic test's fake
  # path, a bespoke -S socket) would otherwise sweep the host's live servers.
  local dir socket name
  dir="$(dirname -- "${TMUX%%,*}")"
  [[ "$dir" == "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" && -d "$dir" ]] || return 1

  # A pane id is unique per server but not across servers, so resolving %N is
  # not proof of identity. Adopt only a server that also agrees on the paired
  # session name; with no name to check against, decline rather than guess.
  [[ -n "${CASEIN_TMUX_SESSION:-}" ]] || return 1

  # Named socket first so the common case never depends on scan order.
  for socket in "${CASEIN_TMUX_SOCKET:-}" "${dir}/casein" "$dir"/*; do
    [[ -n "$socket" && -S "$socket" ]] || continue
    name="$(agent_env_tmux_probe_socket "$socket")" || continue
    [[ "$name" == "${CASEIN_TMUX_SESSION}" ]] || continue

    if agent_env_tmux_adopt_socket "$socket"; then
      echo "casein: repaired stale \$TMUX socket -> ${socket} (session ${name})" >&2
      export CASEIN_TMUX_SOCKET_RESOLVED=ok
      return 0
    fi
  done

  return 1
}

agent_env_tmux_session_id() {
  agent_env_ensure_tmux_socket || return 1
  if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null || true
  else
    tmux display-message -p '#{session_id}' 2>/dev/null || true
  fi
}

agent_env_tmux_session_name() {
  agent_env_ensure_tmux_socket || return 1
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
  # Not inside the command substitution below: the helpers repair $TMUX by
  # exporting it, and an export made in a subshell dies with the subshell.
  agent_env_ensure_tmux_socket || true
  session_name="$(agent_env_tmux_session_name)" || return 1
  workspace_id="${CASEIN_WORKSPACE_ID:-}"

  [[ -n "$session_name" && -n "$workspace_id" ]] || return 1

  for key in CASEIN_TERMINAL_MCP_URL CASEIN_PREVIEW_MCP_URL; do
    url="${!key:-}"
    [[ -n "$url" ]] || return 1

    bound="$(
      MCP_URL="$url" CASEIN_WORKSPACE_ID="$workspace_id" \
        CASEIN_TMUX_SESSION="$session_name" python3 - <<'PY'
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
    ("workspace_id", os.environ["CASEIN_WORKSPACE_ID"]),
    ("tmux_session", os.environ["CASEIN_TMUX_SESSION"]),
])
print(urlunsplit((url.scheme, url.netloc, url.path, urlencode(query), url.fragment)))
PY
    )" || return 1

    printf -v "$key" '%s' "$bound"
    export "$key"
  done

  export CASEIN_TMUX_SESSION="$session_name"
}

# Prefer the repository the operator actually launched from over a checkout
# path inherited from the tmux session. Session env is shared and can lag (or
# be changed by another pane) while a pane's cwd remains the local authority.
agent_env_bind_current_checkout() {
  local checkout
  checkout="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  export CASEIN_CHECKOUT="$(realpath -m "$checkout")"
}

agent_env_parse_workspace_name() {
  local session_name="$1"
  if [[ "$session_name" =~ ^casein_([^_]+)_ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

agent_env_staging_env_file() {
  local workspace_name="$1"
  printf '%s\n' "${HOME}/.casein/agent-mcp/${workspace_name}/env.sh"
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
      CASEIN_API_TOKEN|CASEIN_WORKSPACE_ID|CASEIN_WORKSPACE_NAME|CASEIN_TMUX_SESSION|CASEIN_API_BASE_URL|CASEIN_TERMINAL_MCP_URL|CASEIN_PREVIEW_MCP_URL|CASEIN_ARTIFACT_MCP_URL|CASEIN_TIDEWAVE_MCP_URL|CASEIN_PREVIEW_ENV_ID|CASEIN_CHECKOUT|CASEIN_AGENT_MCP_HOME|CASEIN_SCRIPTS|CASEIN_AGENT_ENV_FILE|CASEIN_TERMINAL_SCHEME|CASEIN_TERMINAL_PRESET|COLORFGBG|CLAUDE_CONFIG_DIR|CODEX_HOME|PATH)
        if [[ -z "${!key:-}" ]]; then
          export "${key}=${value}"
        fi
        ;;
    esac
  done < <(tmux show-environment -t "$session_id" 2>/dev/null || true)

  [[ -n "${CASEIN_API_TOKEN:-}" && -n "${CASEIN_WORKSPACE_ID:-}" ]]
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

agent_env_load_host_casein_env() {
  local host_env="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
  if [[ ! -r "$host_env" ]]; then
    return 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$host_env"
  set +a
  export CASEIN_URL="${CASEIN_URL:-http://127.0.0.1:4000}"
  [[ -n "${CASEIN_API_TOKEN:-}" ]]
}

agent_env_default_checkout() {
  local workspace_name="$1"

  case "$workspace_name" in
    dalexandre-casein | casein)
      printf '%s\n' "/data/workspaces/dalexandre/casein"
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
  local base_url="${CASEIN_URL:-http://127.0.0.1:4000}"
  local token="${CASEIN_API_TOKEN:-}"

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
      export CASEIN_TMUX_SESSION="$tmux_session"
    fi

    export CASEIN_WORKSPACE_ID="$workspace_id"
    export CASEIN_WORKSPACE_NAME="$workspace_name"
    export CASEIN_CHECKOUT="$(agent_env_default_checkout "$workspace_name")"
    export CASEIN_API_BASE_URL="${CASEIN_API_BASE_URL:-$base_url}"
    export CASEIN_TERMINAL_MCP_URL="${base_url}/api/terminals/mcp?${query_suffix}"
    export CASEIN_PREVIEW_MCP_URL="${base_url}/api/preview/mcp?${query_suffix}"
    export CASEIN_ARTIFACT_MCP_URL="${base_url}/api/artifacts/mcp?workspace_id=${workspace_id}"
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

  export CASEIN_WORKSPACE_NAME="$workspace_name"

  if agent_env_load_host_casein_env && agent_env_resolve_workspace_id_from_api "$workspace_name"; then
    return 0
  fi

  return 1
}

agent_env_resolve() {
  # Repair here, in the caller's shell, so the corrected $TMUX is exported for
  # everything the launch spawns — tmux state hooks, repair-tmux-env.sh, and
  # the agent CLI itself all shell out to a bare `tmux`.
  agent_env_ensure_tmux_socket || true

  if [[ -n "${CASEIN_API_TOKEN:-}" ]] && [[ -n "${CASEIN_WORKSPACE_ID:-}" ]]; then
    return 0
  fi

  if [[ -n "${CASEIN_AGENT_ENV_FILE:-}" && -f "${CASEIN_AGENT_ENV_FILE}" ]]; then
    agent_env_load_file "${CASEIN_AGENT_ENV_FILE}"
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

  echo "error: could not resolve Casein agent env (run inside a Casein tmux pane or source .devbox-agent.env)" >&2
  return 1
}

# Record pairing state on the tmux pane (@casein_paired / @casein_paired_reason)
# so the viewer can badge unpaired agent panes without any terminal output.
# Best-effort: plain terminals (no $TMUX / $TMUX_PANE) skip silently, and a
# failing tmux never blocks the launch.
agent_env_stamp_pane_pairing() {
  local paired="$1" reason="${2:-}"
  [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  # Best-effort, as before: a socket that cannot be repaired is not a reason to
  # skip the stamp — the inherited $TMUX may still be the live one.
  agent_env_ensure_tmux_socket || true
  tmux set-option -p -t "$TMUX_PANE" @casein_paired "$paired" 2>/dev/null || true
  tmux set-option -p -t "$TMUX_PANE" @casein_paired_reason "$reason" 2>/dev/null || true
}

agent_env_export_runtime_paths() {
  # Deliberately not requiring CASEIN_AGENT_MCP_HOME: a degraded launch (MCP
  # materialization failed) must still put the launcher shims and the real
  # agent binaries on PATH. The npm prefix rides along so `codex update`
  # installs stay reachable; ~/.local/bin covers user-installed real bins.
  export CASEIN_NPM_PREFIX="${CASEIN_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
  export PATH="${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}:${CASEIN_NPM_PREFIX}/bin:${HOME}/.local/bin:${PATH:-/usr/bin:/bin}"
}
