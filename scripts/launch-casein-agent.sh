#!/usr/bin/env bash
#
# Launch an external agent with Casein Terminal + Preview MCP injected at runtime.
#
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/agent-env.sh
source "${ROOT}/scripts/lib/agent-env.sh"
# shellcheck source=lib/agent-worktree.sh
source "${ROOT}/scripts/lib/agent-worktree.sh"
# shellcheck source=lib/real-agent-bin.sh
source "${ROOT}/scripts/lib/real-agent-bin.sh"
# shellcheck source=lib/agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=lib/sidechat.sh
source "${ROOT}/scripts/lib/sidechat.sh"
# shellcheck source=lib/agent-skills.sh
source "${ROOT}/scripts/lib/agent-skills.sh"

usage() {
  cat <<'EOF'
Usage: launch-casein-agent.sh <runtime> [runtime args...]

Creates a dedicated git worktree when launched from the primary checkout (see
docs/development-workflow.md). Set CASEIN_AGENT_SKIP_WORKTREE=1 to opt out.

Runtimes:
  grok      injects an immutable capability bundle into a private leader session
  codex     injects per-workspace MCP and host skills via launch-time config;
            pass --sidechat <target> for a read-only advisor
  claude    injects per-workspace MCP via --mcp-config (keeps ~/.claude credentials)
            pass --sidechat <target> for a read-only advisor (target: %pane,
            session:pane, or agent)
  opencode  injects per-workspace MCP via project .opencode/opencode.json
            (paired primary checkout OR agent worktree) and stages host
            skills (delegate-to-worker, preview-ui-walk, workspace-agent-pair)
            into ~/.config/opencode/skills + project .opencode/skills
  agent     MCP env + real agent binary
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

RUNTIME="$1"
shift

# Child processes spawned by the managed agent can use this to distinguish a
# real Casein launch from an ordinary shell that merely sourced pairing env.
export CASEIN_AGENT_LAUNCH_CONTEXT="$RUNTIME"

agent_env_resolve

# "requires an exact current tmux session" says nothing about which of the
# three preconditions failed, and they have completely different fixes.
grok_tmux_bind_hint() {
  local key
  if [[ -z "${TMUX:-}" ]]; then
    echo "hint: no \$TMUX — run grok from a Casein tmux pane" >&2
    return 0
  fi

  if ! agent_env_ensure_tmux_socket; then
    echo "hint: \$TMUX names ${TMUX%%,*}, and no live tmux socket under" \
      "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u) owns pane ${TMUX_PANE:-<unset>}" >&2
    return 0
  fi

  for key in CASEIN_WORKSPACE_ID CASEIN_TERMINAL_MCP_URL CASEIN_PREVIEW_MCP_URL; do
    if [[ -z "${!key:-}" ]]; then
      echo "hint: ${key} is unset for this pane — re-pair it" \
        "(bash scripts/lib/repair-tmux-env.sh)" >&2
    fi
  done
}

if [[ "$RUNTIME" == "grok" ]]; then
  agent_env_bind_current_checkout
  if ! agent_env_bind_current_tmux_session; then
    echo "error: managed Grok launch requires an exact current tmux session" >&2
    grok_tmux_bind_hint
    exit 1
  fi
fi

agent_worktree_ensure "$RUNTIME" "${CASEIN_AGENT_TASK:-adhoc}"

# Token-bearing launcher scratch files live under a path every managed Grok
# sandbox denies wholesale. Same-UID mode bits alone do not isolate concurrent
# agent processes from secrets staged in the system temp directory.
CASEIN_LAUNCHER_SECRET_DIR="${HOME}/.casein/agent-mcp/.launcher-tmp"
mkdir -p "$CASEIN_LAUNCHER_SECRET_DIR"
chmod 700 "$CASEIN_LAUNCHER_SECRET_DIR"

# Anchor MCP calls to this pane: tmux sets TMUX_PANE per pane, and the
# materialized MCP configs send it as the X-Casein-Caller-Pane header
# (env-expanded by each runtime at startup). The terminal MCP server uses it
# to resolve "the agent pane" / "the pane beside me" relative to the caller
# instead of the operator-focused active pane. Always exported (possibly
# empty) so header templates never leak an unexpanded placeholder.
export CASEIN_CALLER_PANE="${TMUX_PANE:-}"

warn_degraded_step() {
  local label="$1"
  local detail="${2:-}"

  echo "warn: ${label} failed — agent continues in degraded mode" >&2
  if [[ -n "$detail" ]]; then
    printf '%s\n' "${detail:0:1200}" >&2
  fi
}

grok_debug() {
  if [[ "${CASEIN_GROK_DEBUG:-0}" == "1" ]]; then
    printf 'casein-grok-debug: %s\n' "$*" >&2
  fi
}

run_materialize_export() {
  local out err exports detail
  out="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/materialize.out.XXXXXX")"
  err="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/materialize.err.XXXXXX")"

  if bash "${ROOT}/scripts/materialize-agent-mcp.sh" --export >"$out" 2>"$err"; then
    exports="$(<"$out")"
    if [[ -n "$exports" ]] && ! eval "$exports"; then
      if [[ "$RUNTIME" == "grok" ]]; then
        rm -f "$out" "$err"
        echo "error: managed Grok requires valid materialized capability exports" >&2
        return 1
      else
        warn_degraded_step "materialize-agent-mcp.sh --export eval" \
          "materializer emitted shell exports that could not be evaluated; stdout redacted because it may contain tokens"
      fi
    fi
  else
    detail="$(<"$err")"
    if [[ -s "$out" ]]; then
      detail="${detail}"$'\n'"materialize-agent-mcp.sh wrote $(wc -c <"$out") bytes to stdout; redacted because it may contain tokens"
    fi
    if [[ "$RUNTIME" == "grok" ]]; then
      rm -f "$out" "$err"
      echo "error: managed Grok capability materialization failed" >&2
      printf '%s\n' "${detail:0:1200}" >&2
      return 1
    else
      warn_degraded_step "materialize-agent-mcp.sh --export" "$detail"
    fi
  fi

  rm -f "$out" "$err"
}

run_repair_tmux_env() {
  local out err detail
  local args=()

  if [[ -n "${CASEIN_TMUX_SESSION:-}" ]]; then
    args+=("${CASEIN_TMUX_SESSION}")
  elif [[ -z "${TMUX:-}" ]]; then
    return 0
  fi

  out="$(mktemp)"
  err="$(mktemp)"

  if ! bash "${ROOT}/scripts/lib/repair-tmux-env.sh" "${args[@]}" >"$out" 2>"$err"; then
    detail="$(<"$err")"
    if [[ -s "$out" ]]; then
      detail="${detail}"$'\n'"$(<"$out")"
    fi
    warn_degraded_step "repair-tmux-env.sh" "$detail"
  fi

  rm -f "$out" "$err"
}

if [[ "$RUNTIME" == "grok" ]]; then
  unset CASEIN_GROK_BUNDLE_DIR CASEIN_GROK_BUNDLE_DIGEST
  unset CASEIN_GROK_LEADER_ROOT CASEIN_GROK_LEADER_SOCKET
fi
run_materialize_export
agent_env_export_runtime_paths
run_repair_tmux_env
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py"

# Never redirect agent homes to MCP staging. Preserve only explicit Casein
# owner auth profiles under ~/.casein/agent-auth: signed-in profiles, plus
# empty profiles of registered owners (those fail closed — the provider CLI
# runs its own sign-in inside the profile instead of using the host global
# login). Anything else falls back to the host global provider auth.
enforce_owner_auth() {
  local runtime="$1"
  local key current dir
  key="$(agent_auth_profile_env_key "$runtime")" || return 0
  current="${!key:-}"

  if [[ -n "$current" ]] && ! agent_auth_profile_under_root "$current"; then
    unset "$key"
    current=""
  fi

  # The workspace-derived profile is canonical when this launch belongs to a
  # workspace; agent_auth_profile_active_dir already applies the registered
  # owner fail-closed rule.
  if [[ -n "${CASEIN_WORKSPACE_NAME:-}" ]]; then
    if dir="$(agent_auth_profile_active_dir "$CASEIN_WORKSPACE_NAME" "$runtime")"; then
      export "$key=$dir"
      if ! agent_auth_profile_signed_in "$dir" "$runtime"; then
        echo "casein: owner auth is fail-closed for this workspace; ${runtime} uses ${dir} — complete the sign-in it prompts for (the host global login is not shared)" >&2
      fi
      return 0
    fi
  fi

  if [[ -n "$current" ]] && ! agent_auth_profile_signed_in "$current" "$runtime"; then
    unset "$key"
  fi
}

unset GROK_HOME OPENCODE_CONFIG
enforce_owner_auth codex
enforce_owner_auth claude

sync_project_mcp_config() {
  local runtime="$1"
  local checkout="${CASEIN_CHECKOUT:-}"
  local staging="${CASEIN_AGENT_MCP_HOME:-}"

  [[ -n "$checkout" && -d "$checkout" && -n "$staging" ]] || return 0

  # OpenCode has no per-launch MCP flag alternative (unlike Codex/Claude/Grok),
  # so inject whenever this launch is paired to a workspace staging tree.
  if [[ "${CASEIN_WORKTREE:-0}" != "1" ]]; then
    case "$runtime" in
      agent)
        echo "warn: skipping project MCP injection for ${runtime} outside an agent worktree" >&2
        return 0
        ;;
      opencode)
        if [[ -z "${CASEIN_WORKSPACE_NAME:-}" || -z "${CASEIN_WORKSPACE_ID:-}" ]]; then
          echo "warn: skipping OpenCode MCP injection — workspace not paired (no CASEIN_WORKSPACE_*)" >&2
          return 0
        fi
        ;;
    esac
  fi

  case "$runtime" in
    agent)
      if [[ -f "${staging}/.mcp.json" ]]; then
        cp "${staging}/.mcp.json" "${checkout}/.mcp.json"
        chmod 600 "${checkout}/.mcp.json"
      fi
      ;;
    opencode)
      if [[ -f "${staging}/opencode.json" ]]; then
        mkdir -p "${checkout}/.opencode"
        cp "${staging}/opencode.json" "${checkout}/.opencode/opencode.json"
        chmod 600 "${checkout}/.opencode/opencode.json"
      fi
      ;;
  esac
}

# Stage Casein-infra skills for OpenCode. OpenCode also auto-loads
# ~/.claude/skills, but project .opencode/skills and ~/.config/opencode/skills
# are the first-class paths (and project skills are often gitignored).
opencode_install_skills() {
  local checkout="${CASEIN_CHECKOUT:-}"
  local src="${ROOT}/.claude/skills"

  agent_skills_install "$src" "${HOME}/.config/opencode"
  if [[ -n "$checkout" && -d "$checkout" ]]; then
    mkdir -p "${checkout}/.opencode" 2>/dev/null || true
    agent_skills_install "$src" "${checkout}/.opencode"
  fi
}

sync_project_mcp_config "$RUNTIME"
if [[ "$RUNTIME" == "opencode" ]]; then
  opencode_install_skills
fi

if [[ -n "${CASEIN_CHECKOUT:-}" && -d "${CASEIN_CHECKOUT}" ]]; then
  cd "${CASEIN_CHECKOUT}"
fi

runtime_bin() {
  local name="$1"
  local bin
  bin="$(real_agent_bin "$name")"
  if [[ -z "$bin" ]]; then
    echo "error: could not find executable for ${name} (run scripts/install-agent-shims.sh)" >&2
    exit 1
  fi
  printf '%s\n' "$bin"
}

workspace_slug() {
  CASEIN_WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME:-workspace}" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ.get('CASEIN_WORKSPACE_NAME', 'workspace')).strip('-').lower()
print(slug or 'workspace')
"
}

# Codex gets per-launch -c overrides, so the caller pane can ride the URL as
# a query param with the real value (percent-encoded: %3 -> %253). Header
# env-expansion is not needed for this runtime.
codex_terminal_mcp_url() {
  local url="${CASEIN_TERMINAL_MCP_URL}"

  if [[ -n "${CASEIN_CALLER_PANE:-}" ]]; then
    local pane="${CASEIN_CALLER_PANE/\%/%25}"
    if [[ "$url" == *\?* ]]; then
      url="${url}&caller_pane=${pane}"
    else
      url="${url}?caller_pane=${pane}"
    fi
  fi

  printf '%s' "$url"
}

codex_mcp_config_args() {
  local slug terminal_key preview_key artifact_key tidewave_key
  slug="$(workspace_slug)"
  terminal_key="casein-terminal-${slug}"
  preview_key="casein-preview-${slug}"
  artifact_key="casein-artifact-${slug}"
  tidewave_key="casein-tidewave-${slug}"

  printf '%s\0' \
    -c "mcp_servers.${terminal_key}.url=\"$(codex_terminal_mcp_url)\"" \
    -c "mcp_servers.${terminal_key}.enabled=true" \
    -c "mcp_servers.${terminal_key}.bearer_token_env_var=\"CASEIN_API_TOKEN\"" \
    -c "mcp_servers.${preview_key}.url=\"${CASEIN_PREVIEW_MCP_URL}\"" \
    -c "mcp_servers.${preview_key}.enabled=true" \
    -c "mcp_servers.${preview_key}.bearer_token_env_var=\"CASEIN_API_TOKEN\"" \
    -c "mcp_servers.${artifact_key}.url=\"${CASEIN_ARTIFACT_MCP_URL}\"" \
    -c "mcp_servers.${artifact_key}.enabled=true" \
    -c "mcp_servers.${artifact_key}.bearer_token_env_var=\"CASEIN_API_TOKEN\""

  if [[ -n "${CASEIN_TIDEWAVE_MCP_URL:-}" ]]; then
    printf '%s\0' \
      -c "mcp_servers.${tidewave_key}.url=\"${CASEIN_TIDEWAVE_MCP_URL}\"" \
      -c "mcp_servers.${tidewave_key}.enabled=true"
  fi
}

codex_arg_sets_execution_policy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dangerously-bypass-approvals-and-sandbox)
        return 0
        ;;
      --sandbox | --sandbox=* | -s | -s=* | -s?*)
        return 0
        ;;
      --ask-for-approval | --ask-for-approval=* | -a | -a=* | -a?*)
        return 0
        ;;
    esac
  done

  return 1
}

# --- Semantic agent-state reporting (Grok bootstrap + Codex lifecycle hooks) -
# Claude gets its state hooks via a materialized --settings file below. Grok
# loads a global SessionStart bootstrap hook so Casein learns the session ID and
# can attach ACP with the session-scoped capability bundle. The bundle owns the
# remaining lifecycle hooks. Codex receives per-launch hook tables plus the
# legacy completion-only notify fallback. Both honor the same opt-out as
# Claude: CASEIN_AGENT_STATE_HOOKS=0.

grok_install_state_hook() {
  [[ "${CASEIN_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0
  local src="${ROOT}/scripts/agent-hooks/grok-casein-agent-bootstrap.json"
  local hooks_dir="${GROK_HOME:-${HOME}/.grok}/hooks"
  local dst="${hooks_dir}/casein-agent-state.json"
  local script_src="${ROOT}/scripts/casein-agent-state.sh"
  local trusted_dir="${HOME}/.casein/grok-bootstrap-hooks"
  local script_dst="${trusted_dir}/casein-agent-state.sh"
  local tmp
  [[ -f "$src" ]] || return 0
  mkdir -p "$trusted_dir" 2>/dev/null || return 0
  chmod 700 "$trusted_dir" 2>/dev/null || return 0
  mkdir -p "$hooks_dir" 2>/dev/null || return 0
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    cp "$src" "$dst" 2>/dev/null || true
  fi
  if [[ -f "$script_src" ]] && ! cmp -s "$script_src" "$script_dst" 2>/dev/null; then
    tmp="$(mktemp "${trusted_dir}/.casein-agent-state.XXXXXX")"
    cp "$script_src" "$tmp"
    chmod 500 "$tmp"
    mv -f "$tmp" "$script_dst"
  fi
  export CASEIN_GROK_BOOTSTRAP_HOOK="$script_dst"
}

grok_bind_state_hook_path() {
  local trusted_dir="${HOME}/.casein/grok-bootstrap-hooks"
  mkdir -p "$trusted_dir"
  chmod 700 "$trusted_dir"
  export CASEIN_GROK_BOOTSTRAP_HOOK="${trusted_dir}/casein-agent-state.sh"
}

grok_validate_managed_context() {
  local socket="${CASEIN_GROK_LEADER_SOCKET:-}"
  local root="${CASEIN_GROK_LEADER_ROOT:-}"
  local bundle="${CASEIN_GROK_BUNDLE_DIR:-}"
  local digest="${CASEIN_GROK_BUNDLE_DIGEST:-}"
  local socket_real root_real

  if [[ -z "$socket" || -z "$root" || -z "$bundle" || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: managed Grok launch is missing its private leader or capability bundle metadata" >&2
    return 1
  fi

  if [[ ! "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
    echo "error: managed Grok launch requires an exact tmux pane id" >&2
    return 1
  fi

  socket_real="$(realpath -m "$socket")"
  root_real="$(realpath -m "$root")"
  if [[ "$(dirname "$socket_real")" != "$root_real" ]] ||
     [[ "$(basename "$socket_real")" != "leader.sock" ]] ||
     [[ ! "$(basename "$root_real")" =~ ^[0-9a-f]{24}$ ]] ||
     [[ -L "$root" ]]; then
    echo "error: refusing Grok leader socket outside the private leader root" >&2
    return 1
  fi

  if ! python3 "${ROOT}/scripts/lib/grok-capability-bundle.py" verify \
      "$bundle" --digest "$digest" >/dev/null; then
    echo "error: refusing invalid or mutable Grok capability bundle" >&2
    return 1
  fi
}

grok_capability_api_base() {
  local base="${CASEIN_API_BASE_URL:-${CASEIN_URL:-}}"
  if [[ -z "$base" ]]; then
    base="${CASEIN_TERMINAL_MCP_URL%%/api/terminals/mcp*}"
  fi
  [[ -n "$base" ]] || return 1
  printf '%s\n' "${base%/}"
}

grok_parse_capability_response() {
  local response_file="$1"
  python3 - "$response_file" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
token = data.get("token")
capability_id = data.get("capability_id")
if not isinstance(token, str) or not token.startswith("grokcap_"):
    raise SystemExit(1)
if not isinstance(capability_id, str) or not capability_id:
    raise SystemExit(1)
terminal = (data.get("allowed_tools") or data.get("effective_tools") or {}).get("terminal", [])
write_enabled = "terminal_send_agent_command" in terminal
print(token)
print(capability_id)
print("true" if write_enabled else "false")
PY
}

grok_current_capability() {
  local token="$1" base="$2" response parsed
  response="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/capability-current.XXXXXX")"
  if ! curl --max-time 5 -fsS -o "$response" \
      -H "authorization: Bearer ${token}" \
      "${base}/api/agent-capabilities/current" 2>/dev/null; then
    rm -f "$response"
    return 1
  fi
  # The current endpoint intentionally never returns the raw token. Reuse the
  # cached bearer only when every launch-bound claim still matches this exact
  # workspace, tmux session, leader, bundle, and checkout.
  parsed="$({ CAP_TOKEN="$token" python3 - "$response" <<'PY'
import hashlib, json, os, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
capability_id = data.get("capability_id")
if not isinstance(capability_id, str) or not capability_id:
    raise SystemExit(1)
checkout = os.path.realpath(os.environ["CASEIN_CHECKOUT"])
expected = {
    "workspace_id": os.environ["CASEIN_WORKSPACE_ID"],
    "runtime": "grok",
    "tmux_session_id": os.environ["CASEIN_TMUX_SESSION"],
    "pane_id": os.environ["TMUX_PANE"],
    "leader_id": os.path.basename(os.path.dirname(os.environ["CASEIN_GROK_LEADER_SOCKET"])),
    "bundle_digest": os.environ["CASEIN_GROK_BUNDLE_DIGEST"],
    "checkout_digest": hashlib.sha256(checkout.encode()).hexdigest(),
}
if any(data.get(key) != value for key, value in expected.items()):
    raise SystemExit(1)
terminal = (data.get("effective_tools") or {}).get("terminal", [])
print(os.environ["CAP_TOKEN"])
print(capability_id)
print("true" if "terminal_send_agent_command" in terminal else "false")
PY
  } 2>/dev/null)" || { rm -f "$response"; return 1; }
  rm -f "$response"
  printf '%s\n' "$parsed"
}

grok_issue_capability() {
  local bootstrap_token="$1" base="$2" response request parsed
  response="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/capability-issue.XXXXXX")"
  request="$(
    CASEIN_WORKSPACE_ID="$CASEIN_WORKSPACE_ID" \
      CASEIN_TMUX_SESSION="$CASEIN_TMUX_SESSION" \
      TMUX_PANE="$TMUX_PANE" \
      CASEIN_GROK_LEADER_SOCKET="$CASEIN_GROK_LEADER_SOCKET" \
      CASEIN_GROK_BUNDLE_DIGEST="$CASEIN_GROK_BUNDLE_DIGEST" \
      CASEIN_CHECKOUT="$CASEIN_CHECKOUT" \
      python3 - <<'PY'
import hashlib, json, os
checkout = os.path.realpath(os.environ["CASEIN_CHECKOUT"])
print(json.dumps({
    "tmux_session_id": os.environ["CASEIN_TMUX_SESSION"],
    "pane_id": os.environ["TMUX_PANE"],
    "leader_id": os.path.basename(os.path.dirname(os.environ["CASEIN_GROK_LEADER_SOCKET"])),
    "bundle_digest": os.environ["CASEIN_GROK_BUNDLE_DIGEST"],
    "checkout_digest": hashlib.sha256(checkout.encode()).hexdigest(),
}))
PY
  )"

  if ! curl --max-time 8 -fsS -o "$response" -X POST \
      "${base}/api/workspaces/${CASEIN_WORKSPACE_ID}/grok-agent-capabilities" \
      -H "authorization: Bearer ${bootstrap_token}" \
      -H "content-type: application/json" \
      -d "$request" 2>/dev/null; then
    rm -f "$response"
    return 1
  fi
  parsed="$(grok_parse_capability_response "$response")" || { rm -f "$response"; return 1; }
  rm -f "$response"
  printf '%s\n' "$parsed"
}

# Refresh the persistent OAuth store and print one refreshable credential.
#
# The store is host-global: every managed Grok launch on this box refreshes the
# same ~/.grok/auth.json, and its refresh token rotates on use. Workers spawned
# together therefore race one token — the losers present an already-rotated
# credential, and Grok answers a failed refresh by deleting the store outright.
# That demotes "expired, refresh it" into "signed out", which no unattended
# launch can recover from. Serialize the refresh so only one launch rotates,
# and snapshot the store so a failed refresh leaves it no worse than it found
# it.
grok_refresh_persistent_auth() {
  local grok_bin="$1"
  local auth_path backup_dir backup lock_file refresh_fd provider_auth restore_tmp

  auth_path="${HOME}/.grok/auth.json"
  backup_dir="${CASEIN_GROK_AUTH_BACKUP_DIR:-${HOME}/.casein/grok-auth-backups}"
  lock_file="${backup_dir}/refresh.lock"

  if [[ -L "$backup_dir" ]]; then
    echo "error: managed Grok auth backup dir is a symlink" >&2
    return 1
  fi
  if ! mkdir -p "$backup_dir" || ! chmod 700 "$backup_dir"; then
    echo "error: could not prepare the managed Grok auth backup dir" >&2
    return 1
  fi

  exec {refresh_fd}>>"$lock_file" || return 1
  chmod 600 "$lock_file" 2>/dev/null || true
  if ! flock -w 30 "$refresh_fd"; then
    echo "error: timed out waiting for the Grok credential refresh lock" >&2
    return 1
  fi

  # A launch that queued behind another one usually needs no probe at all: the
  # holder ahead of it already rotated the shared credential.
  if provider_auth="$(python3 "${ROOT}/scripts/lib/grok-managed-home.py" auth-json 2>/dev/null)"; then
    printf '%s\n' "$provider_auth"
    return 0
  fi

  backup=""
  if [[ -f "$auth_path" && ! -L "$auth_path" ]]; then
    backup="$(mktemp "${backup_dir}/auth.XXXXXX")" || return 1
    chmod 600 "$backup"
    cat "$auth_path" >"$backup" || { rm -f "$backup"; backup=""; }
  fi

  # Refresh persistent OAuth only in this trusted launcher process. The managed
  # process receives one refreshable credential through Grok's read-only
  # GROK_AUTH seam; neither the host auth store nor the managed auth sentinel is
  # model-readable.
  if command -v timeout >/dev/null 2>&1; then
    env -u GROK_HOME -u GROK_AUTH -u GROK_AUTH_PATH \
      -u GROK_AUTH_PROVIDER_COMMAND -u XAI_API_KEY -u GROK_CODE_XAI_API_KEY \
      -u CASEIN_API_TOKEN -u CASEIN_ADMIN_API_TOKEN \
      -u CASEIN_WORKSPACE_API_TOKENS \
      timeout --kill-after=2 30 "$grok_bin" --no-auto-update models \
      >/dev/null 2>&1 || true
  fi

  # The deletion this guard exists for. Put the snapshot back so the credential
  # is merely expired rather than gone, leaving a later launch — or the operator
  # sign-in below — something to rotate.
  if [[ -n "$backup" && ! -e "$auth_path" ]]; then
    restore_tmp="$(mktemp "${HOME}/.grok/.auth.XXXXXX")" &&
      chmod 600 "$restore_tmp" &&
      cat "$backup" >"$restore_tmp" &&
      mv -f "$restore_tmp" "$auth_path" &&
      echo "warning: the Grok credential refresh deleted ${auth_path}; restored the pre-refresh snapshot" >&2
  fi
  rm -f "$backup"

  if provider_auth="$(python3 "${ROOT}/scripts/lib/grok-managed-home.py" auth-json)"; then
    printf '%s\n' "$provider_auth"
    return 0
  fi

  echo "error: managed Grok could not obtain refreshable OAuth with at least ten minutes remaining; set CASEIN_GROK_XAI_API_KEY for dedicated API-key auth" >&2
  # The shim resolves `grok` back to this launcher, which would sign in against
  # the managed home instead of the persistent store. Name the real binary.
  echo "hint: to sign in from a headless box, run: ${grok_bin} login --device-auth" >&2
  return 1
}

grok_prepare_managed_home() {
  local socket="$1" grok_bin="$2" reuse="${3:-false}"
  local leader_id managed_root managed_home provider_auth home_action
  leader_id="$(basename "$(dirname "$socket")")"
  managed_root="${CASEIN_GROK_HOME_ROOT:-${HOME}/.casein/grok-homes}"
  home_action="prepare"
  [[ "$reuse" == "true" ]] && home_action="resolve"

  managed_home="$(python3 "${ROOT}/scripts/lib/grok-managed-home.py" "$home_action" \
    "$managed_root" "$leader_id")" || {
    echo "error: failed to prepare the isolated managed Grok home" >&2
    return 1
  }
  if [[ -n "${CASEIN_GROK_XAI_API_KEY:-}" ]]; then
    export XAI_API_KEY="$CASEIN_GROK_XAI_API_KEY"
    unset GROK_AUTH GROK_AUTH_PATH GROK_AUTH_PROVIDER_COMMAND
    export CASEIN_GROK_PROVIDER_AUTH_MODE="api-key"
  elif ! provider_auth="$(python3 "${ROOT}/scripts/lib/grok-managed-home.py" auth-json \
      2>/dev/null)"; then
    # The selected credential is missing or near expiry. Refreshing is a
    # serialized, snapshot-guarded operation on the host-global auth store.
    provider_auth="$(grok_refresh_persistent_auth "$grok_bin")" || return 1
    export GROK_AUTH="$provider_auth"
    unset XAI_API_KEY GROK_CODE_XAI_API_KEY
    export CASEIN_GROK_PROVIDER_AUTH_MODE="oauth-inline-refresh"
  else
    export GROK_AUTH="$provider_auth"
    unset XAI_API_KEY GROK_CODE_XAI_API_KEY
    export CASEIN_GROK_PROVIDER_AUTH_MODE="oauth-inline-refresh"
  fi

  export GROK_HOME="$managed_home"
  export GROK_SUBAGENTS=0
  unset CASEIN_GROK_XAI_API_KEY
}

grok_reset_managed_home() {
  local socket="$1" leader_id managed_root reset_home
  leader_id="$(basename "$(dirname "$socket")")"
  managed_root="${CASEIN_GROK_HOME_ROOT:-${HOME}/.casein/grok-homes}"
  reset_home="$(python3 "${ROOT}/scripts/lib/grok-managed-home.py" prepare \
    "$managed_root" "$leader_id")" || return 1
  [[ "$(realpath -m "$reset_home")" == "$(realpath -m "$GROK_HOME")" ]]
}

# A managed Grok worker whose capability lacks terminal_send_agent_command gets
# the read-only bwrap profile. That profile is severe and — before this — silent:
# the pane reaches a normal-looking prompt, but the worktree and its git metadata
# are write-denied, child network is blocked, and BEAM cannot start
# ("Failed to write to erl_child_setup: 1"), so mix will not run either.
#
# Two separate sessions lost significant time diagnosing this from the symptoms.
# The cause is never local: it is that the workspace's agent-write unlock has
# expired or was never granted, so say so at launch instead of letting the worker
# discover it by failing.
grok_announce_read_only_sandbox() {
  local capability_id="${1:-unknown}"

  cat >&2 <<EOF
warning: Grok is starting with a READ-ONLY sandbox (capability ${capability_id}).
warning:   This worker CANNOT write its worktree, reach the network, or run mix.
warning:   Cause: this workspace's agent-write unlock is expired or absent, so the
warning:   issued capability omits terminal_send_agent_command.
warning:   Fix: have an operator re-grant agent write for the workspace, then
warning:   relaunch. Do NOT set CASEIN_GROK_SANDBOX_BASE to override it — that
warning:   circumvents a deliberate, time-boxed control.
warning:   For write work right now, delegate to codex instead:
warning:     bash scripts/launch-casein-agent.sh codex
EOF
}

grok_install_sandbox_profile() {
  local profile="$1" base="$2" capability_file="$3"
  local tmux_dir="${TMUX%%,*}"
  local bootstrap_file="${CASEIN_AGENT_BOOTSTRAP_FILE:-}"
  local sensitive_env
  local -a sensitive_agent_envs=()

  # /etc/casein is a compatibility symlink to /etc/casein on renamed hosts.
  # bwrap cannot create a deny mountpoint through a symlinked parent, so the
  # sandbox must receive the physical path; symlinked opens still resolve onto
  # the same denied inode inside the sandbox.
  local host_env_file
  host_env_file="$(realpath -m "${CASEIN_ENV_FILE:-/etc/casein/casein.env}")"

  # Grok expands deny globs by walking from their static prefix. Broad globs
  # rooted at /data/workspaces can exceed its 200k-entry safety limit before
  # the leader creates its socket. Resolve the small set of real token files
  # up front and give the sandbox exact paths instead.
  if [[ -d /data/workspaces ]]; then
    while IFS= read -r -d '' sensitive_env; do
      sensitive_agent_envs+=("$sensitive_env")
    done < <(
      find /data/workspaces -xdev -maxdepth 4 -type f -name .devbox-agent.env \
        -print0 2>/dev/null
    )
  fi

  # The leader receives only the current provider access key through its
  # environment. Persistent OAuth/refresh credentials remain outside the
  # managed home and are kernel-denied to Grok and every model-authored tool.
  python3 "${ROOT}/scripts/lib/grok-sandbox-profile.py" install "$profile" "$base" \
    "--read-only=${CASEIN_GROK_BUNDLE_DIR}" \
    "--read-only=$(dirname "$CASEIN_GROK_BOOTSTRAP_HOOK")" \
    "--read-write=${CASEIN_GROK_LEADER_ROOT}" \
    "$capability_file" \
    "${CASEIN_GROK_LEADER_ROOT}/.casein-launcher" \
    "${CASEIN_GROK_LEADER_ROOT}/.casein-runtime" \
    "${CASEIN_GROK_LEADER_LOG}" \
    "$bootstrap_file" \
    "${HOME}/.casein/agent-mcp" \
    "${HOME}/.casein/grok-launcher-secrets" \
    "${CASEIN_GROK_AUTH_BACKUP_DIR:-${HOME}/.casein/grok-auth-backups}" \
    "${HOME}/.casein/grok-leaders/*/capability" \
    "${HOME}/.casein/workspace-api-tokens.json" \
    "${HOME}/.casein/agent-auth" \
    "${HOME}/.ssh" \
    "${HOME}/.gnupg" \
    "${HOME}/.aws" \
    "${HOME}/.azure" \
    "${HOME}/.kube" \
    "${HOME}/.docker" \
    "${HOME}/.codex" \
    "${HOME}/.claude" \
    "${HOME}/.local/share/opencode" \
    "${HOME}/.local/share/keyrings" \
    "${HOME}/.config/gh*" \
    "${HOME}/.config/gcloud" \
    "${HOME}/.config/git/credentials" \
    "${HOME}/.terraform.d" \
    "${HOME}/.git-credentials" \
    "${HOME}/.netrc" \
    "${HOME}/.npmrc" \
    "${HOME}/.pypirc" \
    "${HOME}/.grok/auth.json" \
    "${GROK_HOME}/auth.json" \
    "${HOME}/.grok/mcp_credentials.json" \
    "$host_env_file" \
    "$tmux_dir" \
    "/proc" \
    "${sensitive_agent_envs[@]}" >/dev/null
}

grok_private_leader_ready() {
  local socket="$1" timeout_seconds="${2:-2}" metadata leader_pid
  metadata="$(dirname "$socket")/.casein-launcher"
  [[ -S "$socket" ]] || return 1
  leader_pid="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity "$metadata" \
    2>/dev/null)" || return 1
  [[ "$leader_pid" =~ ^[0-9]+$ ]] || return 1
  python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" probe "$socket" "$leader_pid" "$timeout_seconds" \
    >/dev/null 2>&1
}

grok_stop_private_leader() {
  local socket="$1" leader_dir metadata runtime_file native_lock leader_pid
  local _attempt
  leader_dir="$(dirname "$socket")"
  metadata="${leader_dir}/.casein-launcher"
  runtime_file="${leader_dir}/.casein-runtime"
  native_lock="${leader_dir}/leader.lock"

  if [[ ! -e "$metadata" ]]; then
    if python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" probe "$socket" 0 1 \
        >/dev/null 2>&1; then
      echo "error: refusing to stop a live Grok leader without trusted launcher metadata" >&2
      return 1
    fi
    rm -f "$socket" "$native_lock" "$runtime_file"
    return 0
  fi

  if ! leader_pid="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity \
      "$metadata" 2>/dev/null)"; then
    if read -r leader_pid _starttime <"$metadata" 2>/dev/null &&
       [[ "$leader_pid" =~ ^[0-9]+$ ]] && kill -0 "$leader_pid" 2>/dev/null; then
      echo "error: refusing to signal a process that does not match trusted Grok metadata" >&2
      return 1
    fi
    rm -f "$socket" "$native_lock" "$runtime_file" "$metadata"
    return 0
  fi

  kill -TERM -- "-${leader_pid}" 2>/dev/null || true
  for _attempt in $(seq 1 60); do
    if ! python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" group-live "$leader_pid" \
        >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done
  if python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" group-live "$leader_pid" \
      >/dev/null 2>&1; then
    kill -KILL -- "-${leader_pid}" 2>/dev/null || true
    for _attempt in $(seq 1 40); do
      if ! python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" group-live "$leader_pid" \
          >/dev/null 2>&1; then
        break
      fi
      sleep 0.05
    done
  fi
  if python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" group-live "$leader_pid" \
      >/dev/null 2>&1; then
    echo "error: managed Grok leader process group did not terminate" >&2
    return 1
  fi

  rm -f "$socket" "$native_lock" "$runtime_file" "$metadata"
}

grok_configure_capability() {
  local base bootstrap_token socket leader_id capability_file
  local parsed token capability_id write_enabled profile sandbox_base tmp
  base="$(grok_capability_api_base)" || {
    echo "error: managed Grok capability issuer URL is unavailable" >&2
    return 1
  }
  bootstrap_token="${CASEIN_API_TOKEN:-}"
  socket="$(realpath -m "$CASEIN_GROK_LEADER_SOCKET")"
  leader_id="$(basename "$(dirname "$socket")")"
  capability_file="$(dirname "$socket")/capability"
  export CASEIN_GROK_CAPABILITY_REUSED=false

  if [[ -r "$capability_file" ]] && grok_private_leader_ready "$socket"; then
    token="$(<"$capability_file")"
    if parsed="$(grok_current_capability "$token" "$base")"; then
      mapfile -t fields <<<"$parsed"
      token="${fields[0]:-}"
      capability_id="${fields[1]:-}"
      write_enabled="${fields[2]:-false}"
      export CASEIN_GROK_CAPABILITY_REUSED=true
      grok_debug "capability=reused"
    fi
  fi

  if [[ -z "${capability_id:-}" ]]; then
    if [[ -S "$socket" || -e "$(dirname "$socket")/.casein-launcher" ]]; then
      grok_stop_private_leader "$socket"
    fi
    parsed="$(grok_issue_capability "$bootstrap_token" "$base")" || {
      echo "error: managed Grok capability exchange failed" >&2
      return 1
    }
    mapfile -t fields <<<"$parsed"
    token="${fields[0]:-}"
    capability_id="${fields[1]:-}"
    write_enabled="${fields[2]:-false}"
    tmp="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/capability-token.XXXXXX")"
    printf '%s' "$token" >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$capability_file"
  fi

  if [[ "$write_enabled" == "true" ]]; then
    sandbox_base="strict"
  else
    sandbox_base="read-only"
    grok_announce_read_only_sandbox "$capability_id"
  fi
  profile="casein-${leader_id}-${capability_id//-/}-${sandbox_base}"
  profile="${profile:0:95}"
  if [[ "$CASEIN_GROK_CAPABILITY_REUSED" != "true" ]]; then
    # Deny entries must exist when a new Grok leader resolves the custom
    # profile. Publish empty sentinels from trusted scratch; never replace the
    # live leader's identity/runtime files during an attach.
    for target in "$(dirname "$socket")/.casein-launcher" "$(dirname "$socket")/.casein-runtime"; do
      tmp="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/leader-sentinel.XXXXXX")"
      chmod 600 "$tmp"
      mv -f "$tmp" "$target"
    done
  fi
  grok_install_sandbox_profile "$profile" "$sandbox_base" "$capability_file" || {
    echo "error: failed to install managed Grok sandbox profile" >&2
    return 1
  }

  export CASEIN_API_TOKEN="$token"
  export CASEIN_GROK_SANDBOX_PROFILE="$profile"
  export CASEIN_GROK_SANDBOX_BASE="$sandbox_base"
  export CASEIN_GROK_CAPABILITY_FILE="$capability_file"
  export CASEIN_GROK_PERMISSION_MODE="default"
  unset CASEIN_ADMIN_API_TOKEN CASEIN_WORKSPACE_API_TOKENS
  unset CASEIN_AGENT_ENV_FILE CASEIN_AGENT_BOOTSTRAP_FILE CASEIN_AGENT_MCP_HOME
}

grok_prepare_private_leader() {
  local grok_bin="$1" sandbox_profile="$2" permission_mode="$3"
  local socket="${CASEIN_GROK_LEADER_SOCKET:-}"
  local root="${CASEIN_GROK_LEADER_ROOT:-}"
  local bundle="${CASEIN_GROK_BUNDLE_DIR:-}"
  local digest="${CASEIN_GROK_BUNDLE_DIGEST:-}"
  local socket_real root_real log leader_pid="" runtime_file metadata native_lock
  local expected_signature current_signature tmp detail

  socket_real="$(realpath -m "$socket")"
  root_real="$(realpath -m "$root")"

  mkdir -p "$root_real"
  chmod 700 "$root_real"
  runtime_file="${root_real}/.casein-runtime"
  metadata="${root_real}/.casein-launcher"
  native_lock="${root_real}/leader.lock"
  expected_signature="v2:${sandbox_profile}:${permission_mode}"
  export CASEIN_GROK_LEADER_REUSED=false
  grok_debug "prepare reuse_verified=${CASEIN_GROK_REUSE_VERIFIED:-false} runtime_expected=${expected_signature} runtime_current=$(if [[ -f "$runtime_file" ]]; then cat "$runtime_file"; else printf missing; fi)"

  if [[ "${CASEIN_GROK_REUSE_VERIFIED:-false}" == "true" ]] &&
     [[ -S "$socket_real" ]] &&
     python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity "$metadata" \
       >/dev/null 2>&1; then
    current_signature=""
    [[ -f "$runtime_file" ]] && current_signature="$(<"$runtime_file")"
    if [[ "$current_signature" == "$expected_signature" ]]; then
      export CASEIN_GROK_LEADER_REUSED=true
      grok_debug "leader=reused verified-fast-path"
      return 0
    fi
  elif grok_private_leader_ready "$socket_real"; then
    current_signature=""
    if [[ -f "$runtime_file" ]]; then
      current_signature="$(<"$runtime_file")"
    fi
    if [[ "$current_signature" == "$expected_signature" ]]; then
      export CASEIN_GROK_LEADER_REUSED=true
      grok_debug "leader=reused probed-path"
      return 0
    fi

    grok_stop_private_leader "$socket_real"
  fi

  # Trusted launcher metadata is written before Grok creates its native lock or
  # socket. A lock-only slow start therefore remains safely stoppable, while a
  # sandbox-authored native lock is never treated as process authority.
  if [[ -s "$metadata" || -S "$socket_real" ]]; then
    grok_stop_private_leader "$socket_real"
  fi
  # A replaced/new leader must never consume policy or hooks that the prior
  # sandbox could have changed in its writable GROK_HOME.
  grok_reset_managed_home "$socket_real"
  grok_install_state_hook
  grok_install_sandbox_profile \
    "$CASEIN_GROK_SANDBOX_PROFILE" \
    "$CASEIN_GROK_SANDBOX_BASE" \
    "$CASEIN_GROK_CAPABILITY_FILE"
  rm -f "$socket_real" "$native_lock"
  log="${CASEIN_GROK_LEADER_LOG:?managed Grok leader log is missing}"
  rm -f "$log"
  leader_pid="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" spawn \
    "$metadata" "$log" "$grok_bin" \
    --sandbox "$sandbox_profile" --permission-mode "$permission_mode" \
    --leader-socket "$socket_real" agent leader \
    --no-exit-on-disconnect --relay-on-demand --no-auto-update)" || {
    echo "error: failed to spawn the private Grok leader" >&2
    return 1
  }

  for _attempt in $(seq 1 600); do
    if [[ -S "$socket_real" ]] && grok_private_leader_ready "$socket_real" 60; then
      tmp="$(mktemp "${CASEIN_LAUNCHER_SECRET_DIR}/leader-runtime.XXXXXX")"
      printf '%s' "$expected_signature" >"$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$runtime_file"
      return 0
    fi
    if ! python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity "$metadata" \
        >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  grok_stop_private_leader "$socket_real" || true
  echo "error: private Grok leader did not become ready at ${socket_real}" >&2
  if [[ -s "$log" ]]; then
    detail="$(<"$log")"
    printf '%s\n' "${detail:0:1200}" >&2
  fi
  return 1
}

grok_resume_quiesced_on_exit() {
  local leader_pid="${CASEIN_GROK_QUIESCED_PID:-}"
  if [[ "$leader_pid" =~ ^[0-9]+$ ]]; then
    kill -CONT -- "-${leader_pid}" 2>/dev/null || true
  fi
}

grok_quiesce_for_reattach() {
  local socket="$1" metadata leader_pid tui_starttime
  metadata="$(dirname "$socket")/.casein-launcher"
  leader_pid="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" identity "$metadata")" || {
    echo "error: cannot quiesce a Grok leader without trusted identity" >&2
    return 1
  }

  export CASEIN_GROK_QUIESCED_PID="$leader_pid"
  trap grok_resume_quiesced_on_exit EXIT INT TERM
  kill -STOP -- "-${leader_pid}"

  # The live leader cannot race these files while stopped. Reset the only
  # mutable launch policy and hook inputs, then make the attaching TUI cross
  # Grok's irreversible bwrap boundary before the leader runs again.
  grok_reset_managed_home "$socket"
  grok_install_state_hook
  grok_install_sandbox_profile \
    "$CASEIN_GROK_SANDBOX_PROFILE" \
    "$CASEIN_GROK_SANDBOX_BASE" \
    "$CASEIN_GROK_CAPABILITY_FILE"

  tui_starttime="$(python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" \
    process-starttime "$$")"
  env -i PATH="$PATH" python3 "${ROOT}/scripts/lib/grok-leader-runtime.py" \
    resume-after-sandbox "$metadata" "$$" "$tui_starttime" 20 \
    >/dev/null 2>>"$CASEIN_GROK_LEADER_LOG" &

  # The watcher now owns the fail-safe SIGCONT. Clearing this value prevents
  # the shell's EXIT trap from resuming early if exec succeeds.
  export CASEIN_GROK_QUIESCED_PID=""
}

codex_arg_sets_notify() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      notify=*)
        return 0
        ;;
    esac
  done

  return 1
}

codex_state_notify_args() {
  [[ "${CASEIN_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0

  if codex_arg_sets_notify "$@"; then
    return 0
  fi

  local script="${CASEIN_AGENT_MCP_HOME:-${CASEIN_SCRIPTS:-${ROOT}/scripts}}/casein-codex-notify.sh"
  if [[ ! -x "$script" ]]; then
    warn_degraded_step "Codex notify integration" "missing executable: ${script}"
    return 0
  fi

  printf '%s\0' -c "notify=[\"${script}\"]"
}

codex_arg_sets_hooks() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      hooks.* | features.hooks=* | features.codex_hooks=*)
        return 0
        ;;
    esac
  done
  return 1
}

codex_state_hook_args() {
  [[ "${CASEIN_AGENT_STATE_HOOKS:-1}" != "0" ]] || return 0
  codex_arg_sets_hooks "$@" && return 0

  local script quoted event config
  script="${CASEIN_AGENT_MCP_HOME:-${CASEIN_SCRIPTS:-${ROOT}/scripts}}/casein-codex-notify.sh"
  if [[ ! -x "$script" ]]; then
    warn_degraded_step "Codex lifecycle hooks" "missing executable: ${script}"
    return 0
  fi
  quoted="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$script")"

  for event in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop SubagentStart SubagentStop; do
    config="hooks.${event}=[{matcher=\"*\",hooks=[{type=\"command\",command=${quoted},timeout=5}]}]"
    printf '%s\0' -c "$config"
  done
}

codex_security_config_args() {
  printf '%s\0' -c \
    'shell_environment_policy.exclude=["CASEIN_API_TOKEN","CASEIN_ADMIN_API_TOKEN","CASEIN_WORKSPACE_API_TOKENS"]'
}

codex_arg_sets_model() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --model | --model=* | -m | -m=* | -m?* | model=* | --config=model=* | -c=model=* | -cmodel=*)
        return 0
        ;;
    esac
  done

  return 1
}

codex_model_args() {
  codex_arg_sets_model "$@" && return 0

  local model="${CASEIN_CODEX_DEFAULT_MODEL:-}"

  # Owner auth profiles deliberately isolate CODEX_HOME. Keep that isolation
  # for credentials while inheriting the operator's normal model preference
  # from the host-global Codex config.
  if [[ -z "$model" && -f "${HOME}/.codex/config.toml" ]]; then
    model="$(python3 - "${HOME}/.codex/config.toml" <<'PY' 2>/dev/null || true
import sys, tomllib

try:
    with open(sys.argv[1], "rb") as config:
        value = tomllib.load(config).get("model")
    if isinstance(value, str) and value:
        print(value)
except Exception:
    pass
PY
)"
  fi

  if [[ -n "$model" ]]; then
    printf '%s\0' --model "$model"
  fi
}

codex_arg_sets_terminal_title() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      tui.terminal_title=* | --config=tui.terminal_title=* | -c=tui.terminal_title=* | -ctui.terminal_title=*)
        return 0
        ;;
    esac
  done

  return 1
}

codex_terminal_title_args() {
  # Codex defaults to ["spinner", "project"], which labels every managed
  # worktree tab as agent-codex-adhoc-<timestamp>. Prefer the conversation's
  # task-oriented thread title, matching Claude's useful OSC pane titles.
  # A caller-provided -c/--config value remains authoritative.
  codex_arg_sets_terminal_title "$@" && return 0

  printf '%s\0' -c 'tui.terminal_title=["spinner","thread"]'
}

codex_workspace_mode() {
  local fallback="${CASEIN_WORKSPACE_MODE:-manual}"
  local base="${CASEIN_API_BASE_URL:-${CASEIN_URL:-}}"
  local workspace_id="${CASEIN_WORKSPACE_ID:-}"
  local token="${CASEIN_API_TOKEN:-}"
  local payload mode

  if [[ -n "$base" && -n "$workspace_id" && -n "$token" ]]; then
    payload="$(curl --max-time 1 -fsS \
      -H "authorization: Bearer ${token}" \
      "${base%/}/api/workspaces/${workspace_id}/status" 2>/dev/null || true)"

    mode="$(CODEX_WORKSPACE_STATUS="$payload" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    payload = json.loads(os.environ.get("CODEX_WORKSPACE_STATUS") or "{}")
    mode = payload.get("mode", {})
    if isinstance(mode, dict):
        mode = mode.get("value")
    if isinstance(mode, str):
        print(mode)
except Exception:
    pass
PY
)"

    if [[ -n "$mode" ]]; then
      printf '%s\n' "$mode"
      return 0
    fi
  fi

  printf '%s\n' "$fallback"
}

codex_default_args() {
  if codex_arg_sets_execution_policy "$@"; then
    return 0
  fi

  # Paired Codex sessions are operator-owned raw terminals, so match the
  # interactive Full Access choice unless the caller supplies an execution
  # policy or explicitly opts back into the workspace-mode defaults with 0.
  case "${CASEIN_CODEX_DEFAULT_YOLO:-1}" in
    1 | true | TRUE | yes | YES | on | ON)
      printf '%s\0' --dangerously-bypass-approvals-and-sandbox
      return 0
      ;;
  esac

  case "$(codex_workspace_mode)" in
    review | observe | locked)
      printf '%s\0' --sandbox read-only --ask-for-approval never
      ;;
    *)
      printf '%s\0' --sandbox workspace-write --ask-for-approval on-request
      ;;
  esac
}

claude_arg_sets_permission_policy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dangerously-skip-permissions)
        return 0
        ;;
      --permission-mode | --permission-mode=*)
        return 0
        ;;
    esac
  done

  return 1
}

claude_default_args() {
  case "${CASEIN_CLAUDE_DEFAULT_YOLO:-1}" in
    0 | false | FALSE | no | NO | off | OFF)
      return 0
      ;;
  esac

  if claude_arg_sets_permission_policy "$@"; then
    return 0
  fi

  printf '%s\0' --dangerously-skip-permissions
}

case "$RUNTIME" in
  grok)
    export GROK_CURSOR_MCPS_ENABLED=false
    export GROK_CLAUDE_MCPS_ENABLED=false
    grok_bin="$(runtime_bin grok)"
    grok_validate_managed_context
    grok_socket="$(realpath -m "${CASEIN_GROK_LEADER_SOCKET:-}")"
    grok_leader_dir="$(dirname "$grok_socket")"
    grok_leader_id="$(basename "$grok_leader_dir")"
    grok_leader_base="$(dirname "$grok_leader_dir")"
    grok_log_dir="${grok_leader_base}/.logs"
    if [[ -L "$grok_leader_base" || -L "$grok_log_dir" ]]; then
      echo "error: managed Grok leader base contains an unsafe symlink" >&2
      exit 1
    fi
    mkdir -p "$grok_log_dir"
    chmod 700 "$grok_leader_base" "$grok_log_dir"
    export CASEIN_GROK_LEADER_LOG="${grok_log_dir}/${grok_leader_id}.log"
    exec {grok_launch_fd}>>"${grok_leader_base}/.launch-${grok_leader_id}.flock"
    if ! flock -w 15 "$grok_launch_fd"; then
      echo "error: timed out waiting for the managed Grok leader launch lock" >&2
      exit 1
    fi
    grok_reuse_candidate=false
    if grok_private_leader_ready "$grok_socket"; then
      if [[ -f "${grok_leader_dir}/.casein-runtime" ]] &&
         [[ "$(<"${grok_leader_dir}/.casein-runtime")" == v2:* ]]; then
        grok_reuse_candidate=true
      else
        grok_stop_private_leader "$grok_socket"
      fi
    elif [[ -e "${grok_leader_dir}/.casein-launcher" || -S "$grok_socket" ]]; then
      grok_stop_private_leader "$grok_socket"
    fi
    grok_debug "reuse_candidate=${grok_reuse_candidate}"
    grok_prepare_managed_home "$grok_socket" "$grok_bin" "$grok_reuse_candidate"
    if [[ "$grok_reuse_candidate" == "true" ]]; then
      grok_bind_state_hook_path
    else
      grok_install_state_hook
    fi
    grok_user_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --leader-socket)
          [[ $# -ge 2 ]] || { echo "error: --leader-socket requires a path" >&2; exit 2; }
          if [[ "$(realpath -m "$2")" != "$grok_socket" ]]; then
            echo "error: managed Grok must use Casein's private leader socket" >&2
            exit 2
          fi
          shift 2
          ;;
        --leader-socket=*)
          if [[ "$(realpath -m "${1#*=}")" != "$grok_socket" ]]; then
            echo "error: managed Grok must use Casein's private leader socket" >&2
            exit 2
          fi
          shift
          ;;
        --sandbox | --sandbox=* | --permission-mode | --permission-mode=* | --always-approve | --yolo | --dangerously-skip-permissions | --allow | --allow=* | --deny | --deny=* | --tools | --tools=* | --cwd | --cwd=* | --worktree | --worktree=* | -w | -w?* | --agents | --agents=* | --subagents | --check | --self-verify | --best-of-n | --best-of-n=*)
          echo "error: managed Grok launch owns sandbox, permission, cwd, worktree, and subagent policy" >&2
          exit 2
          ;;
        *)
          grok_user_args+=("$1")
          shift
          ;;
      esac
    done
    grok_configure_capability
    if [[ "$grok_reuse_candidate" == "true" ]] &&
       [[ "$CASEIN_GROK_CAPABILITY_REUSED" == "true" ]]; then
      export CASEIN_GROK_REUSE_VERIFIED=true
    else
      export CASEIN_GROK_REUSE_VERIFIED=false
    fi
    grok_debug "capability_reused=${CASEIN_GROK_CAPABILITY_REUSED} reuse_verified=${CASEIN_GROK_REUSE_VERIFIED}"
    grok_prepare_private_leader "$grok_bin" "$CASEIN_GROK_SANDBOX_PROFILE" "$CASEIN_GROK_PERMISSION_MODE"
    if [[ "$CASEIN_GROK_LEADER_REUSED" == "true" ]]; then
      grok_quiesce_for_reattach "$grok_socket"
      # The background handoff watcher inherited the locked fd and holds it
      # until SIGCONT. Close only this shell's copy so the TUI does not retain
      # the launch lock for its full lifetime.
      exec {grok_launch_fd}>&-
    else
      flock -u "$grok_launch_fd"
      exec {grok_launch_fd}>&-
    fi
    exec "$grok_bin" --sandbox "$CASEIN_GROK_SANDBOX_PROFILE" \
      --permission-mode "$CASEIN_GROK_PERMISSION_MODE" \
      --leader-socket "$grok_socket" --no-subagents "${grok_user_args[@]}"
    ;;
  codex)
    codex_sidechat_target=""
    codex_user_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --sidechat)
          codex_sidechat_target="${2:-}"
          shift 2
          ;;
        *)
          codex_user_args+=("$1")
          shift
          ;;
      esac
    done
    set -- "${codex_user_args[@]}"

    # Codex discovers reusable skills under CODEX_HOME/skills.
    agent_skills_install "${ROOT}/.claude/skills" "${CODEX_HOME:-${HOME}/.codex}"

    codex_args=()
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_mcp_config_args)
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_security_config_args)
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_model_args "$@")
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_terminal_title_args "$@")
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_state_hook_args "$@")
    while IFS= read -r -d '' arg; do
      codex_args+=("$arg")
    done < <(codex_state_notify_args "$@")
    if [[ -n "$codex_sidechat_target" ]]; then
      sidechat_resolve_target "$codex_sidechat_target"
      sidechat_prompt="${CASEIN_AGENT_MCP_HOME}/codex-sidechat-prompt.txt"
      sidechat_write_prompt "$sidechat_prompt" "Codex"
      codex_sidechat_instructions="$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$sidechat_prompt")"
      codex_args+=(-c "developer_instructions=${codex_sidechat_instructions}")
      codex_args+=(--sandbox read-only --ask-for-approval never)
    else
      while IFS= read -r -d '' arg; do
        codex_args+=("$arg")
      done < <(codex_default_args "$@")
    fi
    exec "$(runtime_bin codex)" "${codex_args[@]}" "$@"
    ;;
  opencode)
    exec "$(runtime_bin opencode)" "$@"
    ;;
  claude)
    sidechat_target=""
    claude_user_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --sidechat)
          sidechat_target="${2:-}"
          shift 2
          ;;
        *)
          claude_user_args+=("$1")
          shift
          ;;
      esac
    done
    set -- "${claude_user_args[@]}"

    # Stage Casein-infra skills (e.g. delegate-to-worker) into this launch's Claude
    # config home so agents in non-casein workspaces still have them. enforce_owner_auth
    # above sets CLAUDE_CONFIG_DIR when the workspace uses an owner profile; otherwise
    # Claude reads the host global ~/.claude. Opt out with CASEIN_AGENT_SKILLS=0.
    agent_skills_install "${ROOT}/.claude/skills" "${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

    # Source MCP from this workspace's isolated staging tree (one per workspace),
    # like GROK_HOME/CODEX_HOME do — never from a shared-checkout project file,
    # which collides/accumulates across workspaces. Prefer staging; fall back to
    # the checkout only if staging is missing.
    mcp_json="${CASEIN_AGENT_MCP_HOME}/.mcp.json"
    if [[ ! -f "$mcp_json" && -f "${CASEIN_CHECKOUT}/.mcp.json" ]]; then
      mcp_json="${CASEIN_CHECKOUT}/.mcp.json"
    fi
    if [[ ! -f "$mcp_json" ]]; then
      echo "error: missing .mcp.json in ${CASEIN_AGENT_MCP_HOME} or ${CASEIN_CHECKOUT}" >&2
      exit 1
    fi
    if [[ -d "${CASEIN_CHECKOUT}" ]]; then
      cd "${CASEIN_CHECKOUT}"
    else
      cd "$(dirname "$mcp_json")"
    fi
    # --mcp-config is additive (no --strict): keeps the operator's global MCP
    # servers (e.g. fff) and layers the workspace's terminal/preview/artifact on top.
    # CASEIN_API_TOKEN is already exported by agent_env_resolve above, so the
    # ${CASEIN_API_TOKEN} placeholder in the config resolves.
    claude_args=(--mcp-config "$mcp_json")

    if [[ -n "$sidechat_target" ]]; then
      sidechat_resolve_target "$sidechat_target"
      sidechat_prompt="${CASEIN_AGENT_MCP_HOME}/claude-sidechat-prompt.txt"
      sidechat_write_prompt "$sidechat_prompt"
      sidechat_settings="${CASEIN_AGENT_MCP_HOME}/claude-sidechat-settings.json"
      if [[ ! -f "$sidechat_settings" ]]; then
        echo "error: missing ${sidechat_settings} — run scripts/materialize-agent-mcp.sh" >&2
        exit 1
      fi
      claude_args+=(--settings "$sidechat_settings")
      claude_args+=(--append-system-prompt "$(<"$sidechat_prompt")")
    else
      # Semantic agent-state hooks (opt out with CASEIN_AGENT_STATE_HOOKS=0). The
      # settings file is materialized next to .mcp.json and, like --mcp-config, is
      # additive with the operator's global settings.
      hooks_settings="${CASEIN_AGENT_MCP_HOME}/claude-hooks-settings.json"
      if [[ "${CASEIN_AGENT_STATE_HOOKS:-1}" != "0" && -f "$hooks_settings" ]]; then
        claude_args+=(--settings "$hooks_settings")
      fi
      while IFS= read -r -d '' arg; do
        claude_args+=("$arg")
      done < <(claude_default_args "$@")
    fi

    exec "$(runtime_bin claude)" "${claude_args[@]}" "$@"
    ;;
  agent)
    if [[ "${CASEIN_WORKTREE:-0}" != "1" ]]; then
      export GROK_CURSOR_MCPS_ENABLED=false
      export GROK_CLAUDE_MCPS_ENABLED=false
    fi
    exec "$(runtime_bin agent)" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown runtime: $RUNTIME" >&2
    usage >&2
    exit 1
    ;;
esac
