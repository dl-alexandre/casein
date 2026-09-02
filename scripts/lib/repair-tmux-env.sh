#!/usr/bin/env bash
#
# Repair Casein tmux session environment for the current or named session.
#
# Fixes stale session env from earlier MCP work:
#   - CASEIN_API_TOKEN stored with literal shell quotes
#   - provider homes redirecting auth to empty staging
#   - PATH left as a literal "${PATH}" string
#
# Usage:
#   bash scripts/lib/repair-tmux-env.sh                 # current tmux session
#   bash scripts/lib/repair-tmux-env.sh <session_name>  # explicit session
#
# Stdout is one machine-readable outcome:
#   repaired
#   skipped:not_casein_session
#   skipped:unknown_workspace
#   skipped:no_scoped_token
#   failed:workspace_listing
#
# Exit codes — do not collapse these:
#   0  repaired, or skipped:not_casein_session (benign no-op)
#   1  hard failure (missing token, no session, listing failed)
#   2  skipped:unknown_workspace (actionable catalog miss)
#   3  skipped:no_scoped_token (actionable unpaired workspace)
#
# A non-casein session is not an error. A casein session that should have
# been repaired and was not, is. Launchers must warn only on non-zero.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Labeled tmux only — bare tmux follows $TMUX / default server (#248).
# shellcheck source=tmux-label.sh
source "${ROOT}/scripts/lib/tmux-label.sh"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
LOCAL_URL="${CASEIN_URL:-http://127.0.0.1:4000}"
CANONICAL_SCRIPTS="${CASEIN_SCRIPTS_ROOT:-${ROOT}/scripts}"
# shellcheck source=agent-auth-profile.sh
source "${ROOT}/scripts/lib/agent-auth-profile.sh"
# shellcheck source=workspace-scoped-token.sh
source "${ROOT}/scripts/lib/workspace-scoped-token.sh"

log() { printf '>>> %s\n' "$*" >&2; }
emit_outcome() { printf '%s\n' "$1"; }

# Listing workspaces needs the global/admin token; it is never pushed into a
# session — agent panes only receive workspace-scoped tokens, because the MCP
# endpoints reject tools/call made with the global token.
#
# So the ambient CASEIN_API_TOKEN is the *wrong* credential whenever this runs
# where it matters most: inside a repaired agent pane, where it holds that
# pane's workspace-scoped token. `GET /api/workspaces` carries no workspace id
# in its path, so ApiAuth's scoped branch denies it 403 and the whole repair
# aborted with failed:workspace_listing. Prefer the env-file global token and
# keep the ambient one only as a fallback for operators who exported a global
# token and cannot read the env file.
LISTING_TOKENS=()
env_file_token="$(sudo awk -F= '/^CASEIN_API_TOKEN=/{print $2}' "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
if [[ -n "$env_file_token" ]]; then
  LISTING_TOKENS+=("$env_file_token")
fi
if [[ -n "${CASEIN_API_TOKEN:-}" && "${CASEIN_API_TOKEN}" != "$env_file_token" ]]; then
  LISTING_TOKENS+=("${CASEIN_API_TOKEN}")
fi
unset env_file_token

if [[ ${#LISTING_TOKENS[@]} -eq 0 ]]; then
  echo "error: CASEIN_API_TOKEN missing (export it or set ${ENV_FILE})" >&2
  emit_outcome "failed:missing_token"
  exit 1
fi

declare -A WORKSPACE_IDS=()
WORKSPACE_IDS_LOADED=0

# A 403/empty catalog is a single credential problem, not N per-session
# "unknown workspace" skips. Fail the listing itself.
load_workspace_ids() {
  if [[ "${WORKSPACE_IDS_LOADED}" -eq 1 ]]; then
    return 0
  fi

  local body parsed token
  body=""

  # Try each candidate credential; a scoped token 403s here by design, so a
  # single failure is not yet a verdict on the catalog.
  for token in "${LISTING_TOKENS[@]}"; do
    if body="$(curl -fsS -H "authorization: Bearer ${token}" "${LOCAL_URL}/api/workspaces")"; then
      break
    fi
    body=""
  done

  if [[ -z "$body" ]]; then
    echo "error: failed to list workspaces from ${LOCAL_URL}/api/workspaces" \
      "(no available token has admin listing; empty catalog is not assumed)" >&2
    emit_outcome "failed:workspace_listing"
    return 1
  fi

  if ! parsed="$(
    printf '%s' "$body" | python3 -c "
import json, sys
for ws in json.load(sys.stdin):
    name = ws.get('name') or ''
    ws_id = ws.get('id') or ''
    if name and ws_id:
        print(f\"{name}\t{ws_id}\")
"
  )"; then
    echo "error: could not parse /api/workspaces response" >&2
    emit_outcome "failed:workspace_listing"
    return 1
  fi

  while IFS=$'\t' read -r name id; do
    [[ -n "$name" && -n "$id" ]] || continue
    WORKSPACE_IDS["$name"]="$id"
  done <<<"$parsed"

  WORKSPACE_IDS_LOADED=1
}

default_checkout() {
  local workspace_name="$1"
  case "$workspace_name" in
    dalexandre-casein | casein) printf '%s\n' "${ROOT}" ;;
    *)
      if [[ -d "/data/workspaces/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/${workspace_name}"
      elif [[ -d "/data/workspaces/dalexandre/${workspace_name}" ]]; then
        printf '%s\n' "/data/workspaces/dalexandre/${workspace_name}"
      else
        printf '%s\n' "/data/workspaces/${workspace_name}"
      fi
      ;;
  esac
}

scripts_for_checkout() {
  local checkout="$1"
  if [[ -f "${checkout}/scripts/casein" ]]; then
    printf '%s\n' "${checkout}/scripts"
  else
    printf '%s\n' "${CANONICAL_SCRIPTS}"
  fi
}

discover_tidewave_mcp_url() {
  local workspace_name="$1"
  local workspace_id="$2"
  local url=""

  if [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
    url="$(
      CASEIN_WORKSPACE_NAME="${workspace_name}" \
        CASEIN_WORKSPACE_ID="${workspace_id}" \
        bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
    )"
  fi

  if [[ -z "$url" ]] && [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
    url="$(bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true)"
  fi

  printf '%s' "$url"
}

materialize_workspace() {
  local workspace_name="$1"
  local workspace_id="$2"
  local session="${3:-}"
  local agent_token="$4"
  local checkout scripts tidewave_url query_suffix

  checkout="$(default_checkout "$workspace_name")"
  scripts="$(scripts_for_checkout "$checkout")"
  tidewave_url="$(discover_tidewave_mcp_url "$workspace_name" "$workspace_id")"
  query_suffix="workspace_id=${workspace_id}"
  if [[ -n "$session" ]]; then
    query_suffix="${query_suffix}&tmux_session=${session}"
  fi

  CASEIN_API_TOKEN="${agent_token}" \
    CASEIN_WORKSPACE_NAME="${workspace_name}" \
    CASEIN_WORKSPACE_ID="${workspace_id}" \
    CASEIN_TMUX_SESSION="${session}" \
    CASEIN_API_BASE_URL="${LOCAL_URL}" \
    CASEIN_TERMINAL_MCP_URL="${LOCAL_URL}/api/terminals/mcp?${query_suffix}" \
    CASEIN_PREVIEW_MCP_URL="${LOCAL_URL}/api/preview/mcp?${query_suffix}" \
    CASEIN_ARTIFACT_MCP_URL="${LOCAL_URL}/api/artifacts/mcp?workspace_id=${workspace_id}" \
    CASEIN_TIDEWAVE_MCP_URL="${tidewave_url}" \
    CASEIN_CHECKOUT="${checkout}" \
    CASEIN_SCRIPTS="${scripts}" \
    bash "${ROOT}/scripts/materialize-agent-mcp.sh" >/dev/null
}

set_provider_auth_profiles() {
  local session="$1"
  local workspace_name="$2"
  local key value

  casein_tmux set-environment -t "$session" -u CLAUDE_CONFIG_DIR 2>/dev/null || true
  casein_tmux set-environment -t "$session" -u CODEX_HOME 2>/dev/null || true

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" && -n "$value" ]] || continue
    casein_tmux set-environment -t "$session" "$key" "$value"
  done < <(
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --pairs "$workspace_name" claude
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" --pairs "$workspace_name" codex
  )
}

session_env_present() {
  local session="$1"
  local key="$2"
  local line

  line="$(casein_tmux show-environment -t "$session" "$key" 2>/dev/null || true)"
  [[ "$line" == "${key}="* ]]
}

set_session_env_if_missing() {
  local session="$1"
  local key="$2"
  local value="$3"

  if ! session_env_present "$session" "$key"; then
    casein_tmux set-environment -t "$session" "$key" "$value"
  fi
}

# `tmux set-environment` only seeds panes created AFTER the call — a shell that
# is already running never sees the repair, so `clauded` / `codex` / `grok`
# keep failing in exactly the pane the operator ran this script from. Push the
# refreshed session env into each live pane's shell.
#
# Panes running a foreground program (an agent, vim, less) are skipped rather
# than typed into; they pick the env up when that program exits and the shell
# draws its next prompt.
refresh_live_panes() {
  local session="$1"
  local env_sh="$2"
  local pane cmd quoted_env_sh
  printf -v quoted_env_sh '%q' "$env_sh"

  while IFS=$'\t' read -r pane cmd; do
    [[ -n "$pane" ]] || continue

    case "$cmd" in
      bash | zsh | sh | dash | ksh | fish) ;;
      *)
        log "pane ${pane} busy (${cmd}) — run 'casein_sync_session_env' there after it exits"
        continue
        ;;
    esac

    # Leading space keeps this out of history under HISTCONTROL=ignorespace.
    # Newer panes define casein_sync_session_env via shell integration; older
    # ones predate it and fall back to the materialized env file.
    casein_tmux send-keys -t "$pane" \
      " casein_sync_session_env 2>/dev/null || source ${quoted_env_sh}" C-m
  done < <(
    casein_tmux list-panes -s -t "$session" -F "#{pane_id}"$'\t'"#{pane_current_command}" 2>/dev/null
  )
}

repair_session() {
  local session="$1"
  local workspace_name workspace_id checkout scripts staging env_sh

  if [[ ! "$session" =~ ^casein_([^_]+)_ ]]; then
    log "skip ${session} (not a casein workspace session)"
    emit_outcome "skipped:not_casein_session"
    return 0
  fi

  load_workspace_ids || return 1

  workspace_name="${BASH_REMATCH[1]}"
  workspace_id="${WORKSPACE_IDS[$workspace_name]:-}"

  if [[ -z "$workspace_id" ]]; then
    log "skip ${session} (unknown workspace ${workspace_name})"
    emit_outcome "skipped:unknown_workspace"
    return 2
  fi

  local agent_token
  agent_token="$(workspace_scoped_token_lookup "$ENV_FILE" "$workspace_id")"

  if [[ -z "$agent_token" ]]; then
    log "skip ${session}: no workspace-scoped token for ${workspace_name}" \
      "(run scripts/refresh-devbox-agent-pairing.sh to mint one)"
    emit_outcome "skipped:no_scoped_token"
    return 3
  fi

  checkout="$(default_checkout "$workspace_name")"
  scripts="$(scripts_for_checkout "$checkout")"
  staging="${HOME}/.casein/agent-mcp/${workspace_name}"
  env_sh="${staging}/env.sh"

  local tidewave_url
  tidewave_url="$(discover_tidewave_mcp_url "$workspace_name" "$workspace_id")"

  # Heal partial shim loss before rewriting PATH (claude missing / siblings ok).
  if [[ -x "${ROOT}/scripts/install-agent-shims.sh" ]]; then
    bash "${ROOT}/scripts/install-agent-shims.sh" --ensure >/dev/null 2>&1 ||
      log "warn: agent shim ensure failed for ${session} — continuing env repair"
  fi

  materialize_workspace "$workspace_name" "$workspace_id" "$session" "$agent_token"

  casein_tmux set-environment -t "$session" -u GROK_HOME 2>/dev/null || true
  casein_tmux set-environment -t "$session" -u OPENCODE_CONFIG 2>/dev/null || true
  set_provider_auth_profiles "$session" "$workspace_name"
  set_session_env_if_missing "$session" CASEIN_TERMINAL_SCHEME dark
  set_session_env_if_missing "$session" COLORFGBG "15;0"

  casein_tmux set-environment -t "$session" CASEIN_API_TOKEN "$agent_token"
  casein_tmux set-environment -t "$session" CASEIN_WORKSPACE_ID "$workspace_id"
  casein_tmux set-environment -t "$session" CASEIN_WORKSPACE_NAME "$workspace_name"
  casein_tmux set-environment -t "$session" CASEIN_TMUX_SESSION "$session"
  casein_tmux set-environment -t "$session" CASEIN_API_BASE_URL "${LOCAL_URL}"
  casein_tmux set-environment -t "$session" CASEIN_TERMINAL_MCP_URL "${LOCAL_URL}/api/terminals/mcp?workspace_id=${workspace_id}&tmux_session=${session}"
  casein_tmux set-environment -t "$session" CASEIN_PREVIEW_MCP_URL "${LOCAL_URL}/api/preview/mcp?workspace_id=${workspace_id}&tmux_session=${session}"
  casein_tmux set-environment -t "$session" CASEIN_ARTIFACT_MCP_URL "${LOCAL_URL}/api/artifacts/mcp?workspace_id=${workspace_id}"
  if [[ -n "$tidewave_url" ]]; then
    casein_tmux set-environment -t "$session" CASEIN_TIDEWAVE_MCP_URL "$tidewave_url"
  else
    casein_tmux set-environment -t "$session" -u CASEIN_TIDEWAVE_MCP_URL 2>/dev/null || true
  fi
  casein_tmux set-environment -t "$session" CASEIN_CHECKOUT "$checkout"
  casein_tmux set-environment -t "$session" CASEIN_AGENT_MCP_HOME "$staging"
  casein_tmux set-environment -t "$session" CASEIN_SCRIPTS "$scripts"
  casein_tmux set-environment -t "$session" CASEIN_AGENT_ENV_FILE "$env_sh"
  local npm_prefix terminal_shims tools_bin repaired_path
  npm_prefix="${CASEIN_NPM_PREFIX:-${HOME}/.local/share/npm-global}"
  terminal_shims="${CASEIN_TERMINAL_SHIMS_DIR:-${HOME}/.casein/terminal-shims}"
  tools_bin="${CASEIN_TERMINAL_TOOLS_DIR:-${HOME}/.casein/tools}/bin"
  # Match PaneEnv / Shims.path_with_shims order: terminal shims → tools →
  # agent launchers → npm package bins → existing PATH (deduped below).
  repaired_path="${terminal_shims}:${tools_bin}:${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}:${npm_prefix}/bin:${PATH}"
  repaired_path="$(
    PATH="$repaired_path" python3 - <<'PY'
import os
seen = set()
out = []
for part in os.environ.get("PATH", "").split(":"):
    if part and part not in seen:
        seen.add(part)
        out.append(part)
print(":".join(out))
PY
  )"
  casein_tmux set-environment -t "$session" CASEIN_NPM_PREFIX "$npm_prefix"
  casein_tmux set-environment -t "$session" PATH "$repaired_path"

  refresh_live_panes "$session" "$env_sh"

  log "repaired ${session} (${workspace_name})"
  emit_outcome "repaired"
}

resolve_session() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    printf '%s\n' "$1"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    casein_tmux display-message -p '#{session_name}' 2>/dev/null || true
    return 0
  fi

  return 1
}

session="$(resolve_session "${1:-}" || true)"
if [[ -z "$session" ]]; then
  echo "error: no tmux session to repair (pass session name or run inside tmux)" >&2
  emit_outcome "failed:no_session"
  exit 1
fi

repair_session "$session"
