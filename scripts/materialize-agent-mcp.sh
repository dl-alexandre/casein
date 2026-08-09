#!/usr/bin/env bash
#
# Materialize per-workspace MCP client configs for external agents (Grok, Claude,
# Codex, OpenCode, Cursor). Reads .devbox-agent.env (or already-exported vars).
# Does not replace global agent homes. Grok receives a content-addressed plugin
# bundle through ACP `_meta.pluginDirs`; other agents use per-launch overrides.
#
# Usage:
#   source .devbox-agent.env
#   bash scripts/materialize-agent-mcp.sh
#
# Exports CASEIN_AGENT_MCP_HOME on stdout-friendly assignment when sourced:
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

if [[ -f "${ROOT}/.devbox-agent.env" ]] && [[ -z "${CASEIN_API_TOKEN:-}" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/.devbox-agent.env"
fi

: "${CASEIN_API_TOKEN:?CASEIN_API_TOKEN is required (source .devbox-agent.env)}"
CASEIN_API_TOKEN="$(
  CASEIN_API_TOKEN="${CASEIN_API_TOKEN}" python3 -c "
import os
t = os.environ.get('CASEIN_API_TOKEN', '').strip()
if len(t) >= 2 and t[0] == t[-1] and t[0] in \"'\\\"\":
    t = t[1:-1]
print(t)
"
)"
: "${CASEIN_WORKSPACE_NAME:?CASEIN_WORKSPACE_NAME is required}"
: "${CASEIN_WORKSPACE_ID:?CASEIN_WORKSPACE_ID is required}"

# Only ever bake a token that is positively registered for THIS workspace into
# agent configs. The MCP endpoints reject tools/call from any token not scoped
# to the workspace (workspace_scoped_token_required), and a pane shell can
# inherit the global admin token, a stale/rotated token, or another workspace's
# token as CASEIN_API_TOKEN. Validating membership in the scoped-token registry
# (env file + runtime store) closes all three cases in one place: keep the
# inherited token only if it is registered here, otherwise swap in this
# workspace's scoped token, and fail closed when none exists.
# shellcheck source=scripts/lib/workspace-scoped-token.sh
source "${ROOT}/scripts/lib/workspace-scoped-token.sh"
CASEIN_ENV_FILE_REF="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
if ! workspace_scoped_token_is_registered_for \
    "$CASEIN_ENV_FILE_REF" "$CASEIN_WORKSPACE_ID" "$CASEIN_API_TOKEN"; then
  SCOPED_TOKEN="$(
    workspace_scoped_token_lookup "$CASEIN_ENV_FILE_REF" "${CASEIN_WORKSPACE_ID}"
  )"
  if [[ -n "$SCOPED_TOKEN" ]]; then
    CASEIN_API_TOKEN="$SCOPED_TOKEN"
  else
    cat >&2 <<'ERR'
error: CASEIN_API_TOKEN is not a workspace-scoped token for this workspace and
no scoped token exists in the registry. Refusing to materialize agent configs
the MCP endpoints would reject. Run scripts/refresh-devbox-agent-pairing.sh to
mint scoped tokens, or export the workspace's scoped CASEIN_API_TOKEN.
ERR
    exit 1
  fi
fi
: "${CASEIN_TERMINAL_MCP_URL:?CASEIN_TERMINAL_MCP_URL is required}"
: "${CASEIN_PREVIEW_MCP_URL:?CASEIN_PREVIEW_MCP_URL is required}"
: "${CASEIN_API_BASE_URL:=${CASEIN_URL:-}}"
: "${CASEIN_WORKSPACE_MODE:=manual}"
if [[ -z "${CASEIN_ARTIFACT_MCP_URL:-}" ]]; then
  CASEIN_ARTIFACT_MCP_URL="${CASEIN_PREVIEW_MCP_URL/\/api\/preview\/mcp/\/api\/artifacts\/mcp}"
fi
: "${CASEIN_TMUX_SESSION:=}"

if [[ -z "${CASEIN_TIDEWAVE_MCP_URL:-}" ]]; then
  if [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
    CASEIN_TIDEWAVE_MCP_URL="$(
      bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true
    )"
  fi
  if [[ -z "${CASEIN_TIDEWAVE_MCP_URL:-}" ]] && [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
    CASEIN_TIDEWAVE_MCP_URL="$(
      bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
    )"
  fi
fi

if [[ -z "${CASEIN_CHECKOUT:-}" ]]; then
  case "${CASEIN_WORKSPACE_NAME}" in
    dalexandre-casein) CASEIN_CHECKOUT="${ROOT}" ;;
    *)
      if [[ -d "/data/workspaces/${CASEIN_WORKSPACE_NAME}" ]]; then
        CASEIN_CHECKOUT="/data/workspaces/${CASEIN_WORKSPACE_NAME}"
      else
        CASEIN_CHECKOUT="${ROOT}"
      fi
      ;;
  esac
fi
HOME_DIR="${HOME:?HOME is required}"
DEFAULT_STAGING="${HOME_DIR}/.casein/agent-mcp/${CASEIN_WORKSPACE_NAME}"
if [[ -n "${CASEIN_AGENT_MCP_HOME:-}" ]] && [[ "${CASEIN_AGENT_MCP_HOME}" != "${DEFAULT_STAGING}" ]]; then
  unset CASEIN_AGENT_MCP_HOME
fi
STAGING="${CASEIN_AGENT_MCP_HOME:-${DEFAULT_STAGING}}"
export CASEIN_AGENT_MCP_HOME="${STAGING}"

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

if [[ -f "${CASEIN_CHECKOUT}/scripts/casein" ]]; then
  CASEIN_SCRIPTS="${CASEIN_CHECKOUT}/scripts"
else
  CASEIN_SCRIPTS="${CASEIN_SCRIPTS:-${ROOT}/scripts}"
fi
export CASEIN_SCRIPTS

mkdir -p "${STAGING}/grok" "${STAGING}/codex" "${STAGING}/cursor"

# Stage checkout-independent agent hook scripts into the workspace home so they
# resolve no matter which project is the checkout. Prefer the release-shipped
# priv/scripts copy; fall back to the plain scripts tree in a dev checkout.
for _hook in casein-agent-state.sh casein-codex-notify.sh; do
  if [[ -f "${ROOT}/priv/scripts/${_hook}" ]]; then
    _hook_src="${ROOT}/priv/scripts/${_hook}"
  elif [[ -f "${CASEIN_SCRIPTS}/${_hook}" ]]; then
    _hook_src="${CASEIN_SCRIPTS}/${_hook}"
  else
    continue
  fi
  cp "${_hook_src}" "${STAGING}/${_hook}"
  chmod 755 "${STAGING}/${_hook}"
done

WORKSPACE_SLUG="$(
  CASEIN_WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME}" python3 -c "
import os, re
slug = re.sub(r'[^a-zA-Z0-9]+', '-', os.environ['CASEIN_WORKSPACE_NAME']).strip('-').lower()
print(slug or 'workspace')
"
)"
TERMINAL_KEY="casein-terminal-${WORKSPACE_SLUG}"
PREVIEW_KEY="casein-preview-${WORKSPACE_SLUG}"
ARTIFACT_KEY="casein-artifact-${WORKSPACE_SLUG}"
TIDEWAVE_KEY="casein-tidewave-${WORKSPACE_SLUG}"

TIDEWAVE_GROK_BLOCK=""
TIDEWAVE_OPENCODE_BLOCK=""
TIDEWAVE_ENV_EXPORT=""
if [[ -n "${CASEIN_TIDEWAVE_MCP_URL:-}" ]]; then
  TIDEWAVE_GROK_BLOCK="
[mcp_servers.${TIDEWAVE_KEY}]
url = \"${CASEIN_TIDEWAVE_MCP_URL}\"
enabled = true
"
  TIDEWAVE_OPENCODE_BLOCK=",
    \"${TIDEWAVE_KEY}\": {
      \"type\": \"remote\",
      \"url\": \"${CASEIN_TIDEWAVE_MCP_URL}\",
      \"enabled\": true,
      \"oauth\": false
    }"
  printf -v TIDEWAVE_ENV_EXPORT 'export CASEIN_TIDEWAVE_MCP_URL=%q' "${CASEIN_TIDEWAVE_MCP_URL}"
fi

AUTH_PROFILE_EXPORTS=""
if [[ -f "${ROOT}/scripts/lib/agent-auth-profile.sh" ]]; then
  AUTH_PROFILE_EXPORTS="$(
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" "${CASEIN_WORKSPACE_NAME}" claude
    bash "${ROOT}/scripts/lib/agent-auth-profile.sh" "${CASEIN_WORKSPACE_NAME}" codex
  )"
fi

# --- Grok (GROK_HOME) ---
cat >"${STAGING}/grok/config.toml" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — do not edit by hand.
[mcp_servers.${TERMINAL_KEY}]
url = "${CASEIN_TERMINAL_MCP_URL}"
enabled = true

[mcp_servers.${TERMINAL_KEY}.headers]
Authorization = "Bearer \${CASEIN_API_TOKEN}"
X-Casein-Caller-Pane = "\${CASEIN_CALLER_PANE}"

[mcp_servers.${PREVIEW_KEY}]
url = "${CASEIN_PREVIEW_MCP_URL}"
enabled = true

[mcp_servers.${PREVIEW_KEY}.headers]
Authorization = "Bearer \${CASEIN_API_TOKEN}"

[mcp_servers.${ARTIFACT_KEY}]
url = "${CASEIN_ARTIFACT_MCP_URL}"
enabled = true

[mcp_servers.${ARTIFACT_KEY}.headers]
Authorization = "Bearer \${CASEIN_API_TOKEN}"
${TIDEWAVE_GROK_BLOCK}
EOF

# --- Codex staging marker (launch-casein-agent.sh injects MCP at startup) ---
cat >"${STAGING}/codex/config.toml" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — do not edit by hand.
# Casein MCP is injected into Codex by scripts/launch-casein-agent.sh with
# per-launch -c overrides. Keeping this file free of Casein MCP entries prevents
# plain Codex startups from requiring a Casein token in the environment.
EOF

# --- OpenCode (OPENCODE_CONFIG) ---
# Protocol declare (#751): runtimes still negotiate 2025 via legacy initialize.
# merge-agent-mcp.client_protocol_declare() is the single opt-in for _meta /
# protocolVersion once a runtime schema accepts it — do not invent OpenCode
# keys here. Codex MCP is launch-injected (no staging servers); same rule.
cat >"${STAGING}/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "${TERMINAL_KEY}": {
      "type": "remote",
      "url": "${CASEIN_TERMINAL_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:CASEIN_API_TOKEN}",
        "X-Casein-Caller-Pane": "{env:CASEIN_CALLER_PANE}"
      }
    },
    "${PREVIEW_KEY}": {
      "type": "remote",
      "url": "${CASEIN_PREVIEW_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:CASEIN_API_TOKEN}"
      }
    },
    "${ARTIFACT_KEY}": {
      "type": "remote",
      "url": "${CASEIN_ARTIFACT_MCP_URL}",
      "enabled": true,
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:CASEIN_API_TOKEN}"
      }
    }${TIDEWAVE_OPENCODE_BLOCK}
  }
}
EOF

# --- Universal .mcp.json (Claude project, Grok, Cursor compat) ---
# write-claude-mcp / write-grok-mcp merge client_protocol_declare() when non-empty.
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py" write-claude-mcp \
  "${STAGING}/.mcp.json" "${CASEIN_TERMINAL_MCP_URL}" "${CASEIN_PREVIEW_MCP_URL}" "${CASEIN_ARTIFACT_MCP_URL}"
cp "${STAGING}/.mcp.json" "${STAGING}/cursor/mcp.json"
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py" write-grok-mcp \
  "${STAGING}/grok/.mcp.json" "${CASEIN_TERMINAL_MCP_URL}" "${CASEIN_PREVIEW_MCP_URL}" "${CASEIN_ARTIFACT_MCP_URL}"

# --- Claude Code hooks settings (semantic agent-state reporting) ---
# Injected by the launcher via `claude --settings`. The hook command runs
# through a shell, so $CASEIN_SCRIPTS resolves from the agent's env at hook time.
AGENT_STATE_HOOK="${STAGING}/casein-agent-state.sh"
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

# --- Claude sidechat settings (read-only advisor; injected with --sidechat) ---
SIDECHAT_SETTINGS="${STAGING}/claude-sidechat-settings.json"
AGENT_STATE_HOOK="${AGENT_STATE_HOOK}" python3 - "${SIDECHAT_SETTINGS}" <<'PY'
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
    },
    "permissions": {
        "deny": ["Edit", "Write", "Bash"],
    },
}

with open(sys.argv[1], "w") as f:
    json.dump(settings, f, indent=2)
PY
chmod 600 "${SIDECHAT_SETTINGS}"

# --- Grok session capability bundle ---------------------------------------
# Keep Casein capabilities out of the checkout and global Grok config. The
# bundle contains no bearer token: .mcp.json references CASEIN_API_TOKEN from
# this launch environment. A digest directory is never overwritten, so the
# path supplied through ACP `_meta.pluginDirs` is reproducible and immutable.
GROK_BUNDLE_ROOT="${CASEIN_GROK_BUNDLE_ROOT:-${HOME_DIR}/.casein/grok-bundles}"
GROK_BUNDLE_ARGS=(
  build
  --bundle-root "${GROK_BUNDLE_ROOT}"
  --mcp-config "${STAGING}/grok/.mcp.json"
  --skills-root "${ROOT}/.claude/skills"
)

case "${CASEIN_AGENT_STATE_HOOKS:-1}" in
  0 | false | FALSE | no | NO | off | OFF)
    GROK_BUNDLE_ARGS+=(--hooks-disabled)
    ;;
  *)
    GROK_BUNDLE_ARGS+=(
      --hook-config "${ROOT}/scripts/agent-hooks/grok-casein-agent-state.json"
      --hook-script "${STAGING}/casein-agent-state.sh"
    )
    ;;
esac

for _skill in ${CASEIN_GROK_BUNDLE_SKILLS:-preview-ui-walk verify workspace-agent-pair}; do
  if [[ -d "${ROOT}/.claude/skills/${_skill}" ]]; then
    GROK_BUNDLE_ARGS+=(--skill "${_skill}")
  fi
done

mapfile -t GROK_BUNDLE_RESULT < <(
  python3 "${ROOT}/scripts/lib/grok-capability-bundle.py" "${GROK_BUNDLE_ARGS[@]}"
)
CASEIN_GROK_BUNDLE_DIR="${GROK_BUNDLE_RESULT[0]:-}"
CASEIN_GROK_BUNDLE_DIGEST="${GROK_BUNDLE_RESULT[1]:-}"
if [[ ! "${CASEIN_GROK_BUNDLE_DIGEST}" =~ ^[0-9a-f]{64}$ ]] ||
   [[ ! -d "${CASEIN_GROK_BUNDLE_DIR}" ]]; then
  echo "error: Grok capability bundle compiler returned an invalid result" >&2
  exit 1
fi
export CASEIN_GROK_BUNDLE_DIR CASEIN_GROK_BUNDLE_DIGEST

# One private leader per workspace/worktree lets the human TUI and Casein ACP
# attachment converge on the same Grok session without touching the global
# ~/.grok/leader.sock. Keep the path short enough for Unix sockaddr_un.
GROK_LEADER_BASE="${CASEIN_GROK_LEADER_BASE:-${HOME_DIR}/.casein/grok-leaders}"
GROK_LEADER_KEY="$(printf '%s\0%s' "${CASEIN_WORKSPACE_ID}" "$(realpath -m "${CASEIN_CHECKOUT}")" | sha256sum | cut -c1-24)"
CASEIN_GROK_LEADER_ROOT="${GROK_LEADER_BASE}/${GROK_LEADER_KEY}"
CASEIN_GROK_LEADER_SOCKET="${CASEIN_GROK_LEADER_ROOT}/leader.sock"
if [[ "${#CASEIN_GROK_LEADER_SOCKET}" -gt 100 ]]; then
  GROK_LEADER_BASE="/dev/shm/casein-grok-leaders-$(id -u)"
  CASEIN_GROK_LEADER_ROOT="${GROK_LEADER_BASE}/${GROK_LEADER_KEY}"
  CASEIN_GROK_LEADER_SOCKET="${CASEIN_GROK_LEADER_ROOT}/leader.sock"
fi
mkdir -p "${GROK_LEADER_BASE}" "${CASEIN_GROK_LEADER_ROOT}"
chmod 700 "${GROK_LEADER_BASE}" "${CASEIN_GROK_LEADER_ROOT}"
export CASEIN_GROK_LEADER_ROOT CASEIN_GROK_LEADER_SOCKET

ENV_SH="${STAGING}/env.sh"
# Write atomically: a fresh temp inode (0600 under umask) that replaces the old
# file via rename, so a concurrent reader never sees a partial file and any
# stale, laxer-permissioned env.sh from an older run is swapped out wholesale.
ENV_SH_TMP="$(mktemp "${STAGING}/.env.sh.XXXXXX")"
cat >"${ENV_SH_TMP}" <<EOF
# Generated by scripts/materialize-agent-mcp.sh — source or load via casein agent env.
export CASEIN_API_TOKEN='${CASEIN_API_TOKEN}'
export CASEIN_WORKSPACE_ID='${CASEIN_WORKSPACE_ID}'
export CASEIN_WORKSPACE_NAME='${CASEIN_WORKSPACE_NAME}'
export CASEIN_WORKSPACE_MODE='${CASEIN_WORKSPACE_MODE}'
export CASEIN_API_BASE_URL='${CASEIN_API_BASE_URL}'
export CASEIN_CODEX_HOOK_URL='${CASEIN_API_BASE_URL%/}/api/workspaces/${CASEIN_WORKSPACE_ID}/codex/hooks'
export CASEIN_TERMINAL_MCP_URL='${CASEIN_TERMINAL_MCP_URL}'
export CASEIN_PREVIEW_MCP_URL='${CASEIN_PREVIEW_MCP_URL}'
export CASEIN_ARTIFACT_MCP_URL='${CASEIN_ARTIFACT_MCP_URL}'
export CASEIN_TMUX_SESSION='${CASEIN_TMUX_SESSION}'
${TIDEWAVE_ENV_EXPORT}
${AUTH_PROFILE_EXPORTS}
export CASEIN_CHECKOUT='${CASEIN_CHECKOUT}'
export CASEIN_AGENT_MCP_HOME='${STAGING}'
export CASEIN_GROK_BUNDLE_DIR='${CASEIN_GROK_BUNDLE_DIR}'
export CASEIN_GROK_BUNDLE_DIGEST='${CASEIN_GROK_BUNDLE_DIGEST}'
export CASEIN_GROK_LEADER_ROOT='${CASEIN_GROK_LEADER_ROOT}'
export CASEIN_GROK_LEADER_SOCKET='${CASEIN_GROK_LEADER_SOCKET}'
export CASEIN_SCRIPTS='${CASEIN_SCRIPTS}'
export CASEIN_AGENT_ENV_FILE='${ENV_SH}'
export CASEIN_NPM_PREFIX="\${CASEIN_NPM_PREFIX:-\${HOME}/.local/share/npm-global}"
export PATH="\${CASEIN_AGENT_BIN_DIR:-\${HOME}/.casein/agent-shims}:\${CASEIN_NPM_PREFIX}/bin:\${PATH}"
EOF
chmod 600 "${ENV_SH_TMP}"
mv -f "${ENV_SH_TMP}" "${ENV_SH}"

# Cursor project discovery: copy into checkout when writable (gitignored).
# Claude no longer uses a checkout .mcp.json — the launcher injects this
# workspace's isolated staging file via `claude --mcp-config`, so writing a
# shared-checkout project file (which collided across workspaces) is omitted.
if [[ -n "${CASEIN_CHECKOUT}" ]] && [[ -d "${CASEIN_CHECKOUT}" ]] && [[ -w "${CASEIN_CHECKOUT}" ]]; then
  mkdir -p "${CASEIN_CHECKOUT}/.cursor"
  cp "${STAGING}/cursor/mcp.json" "${CASEIN_CHECKOUT}/.cursor/mcp.json"
  chmod 600 "${CASEIN_CHECKOUT}/.cursor/mcp.json"
fi

python3 "${ROOT}/scripts/lib/merge-agent-mcp.py" 2>/dev/null || true

if [[ "$EXPORT_ONLY" -eq 1 ]]; then
  # The materialized .mcp.json (and grok/opencode configs) auth with the
  # literal placeholder `Bearer ${CASEIN_API_TOKEN}`, which the agent expands
  # from its process env. The launch wrapper eval's this output before exec'ing
  # the agent, so the token MUST be exported here or every server 401s.
  printf 'export CASEIN_API_TOKEN=%q\n' "$CASEIN_API_TOKEN"
  printf 'export CASEIN_ARTIFACT_MCP_URL=%q\n' "$CASEIN_ARTIFACT_MCP_URL"
  printf 'export CASEIN_AGENT_MCP_HOME=%q\n' "$STAGING"
  printf 'export CASEIN_GROK_BUNDLE_DIR=%q\n' "$CASEIN_GROK_BUNDLE_DIR"
  printf 'export CASEIN_GROK_BUNDLE_DIGEST=%q\n' "$CASEIN_GROK_BUNDLE_DIGEST"
  printf 'export CASEIN_GROK_LEADER_ROOT=%q\n' "$CASEIN_GROK_LEADER_ROOT"
  printf 'export CASEIN_GROK_LEADER_SOCKET=%q\n' "$CASEIN_GROK_LEADER_SOCKET"
  printf 'export CASEIN_CHECKOUT=%q\n' "$CASEIN_CHECKOUT"
  printf 'export CASEIN_AGENT_ENV_FILE=%q\n' "$ENV_SH"
  if [[ -n "$AUTH_PROFILE_EXPORTS" ]]; then
    printf '%s\n' "$AUTH_PROFILE_EXPORTS"
  fi
  exit 0
fi

cat <<EOF
Materialized Casein MCP client configs for workspace: ${CASEIN_WORKSPACE_NAME}
  staging:  ${STAGING}
  checkout: ${CASEIN_CHECKOUT}

Agents (from any directory — shims on PATH after install-agent-shims.sh):
  grok
  claude
  codex
  opencode

MCP is injected into agents without replacing auth state.
Casein MCP is not persisted in global Grok/Codex/OpenCode config files.
Grok bundle: ${CASEIN_GROK_BUNDLE_DIR}
Grok bundle digest: ${CASEIN_GROK_BUNDLE_DIGEST}
EOF
