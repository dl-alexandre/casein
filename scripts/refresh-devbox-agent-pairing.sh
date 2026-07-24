#!/usr/bin/env bash
#
# Refresh .devbox-agent.env and materialized MCP configs without rebuilding.
# Ensures loopback :4000 works (socat proxy when using canary Unix sockets).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${CASEIN_ENV_FILE:-/etc/devide/devide.env}"
WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME:-dalexandre-devide}"
AGENT_ENV="${ROOT}/.devbox-agent.env"

log() { printf '>>> %s\n' "$*"; }

ADMIN_TOKEN="$(sudo awk -F= '/^CASEIN_API_TOKEN=/{print $2}' "$ENV_FILE" | tail -n 1 | sed "s/^['\"]//;s/['\"]$//")"
if [[ -z "$ADMIN_TOKEN" ]]; then
  echo "error: CASEIN_API_TOKEN missing from $ENV_FILE" >&2
  exit 1
fi

# shellcheck source=scripts/lib/workspace-scoped-token.sh
source "${ROOT}/scripts/lib/workspace-scoped-token.sh"

bash scripts/ensure-devide-loopback-proxy.sh

LOCAL_URL="http://127.0.0.1:4000"
PUBLIC_URL="https://devide.devbox.milcgroup.com"
SCOPED_TOKENS_JSON="$(workspace_scoped_token_read_json "$ENV_FILE")"
SCOPED_TOKENS_CHANGED=0

ensure_scoped_token_for_workspace() {
  local workspace_id="$1"
  local result_var="$2"
  local token merged_json

  mapfile -t _scoped_lines < <(
    WORKSPACE_ID="$workspace_id" EXISTING_JSON="$SCOPED_TOKENS_JSON" python3 - <<'PY'
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
    if val == workspace_id or (isinstance(val, list) and workspace_id in val):
        print(tok)
        print(json.dumps(tokens, separators=(",", ":")))
        sys.exit(0)

new_tok = secrets.token_hex(32)
tokens[new_tok] = workspace_id
print(new_tok)
print(json.dumps(tokens, separators=(",", ":")))
PY
  )
  token="${_scoped_lines[0]:-}"
  merged_json="${_scoped_lines[1]:-}"
  [[ -n "$merged_json" ]] || merged_json="{}"

  if [[ -z "$token" ]]; then
    echo "error: failed to resolve workspace-scoped token for ${workspace_id}" >&2
    exit 1
  fi

  if [[ "$merged_json" != "$SCOPED_TOKENS_JSON" ]]; then
    SCOPED_TOKENS_JSON="$merged_json"
    SCOPED_TOKENS_CHANGED=1
  fi

  printf -v "$result_var" '%s' "$token"
}

write_scoped_tokens_if_needed() {
  [[ "$SCOPED_TOKENS_CHANGED" == "1" ]] || return 0
  workspace_scoped_token_write_env "$ENV_FILE" "$SCOPED_TOKENS_JSON"
}

relaunch_current_release_if_needed() {
  [[ "$SCOPED_TOKENS_CHANGED" == "1" ]] || return 0

  if [[ "${DEVIDE_REFRESH_RELAUNCH_ON_TOKEN_CHANGE:-1}" != "1" ]]; then
    log "workspace token env changed; relaunch the current DevIDE release before MCP verification"
    return 0
  fi

  local active_release="${CASEIN_DEPLOY_ROOT:-/opt/devide}/release"
  local tarball revision

  if [[ ! -x "${active_release}/bin/casein" ]]; then
    log "warning: workspace token env changed but ${active_release} is not an executable release"
    return 0
  fi

  revision="$(git rev-parse --verify --quiet origin/master 2>/dev/null || true)"
  revision="${revision:-manual-token-refresh}"

  log "relaunching current release so it sees updated workspace-scoped tokens"
  tarball="$(sudo mktemp "${CASEIN_DEPLOY_ROOT:-/opt/devide}/dev_ide-token-refresh-XXXXXX.tgz")"
  sudo tar -C "$active_release" -czf "$tarball" .
  sudo chown "$(id -un):$(id -gn)" "$tarball"

  if bash scripts/deploy-devbox-release.sh "$tarball" "$revision"; then
    log "release relaunched with refreshed token env"
  else
    sudo rm -f "$tarball"
    return 1
  fi

  sudo rm -f "$tarball"
  bash scripts/ensure-devide-loopback-proxy.sh
}

WORKSPACES_JSON="$(
  curl -fsS -H "authorization: Bearer ${ADMIN_TOKEN}" "${LOCAL_URL}/api/workspaces"
)"

WORKSPACE_ID="$(
  WORKSPACES_JSON="$WORKSPACES_JSON" WORKSPACE_NAME="$WORKSPACE_NAME" python3 -c "
import json, os
name = os.environ['WORKSPACE_NAME']
for w in json.loads(os.environ['WORKSPACES_JSON']):
    if w.get('name') == name:
        print(w['id'])
        break
"
)"

if [[ -z "$WORKSPACE_ID" ]]; then
  echo "error: workspace ${WORKSPACE_NAME} not found" >&2
  exit 1
fi

log "ensuring workspace-scoped MCP token for ${WORKSPACE_NAME}"
ensure_scoped_token_for_workspace "$WORKSPACE_ID" AGENT_TOKEN

default_checkout() {
  local workspace_name="$1"
  case "$workspace_name" in
    dalexandre-devide | dev_ide) printf '%s\n' "${ROOT}" ;;
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
  if [[ -f "${checkout}/scripts/devide" ]]; then
    printf '%s\n' "${checkout}/scripts"
  else
    printf '%s\n' "${ROOT}/scripts"
  fi
}

materialize_all_workspaces() {
  local prefix="${DEVIDE_WORKSPACE_PREFIX:-dalexandre}"

  WORKSPACES_JSON="$WORKSPACES_JSON" PREFIX="$prefix" python3 -c "
import json, os

prefix = os.environ.get('PREFIX', '')
for ws in json.loads(os.environ['WORKSPACES_JSON']):
    name = ws.get('name') or ''
    ws_id = ws.get('id') or ''
    if not name or not ws_id:
        continue
    if prefix and not name.startswith(prefix):
        continue
    print(f\"{name}\t{ws_id}\")
" >"${TMPDIR:-/tmp}/devide-refresh-workspaces.$$"

  while IFS=$'\t' read -r ws_name ws_id; do
    [[ -n "$ws_name" && -n "$ws_id" ]] || continue
    checkout="$(default_checkout "$ws_name")"
    scripts="$(scripts_for_checkout "$checkout")"
    log "materializing MCP for ${ws_name}"
    ensure_scoped_token_for_workspace "$ws_id" ws_token
    CASEIN_API_TOKEN="${ws_token}" \
      DEVIDE_WORKSPACE_NAME="${ws_name}" \
      DEVIDE_WORKSPACE_ID="${ws_id}" \
      DEVIDE_TERMINAL_MCP_URL="${LOCAL_URL}/api/terminals/mcp?workspace_id=${ws_id}" \
      DEVIDE_PREVIEW_MCP_URL="${LOCAL_URL}/api/preview/mcp?workspace_id=${ws_id}" \
      DEVIDE_ARTIFACT_MCP_URL="${LOCAL_URL}/api/artifacts/mcp?workspace_id=${ws_id}" \
      DEVIDE_CHECKOUT="${checkout}" \
      DEVIDE_SCRIPTS="${scripts}" \
      bash scripts/materialize-agent-mcp.sh >/dev/null
  done <"${TMPDIR:-/tmp}/devide-refresh-workspaces.$$"

  rm -f "${TMPDIR:-/tmp}/devide-refresh-workspaces.$$"
}

TIDEWAVE_MCP_URL=""
if [[ -x "${ROOT}/scripts/tidewave-resolve-url.sh" ]]; then
  TIDEWAVE_MCP_URL="$(
    DEVIDE_WORKSPACE_NAME="${WORKSPACE_NAME}" \
      DEVIDE_WORKSPACE_ID="${WORKSPACE_ID}" \
      bash "${ROOT}/scripts/tidewave-resolve-url.sh" 2>/dev/null || true
  )"
fi
if [[ -z "$TIDEWAVE_MCP_URL" ]] && [[ -x "${ROOT}/scripts/preview-env.sh" ]]; then
  TIDEWAVE_MCP_URL="$(bash "${ROOT}/scripts/preview-env.sh" tidewave-latest 2>/dev/null || true)"
fi

cat >"$AGENT_ENV" <<EOF
# DevIDE devbox agent pairing — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source before starting an external agent:  source .devbox-agent.env
# CASEIN_API_TOKEN is workspace-scoped. The global admin token stays only in
# /etc/devide/devide.env; never copy it into an agent-readable checkout.

export CASEIN_API_TOKEN='${AGENT_TOKEN}'
export DEVIDE_URL='${LOCAL_URL}'
export DEVIDE_PUBLIC_URL='${PUBLIC_URL}'
export DEVIDE_WORKSPACE_ID='${WORKSPACE_ID}'
export DEVIDE_WORKSPACE_NAME='${WORKSPACE_NAME}'
export DEVIDE_TERMINAL_MCP_URL='${LOCAL_URL}/api/terminals/mcp?workspace_id=${WORKSPACE_ID}'
export DEVIDE_PREVIEW_MCP_URL='${LOCAL_URL}/api/preview/mcp?workspace_id=${WORKSPACE_ID}'
export DEVIDE_ARTIFACT_MCP_URL='${LOCAL_URL}/api/artifacts/mcp?workspace_id=${WORKSPACE_ID}'
$( [[ -n "$TIDEWAVE_MCP_URL" ]] && printf "export DEVIDE_TIDEWAVE_MCP_URL='%s'\n" "$TIDEWAVE_MCP_URL" )
export DEVIDE_CHECKOUT='${ROOT}'
export DEVIDE_SCRIPTS='${ROOT}/scripts'
export DEVIDE_AGENT_MCP_HOME="\${HOME}/.devide/agent-mcp/${WORKSPACE_NAME}"
export CASEIN_NPM_PREFIX="\${CASEIN_NPM_PREFIX:-\${HOME}/.local/share/npm-global}"
export CASEIN_AGENT_BIN_DIR="\${CASEIN_AGENT_BIN_DIR:-\${HOME}/.devide/agent-shims}"
case ":\${PATH:-}:" in *":\${HOME}/.local/bin:"*) ;; *) export PATH="\${HOME}/.local/bin:\${PATH:-}" ;; esac
case ":\${PATH:-}:" in *":\${CASEIN_NPM_PREFIX}/bin:"*) ;; *) export PATH="\${CASEIN_NPM_PREFIX}/bin:\${PATH:-}" ;; esac
# Launcher shims last so they land frontmost: bare agent names in this shell
# must hit DevIDE MCP injection once this file is sourced.
case ":\${PATH:-}:" in *":\${CASEIN_AGENT_BIN_DIR}:"*) ;; *) export PATH="\${CASEIN_AGENT_BIN_DIR}:\${PATH:-}" ;; esac
EOF
chmod 600 "$AGENT_ENV"

log "wrote ${AGENT_ENV}"

ROOT="$ROOT" LOCAL_URL="$LOCAL_URL" materialize_all_workspaces
write_scoped_tokens_if_needed

source "${AGENT_ENV}"
python3 "${ROOT}/scripts/lib/merge-agent-mcp.py"

bash scripts/ensure-devbox-npm-prefix.sh
bash scripts/install-agent-shims.sh
bash scripts/refresh-tmux-pane-env.sh --workspace-prefix dalexandre

relaunch_current_release_if_needed

DEVIDE_URL="$LOCAL_URL" CASEIN_API_TOKEN="$AGENT_TOKEN" \
  WORKSPACE_ID="$WORKSPACE_ID" DEVIDE_WORKSPACE_NAME="$WORKSPACE_NAME" \
  bash scripts/verify_agent_pairing.sh

log "done"
