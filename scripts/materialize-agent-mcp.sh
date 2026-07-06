#!/usr/bin/env bash
#
# Materialize per-workspace MCP client configs for external agents (Grok, Claude,
# Codex, OpenCode, Cursor). Reads .devbox-agent.env (or already-exported vars).
# Does not replace global agent homes. DevIDE MCP is injected by the launcher
# using project-local config files or per-launch overrides.
#
# Usage:
#   source .devbox-agent.env
#   bash scripts/materialize-agent-mcp.sh
#
# Exports DEVIDE_AGENT_MCP_HOME on stdout-friendly assignment when sourced:
#   eval "$(bash scripts/materialize-agent-mcp.sh --export)"
#
set -euo pipefail

# Everything this script writes under the staging tree carries the workspace's
# scoped MCP token (directly in env.sh, indirectly via config placeholders) and
# is private to this user's agents. Create it 0700/0600 from the start so there
# is no world-readable window between create and chmod.
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXPORT_ONLY=0
if [[ "${1:-}" == "--export" ]]; then
  EXPORT_ONLY=1
fi

if [[ -f "${ROOT}/.devbox-agent.env" ]] && [[ -z "${DEV_IDE_API_TOKEN:-}" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/.devbox-agent.env"
fi

: "${DEV_IDE_API_TOKEN:?DEV_IDE_API_TOKEN is required (source .devbox-agent.env)}"
DEV_IDE_API_TOKEN="$(
  DEV_IDE_API_TOKEN="${DEV_IDE_API_TOKEN}" python3 -c "
import os
t = os.environ.get('DEV_IDE_API_TOKEN', '').strip()
if len(t) >= 2 and t[0] == t[-1] and t[0] in \"'\\\"\":
    t = t[1:-1]
print(t)
"
)"
: "${DEVIDE_WORKSPACE_NAME:?DEVIDE_WORKSPACE_NAME is required}"
: "${DEVIDE_WORKSPACE_ID:?DEVIDE_WORKSPACE_ID is required}"

# Only ever bake a token that is positively registered for THIS workspace into
# agent configs. The MCP endpoints reject tools/call from any token not scoped
# to the workspace (workspace_scoped_token_required), and a pane shell can
# inherit the global admin token, a stale/rotated token, or another workspace's
# token as DEV_IDE_API_TOKEN. Validating membership in the scoped-token registry
# (env file + runtime store) closes all three cases in one place: keep the
# inherited token only if it is registered here, otherwise swap in this
# workspace's scoped token, and fail closed when none exists.
# shellcheck source=scripts/lib/workspace-scoped-token.sh
source "${ROOT}/scripts/lib/workspace-scoped-token.sh"
DEV_IDE_ENV_FILE_REF="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
if ! workspace_scoped_token_is_registered_for \
    "$DEV_IDE_ENV_FILE_REF" "$DEVIDE_WORKSPACE_ID" "$DEV_IDE_API_TOKEN"; then
  SCOPED_TOKEN="$(
    workspace_scoped_token_lookup "$DEV_IDE_ENV_FILE_REF" "${DEVIDE_WORKSPACE_ID}"
  )"
  if [[ -n "$SCOPED_TOKEN" ]]; then
    DEV_IDE_API_TOKEN="$SCOPED_TOKEN"
  else
    cat >&2 <<'ERR'
error: DEV_IDE_API_TOKEN is not a workspace-scoped token for this workspace and
no scoped token exists in the registry. Refusing to materialize agent configs
the MCP endpoints would reject. Run scripts/refresh-devbox-agent-pairing.sh to
mint scoped tokens, or export the workspace's scoped DEV_IDE_API_TOKEN.
ERR
    exit 1
  fi
fi
: "${DEVIDE_TERMINAL_MCP_URL:?DEVIDE_TERMINAL_MCP_URL is required}"
: "${DEVIDE_PREVIEW_MCP_URL:?DEVIDE_PREVIEW_MCP_URL is required}"
: "${DEVIDE_API_BASE_URL:=${DEVIDE_URL:-}}"
if [[ -z "${DEVIDE_ARTIFACT_MCP_URL:-}" ]]; then
  DEVIDE_ARTIFACT_MCP_URL="${DEVIDE_PREVIEW_MCP_URL/\/api\/preview\/mcp/\/api\/artifacts\/mcp}"
fi
: "${DEVIDE_TMUX_SESSION:=}"

if [[ -z "${DEVIDE_TIDEWAVE_MCP_URL:-}" ]]; then
  if [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
    DEVIDE_TIDEWAVE_MCP_URL="$(
      bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true
    )"
  fi
  if [[ -z "${DEVIDE_TIDEWAVE_MCP_URL:-}" ]] && [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
    DEVIDE_TIDEWAVE_MCP_URL="$(
      bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
    )"
  fi
fi

if [[ -z "${DEVIDE_CHECKOUT:-}" ]]; then
  case "${DEVIDE_WORKSPACE_NAME}" in
    dalexandre-devide) DEVIDE_CHECKOUT="${ROOT}" ;;
    *)
      if [[ -d "/data/workspaces/${DEVIDE_WORKSPACE_NAME}" ]]; then
        DEVIDE_CHECKOUT="/data/workspaces/${DEVIDE_WORKSPACE_NAME}"
      else
        DEVIDE_CHECKOUT="${ROOT}"
      fi
      ;;
  esac
fi
HOME_DIR="${HOME:?HOME is required}"
DEFAULT_STAGING="${HOME_DIR}/.devide/agent-mcp/${DEVIDE_WORKSPACE_NAME}"
if [[ -n "${DEVIDE_AGENT_MCP_HOME:-}" ]] && [[ "${DEVIDE_AGENT_MCP_HOME}" != "${DEFAULT_STAGING}" ]]; then
  unset DEVIDE_AGENT_MCP_HOME
fi
STAGING="${DEVIDE_AGENT_MCP_HOME:-${DEFAULT_STAGING}}"
export DEVIDE_AGENT_MCP_HOME="${STAGING}"

# Serialize concurrent materializations of the same workspace. Every agent
# launch runs this script and they share one staging tree, so without a lock two
# launches can interleave writes and a reader can observe a half-written env.sh.
# The lock is released when this process exits (fd 9 closes).
mkdir -p "${STAGING}"
chmod 700 "${STAGING}" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  exec 9>"${STAGING}/.materialize.lock"
  flock 9
fi

if [[ -f "${DEVIDE_CHECKOUT}/scripts/devide" ]]; then
  DEVIDE_SCRIPTS="${DEVIDE_CHECKOUT}/scripts"
else
  DEVIDE_SCRIPTS="${DEVIDE_SCRIPTS:-${ROOT}/scripts}"
fi
export DEVIDE_SCRIPTS

mkdir -p "${STAGING}/grok" "${STAGING}/codex" "${STAGING}/cursor"

WORKSPACE_SLUG="$(
  DEVIDE_WORKSPACE_NAME="${DEVIDE_WORKSPACE_NAME}" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ['DEVIDE_WORKSPACE_NAME']).strip('-').lower()
print(slug or 'workspace')
"
)"
TERMINAL_KEY="devide-terminal-${WORKSPACE_SLUG}"
PREVIEW_KEY="devide-preview-${WORKSPACE_SLUG}"
ARTIFACT_KEY="devide-artifact-${WORKSPACE_SLUG}"
TIDEWAVE_KEY="devide-tidewave-${WORKSPACE_SLUG}"

TIDEWAVE_GROK_BLOCK=""
TIDEWAVE_OPENCODE_BLOCK=""
TIDEWAVE_ENV_EXPORT=""
if [[ -n "${DEVIDE_TIDEWAVE_MCP_URL:-}" ]]; then
  TIDEWAVE_GROK_BLOCK="
[mcp_servers.${TIDEWAVE_KEY}]
url = \"${DEVIDE_TIDEWAVE_MCP_URL}\"
enabled = true
"
  TIDEWAVE_OPENCODE_BLOCK=",
    \"${TIDEWAVE_KEY}\": {
      \"type\": \"remote\",
      \"url\": \"${DEVIDE_TIDEWAVE_MCP_URL}\",
      \"enabled\": true,
      \"oauth\": false
    }"
  printf -v TIDEWAVE_ENV_EXPORT 'export DEVIDE_TIDEWAVE_MCP_URL=%q' "${DEVIDE_TIDEWAVE_MCP_URL}"
fi

AUTH_PROFILE_EXPORTS=""
if [[ -f "${ROOT}/scripts/lib/agent-auth-profile.sh" ]]; then
  AUTH_PROFILE_EXPORTS="$(
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" "${DEVIDE_WORKSPACE_NAME}" claude
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" "${DEVIDE_WORKSPACE_NAME}" codex
  )"
fi

# --- Grok (GROK_HOME) ---
cat >"${STAGING}/grok/config.toml" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — do not edit by hand.
[mcp_servers.${TERMINAL_KEY}]
url = "${DEVIDE_TERMINAL_MCP_URL}"
enabled = true

[mcp_servers.${TERMINAL_KEY}.headers]
Authorization = "Bearer \${DEV_IDE_API_TOKEN}"

[mcp_servers.${PREVIEW_KEY}]
url = "${DEVIDE_PREVIEW_MCP_URL}"
enabled = true

[mcp_servers.${PREVIEW_KEY}.headers]
Authorization = "Bearer \${DEV_IDE_API_TOKEN}"

[mcp_servers.${ARTIFACT_KEY}]
url = "${DEVIDE_ARTIFACT_MCP_URL}"
enabled = true

[mcp_servers.${ARTIFACT_KEY}.headers]
Authorization = "Bearer \${DEV_IDE_API_TOKEN}"
${TIDEWAVE_GROK_BLOCK}
EOF

# --- Codex staging marker (launch-devide-agent.sh injects MCP at startup) ---
cat >"${STAGING}/codex/config.toml" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — do not edit by hand.
# DevIDE MCP is injected into Codex by scripts/launch-devide-agent.sh with
# per-launch -c overrides. Keeping this file free of DevIDE MCP entries prevents
# plain Codex startups from requiring a DevIDE token in the environment.
EOF

# --- OpenCode (OPENCODE_CONFIG) ---
cat >"${STAGING}/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "${TERMINAL_KEY}": {
      "type": "remote",
      "url": "${DEVIDE_TERMINAL_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"
      }
    },
    "${PREVIEW_KEY}": {
      "type": "remote",
      "url": "${DEVIDE_PREVIEW_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"
      }
    },
    "${ARTIFACT_KEY}": {
      "type": "remote",
      "url": "${DEVIDE_ARTIFACT_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"
      }
    }${TIDEWAVE_OPENCODE_BLOCK}
  }
}
EOF

# --- Universal .mcp.json (Claude project, Grok, Cursor compat) ---
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py" write-claude-mcp \
  "${STAGING}/.mcp.json" "${DEVIDE_TERMINAL_MCP_URL}" "${DEVIDE_PREVIEW_MCP_URL}" "${DEVIDE_ARTIFACT_MCP_URL}"
cp "${STAGING}/.mcp.json" "${STAGING}/cursor/mcp.json"

# --- Claude Code hooks settings (semantic agent-state reporting) ---
# Injected by the launcher via `claude --settings`. The hook command runs
# through a shell, so $DEVIDE_SCRIPTS resolves from the agent's env at hook time.
AGENT_STATE_HOOK="${DEVIDE_SCRIPTS}/devide-agent-state.sh"
HOOKS_SETTINGS="${STAGING}/claude-hooks-settings.json"
AGENT_STATE_HOOK="${AGENT_STATE_HOOK}" python3 - "${HOOKS_SETTINGS}" <<'PY'
import json, os, sys

command = f'"{os.environ["AGENT_STATE_HOOK"]}"'
entry = [{"hooks": [{"type": "command", "command": command, "timeout": 5}]}]
pretooluse = [{"matcher": "*", "hooks": [{"type": "command", "command": command, "timeout": 5}]}]

settings = {
    "hooks": {
        "UserPromptSubmit": entry,
        "PreToolUse": pretooluse,
        "Notification": entry,
        "Stop": entry,
        "SessionStart": entry,
        "SessionEnd": entry,
    }
}

with open(sys.argv[1], "w") as f:
    json.dump(settings, f, indent=2)
PY
chmod 600 "${HOOKS_SETTINGS}"

ENV_SH="${STAGING}/env.sh"
# Write atomically: a fresh temp inode (0600 under umask) that replaces the old
# file via rename, so a concurrent reader never sees a partial file and any
# stale, laxer-permissioned env.sh from an older run is swapped out wholesale.
ENV_SH_TMP="$(mktemp "${STAGING}/.env.sh.XXXXXX")"
cat >"${ENV_SH_TMP}" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — source or load via devide agent env.
export DEV_IDE_API_TOKEN='${DEV_IDE_API_TOKEN}'
export DEVIDE_WORKSPACE_ID='${DEVIDE_WORKSPACE_ID}'
export DEVIDE_WORKSPACE_NAME='${DEVIDE_WORKSPACE_NAME}'
export DEVIDE_API_BASE_URL='${DEVIDE_API_BASE_URL}'
export DEVIDE_TERMINAL_MCP_URL='${DEVIDE_TERMINAL_MCP_URL}'
export DEVIDE_PREVIEW_MCP_URL='${DEVIDE_PREVIEW_MCP_URL}'
export DEVIDE_ARTIFACT_MCP_URL='${DEVIDE_ARTIFACT_MCP_URL}'
export DEVIDE_TMUX_SESSION='${DEVIDE_TMUX_SESSION}'
${TIDEWAVE_ENV_EXPORT}
${AUTH_PROFILE_EXPORTS}
export DEVIDE_CHECKOUT='${DEVIDE_CHECKOUT}'
export DEVIDE_AGENT_MCP_HOME='${STAGING}'
export DEVIDE_SCRIPTS='${DEVIDE_SCRIPTS}'
export DEVIDE_AGENT_ENV_FILE='${ENV_SH}'
export DEV_IDE_NPM_PREFIX="\${DEV_IDE_NPM_PREFIX:-\${HOME}/.local/share/npm-global}"
export PATH="\${HOME}/.local/bin:\${DEV_IDE_NPM_PREFIX}/bin:\${PATH}"
EOF
chmod 600 "${ENV_SH_TMP}"
mv -f "${ENV_SH_TMP}" "${ENV_SH}"

# Cursor project discovery: copy into checkout when writable (gitignored).
# Claude no longer uses a checkout .mcp.json — the launcher injects this
# workspace's isolated staging file via `claude --mcp-config`, so writing a
# shared-checkout project file (which collided across workspaces) is omitted.
if [[ -n "${DEVIDE_CHECKOUT}" ]] && [[ -d "${DEVIDE_CHECKOUT}" ]] && [[ -w "${DEVIDE_CHECKOUT}" ]]; then
  mkdir -p "${DEVIDE_CHECKOUT}/.cursor"
  cp "${STAGING}/cursor/mcp.json" "${DEVIDE_CHECKOUT}/.cursor/mcp.json"
  chmod 600 "${DEVIDE_CHECKOUT}/.cursor/mcp.json"
fi

python3 "${ROOT}/scripts/lib/merge-agent-mcp.py" 2>/dev/null || true

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  # The materialized .mcp.json (and grok/opencode configs) auth with the
  # literal placeholder `Bearer ${DEV_IDE_API_TOKEN}`, which the agent expands
  # from its process env. The launch wrapper eval's this output before exec'ing
  # the agent, so the token MUST be exported here or every server 401s.
  printf 'export DEV_IDE_API_TOKEN=%q\n' "$DEV_IDE_API_TOKEN"
  printf 'export DEVIDE_ARTIFACT_MCP_URL=%q\n' "$DEVIDE_ARTIFACT_MCP_URL"
  printf 'export DEVIDE_AGENT_MCP_HOME=%q\n' "$STAGING"
  printf 'export DEVIDE_CHECKOUT=%q\n' "$DEVIDE_CHECKOUT"
  printf 'export DEVIDE_AGENT_ENV_FILE=%q\n' "$ENV_SH"
  if [[ -n "$AUTH_PROFILE_EXPORTS" ]]; then
    printf '%s\n' "$AUTH_PROFILE_EXPORTS"
  fi
  exit 0
fi

cat <<EOF
Materialized DevIDE MCP client configs for workspace: ${DEVIDE_WORKSPACE_NAME}
  staging:  ${STAGING}
  checkout: ${DEVIDE_CHECKOUT}

Agents (from any directory — shims on PATH after install-agent-shims.sh):
  grok
  claude
  codex
  opencode

MCP is injected into agents without replacing auth state.
DevIDE MCP is not persisted in global Grok/Codex/OpenCode config files.
EOF
