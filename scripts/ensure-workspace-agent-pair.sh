#!/usr/bin/env bash
#
# Ensure a product workspace's agent runtime(s) have DevIDE MCP + host skills.
#
# This is the mechanical half of the workspace-agent-pair skill: safe to run
# from any cwd on the milc devbox when the target workspace is already paired
# (staging under ~/.devide/agent-mcp/<name>/). Does not mint tokens — use
# scripts/refresh-devbox-agent-pairing.sh for first-time pairing.
#
# Usage:
#   # From a paired tmux session (env already set):
#   bash /path/to/dev_ide/scripts/ensure-workspace-agent-pair.sh
#
#   # Explicit workspace + runtime:
#   bash scripts/ensure-workspace-agent-pair.sh \
#     --workspace dalexandre-devbox --runtime opencode --verify
#
#   # All runtimes:
#   bash scripts/ensure-workspace-agent-pair.sh --workspace dalexandre-reports --runtime all
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/agent-skills.sh
source "${ROOT}/scripts/lib/agent-skills.sh"

WORKSPACE_NAME="${DEVIDE_WORKSPACE_NAME:-}"
WORKSPACE_EXPLICIT=0
RUNTIME="all"
VERIFY=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: ensure-workspace-agent-pair.sh [options]

Ensure DevIDE terminal/preview/artifact MCP + host infrastructure skills are
installed for a product workspace agent runtime.

Options:
  --workspace NAME   Workspace name (default: $DEVIDE_WORKSPACE_NAME)
  --runtime NAME     opencode | claude | grok | codex | all  (default: all)
  --verify           Probe terminal MCP tools/list + OpenCode skill/config when possible
  --quiet            Less chatter
  -h, --help         Show this help

Environment (usually from ~/.devide/agent-mcp/<name>/env.sh or tmux session):
  DEVIDE_WORKSPACE_NAME, DEVIDE_WORKSPACE_ID, DEVIDE_CHECKOUT,
  DEVIDE_AGENT_MCP_HOME, DEV_IDE_API_TOKEN, DEVIDE_*_MCP_URL

When --workspace is passed, ambient DEVIDE_AGENT_MCP_HOME / DEVIDE_CHECKOUT from
another workspace are ignored so a foreign shell cannot pair the wrong target.
EOF
}

log() {
  [[ "$QUIET" -eq 1 ]] && return 0
  printf '>>> %s\n' "$*"
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE_NAME="${2:-}"
      WORKSPACE_EXPLICIT=1
      shift 2
      ;;
    --runtime)
      RUNTIME="${2:-}"
      shift 2
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$RUNTIME" in
  opencode|claude|grok|codex|all) ;;
  *) die "unsupported --runtime '${RUNTIME}' (opencode|claude|grok|codex|all)" ;;
esac

[[ -n "$WORKSPACE_NAME" ]] || die "workspace name required (--workspace or DEVIDE_WORKSPACE_NAME)"

# Always key staging by workspace *name*. Prefer ambient DEVIDE_AGENT_MCP_HOME
# only when it already points at that name (session env). Never let a foreign
# shell's DEVIDE_AGENT_MCP_HOME override an explicit --workspace.
CANONICAL_STAGING="${HOME}/.devide/agent-mcp/${WORKSPACE_NAME}"
if [[ "$WORKSPACE_EXPLICIT" -eq 1 ]]; then
  STAGING="$CANONICAL_STAGING"
elif [[ -n "${DEVIDE_AGENT_MCP_HOME:-}" && "${DEVIDE_AGENT_MCP_HOME}" == *"/agent-mcp/${WORKSPACE_NAME}" ]]; then
  STAGING="${DEVIDE_AGENT_MCP_HOME}"
else
  STAGING="$CANONICAL_STAGING"
fi
ENV_SH="${STAGING}/env.sh"

if [[ -f "$ENV_SH" ]]; then
  # Drop foreign pairing vars before source so a wrong ambient checkout/token
  # cannot survive when --workspace selected a different staging tree.
  if [[ "$WORKSPACE_EXPLICIT" -eq 1 ]]; then
    unset DEVIDE_CHECKOUT DEVIDE_AGENT_MCP_HOME DEVIDE_WORKSPACE_ID DEV_IDE_API_TOKEN \
      DEVIDE_TERMINAL_MCP_URL DEVIDE_PREVIEW_MCP_URL DEVIDE_ARTIFACT_MCP_URL \
      DEVIDE_TMUX_SESSION DEVIDE_API_BASE_URL 2>/dev/null || true
  fi
  # shellcheck source=/dev/null
  set -a
  # shellcheck disable=SC1090
  source "$ENV_SH"
  set +a
  log "sourced ${ENV_SH}"
else
  die "missing ${ENV_SH} — run refresh/setup pairing for workspace '${WORKSPACE_NAME}' first"
fi

: "${DEVIDE_WORKSPACE_ID:?DEVIDE_WORKSPACE_ID missing after sourcing env.sh}"
: "${DEV_IDE_API_TOKEN:?DEV_IDE_API_TOKEN missing after sourcing env.sh}"
: "${DEVIDE_TERMINAL_MCP_URL:?DEVIDE_TERMINAL_MCP_URL missing after sourcing env.sh}"

# Guard: env.sh must describe the workspace we asked for.
if [[ "${DEVIDE_WORKSPACE_NAME:-}" != "$WORKSPACE_NAME" ]]; then
  die "env.sh workspace name '${DEVIDE_WORKSPACE_NAME:-}' != requested '${WORKSPACE_NAME}' (${ENV_SH})"
fi

CHECKOUT="${DEVIDE_CHECKOUT:-}"
if [[ -z "$CHECKOUT" || ! -d "$CHECKOUT" ]]; then
  if [[ -d "/data/workspaces/${WORKSPACE_NAME}" ]]; then
    CHECKOUT="/data/workspaces/${WORKSPACE_NAME}"
  else
    die "DEVIDE_CHECKOUT not set and /data/workspaces/${WORKSPACE_NAME} missing"
  fi
fi
export DEVIDE_CHECKOUT="$CHECKOUT"
export DEVIDE_AGENT_MCP_HOME="$STAGING"
export DEVIDE_WORKSPACE_NAME="$WORKSPACE_NAME"

# Host skills live in the dev_ide tree. Prefer this script's repo, then common
# checkouts, then release overlays if present.
skill_source_dir() {
  local candidate
  for candidate in \
    "${ROOT}/.claude/skills" \
    "/data/workspaces/dalexandre/dev_ide/.claude/skills" \
    "/opt/devide/deploy-build/.claude/skills" \
    "/opt/devide/release/lib/dev_ide-0.1.0/priv/claude/skills"
  do
    if [[ -d "${candidate}/preview-ui-walk" || -d "${candidate}/workspace-agent-pair" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # Fall back to ROOT even if incomplete — agent_skills_install skips missing.
  printf '%s\n' "${ROOT}/.claude/skills"
}

SKILL_SRC="$(skill_source_dir)"
log "skill source: ${SKILL_SRC}"
log "workspace: ${WORKSPACE_NAME} (${DEVIDE_WORKSPACE_ID})"
log "checkout: ${CHECKOUT}"
log "staging: ${STAGING}"

# Always keep host skills on Claude's global path — OpenCode auto-loads them as
# external skills, and Claude launches already stage there.
agent_skills_install "$SKILL_SRC" "${HOME}/.claude"
log "skills → ~/.claude/skills"

install_for_opencode() {
  agent_skills_install "$SKILL_SRC" "${HOME}/.config/opencode"
  mkdir -p "${CHECKOUT}/.opencode" 2>/dev/null || true
  agent_skills_install "$SKILL_SRC" "${CHECKOUT}/.opencode"
  if [[ -f "${STAGING}/opencode.json" ]]; then
    cp "${STAGING}/opencode.json" "${CHECKOUT}/.opencode/opencode.json"
    chmod 600 "${CHECKOUT}/.opencode/opencode.json"
    log "MCP → ${CHECKOUT}/.opencode/opencode.json"
  else
    echo "warn: missing ${STAGING}/opencode.json — rematerialize pairing" >&2
  fi
  # Prefer not dirtied product git status when the repo gitignores this path.
  if [[ -f "${CHECKOUT}/.opencode/.gitignore" ]] &&
    ! grep -qx 'opencode.json' "${CHECKOUT}/.opencode/.gitignore" 2>/dev/null; then
    printf '\n# DevIDE-injected workspace MCP (Bearer via env; do not commit)\nopencode.json\n' \
      >>"${CHECKOUT}/.opencode/.gitignore" || true
  fi
  log "skills → ~/.config/opencode/skills + ${CHECKOUT}/.opencode/skills"
}

install_for_claude() {
  # Owner profile if present, else global (already done above).
  local profile="${CLAUDE_CONFIG_DIR:-}"
  if [[ -z "$profile" && -n "${DEVIDE_WORKSPACE_NAME:-}" ]]; then
    local guess="${HOME}/.devide/agent-auth/profiles/${DEVIDE_WORKSPACE_NAME%%-*}/claude"
    # profiles are per-owner (dalexandre), not per-workspace — leave global.
    :
  fi
  if [[ -n "$profile" && -d "$profile" ]]; then
    agent_skills_install "$SKILL_SRC" "$profile"
    log "skills → ${profile}/skills"
  fi
  if [[ -f "${STAGING}/.mcp.json" ]]; then
    # Claude launch uses --mcp-config from staging; also drop a project copy for
    # agents that discover project .mcp.json.
    cp "${STAGING}/.mcp.json" "${CHECKOUT}/.mcp.json"
    chmod 600 "${CHECKOUT}/.mcp.json"
    log "MCP → ${CHECKOUT}/.mcp.json (Claude also uses staging --mcp-config)"
  fi
}

install_for_grok() {
  agent_skills_install "$SKILL_SRC" "${HOME}/.claude" # grok does not load skills the same way; no-op safety
  if [[ -f "${STAGING}/.mcp.json" ]]; then
    # Primary checkout injection is intentionally worktree-gated in the
    # launcher; still write when the user explicitly pairs so product agents
    # started via `opencode`-style primary flows can share the file.
    cp "${STAGING}/.mcp.json" "${CHECKOUT}/.mcp.json"
    chmod 600 "${CHECKOUT}/.mcp.json"
    log "MCP → ${CHECKOUT}/.mcp.json (Grok reads project .mcp.json)"
  fi
}

install_for_codex() {
  # Codex gets MCP via launch-time -c flags; ensure staging marker + env only.
  if [[ ! -d "${STAGING}/codex" ]]; then
    mkdir -p "${STAGING}/codex"
  fi
  log "Codex: use launch-devide-agent.sh codex (per-launch MCP flags); skills N/A"
}

case "$RUNTIME" in
  opencode) install_for_opencode ;;
  claude) install_for_claude ;;
  grok) install_for_grok ;;
  codex) install_for_codex ;;
  all)
    install_for_opencode
    install_for_claude
    install_for_grok
    install_for_codex
    ;;
esac

verify_terminal_mcp() {
  python3 - <<'PY'
import json, os, sys, urllib.request

url = os.environ.get("DEVIDE_TERMINAL_MCP_URL", "")
token = os.environ.get("DEV_IDE_API_TOKEN", "")
if not url or not token:
    print("verify: missing DEVIDE_TERMINAL_MCP_URL or DEV_IDE_API_TOKEN", file=sys.stderr)
    sys.exit(1)

def call(method, params=None, id=1, session=None):
    body = json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}).encode()
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
    }
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        sid = r.headers.get("Mcp-Session-Id") or session
        raw = r.read().decode()
    if raw.strip().startswith("{"):
        return json.loads(raw), sid
    for line in raw.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip()), sid
    return {"raw": raw[:300]}, sid

try:
    init, sid = call(
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "ensure-workspace-agent-pair", "version": "0"},
        },
    )
    tools, _ = call("tools/list", {}, 2, session=sid)
    names = [t.get("name") for t in ((tools.get("result") or {}).get("tools") or [])]
    print(f"verify: terminal MCP ok ({len(names)} tools)")
    if "terminal_list_sessions" not in names:
        print("verify: WARN terminal_list_sessions missing", file=sys.stderr)
        sys.exit(2)
except Exception as e:
    print(f"verify: terminal MCP failed: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

verify_opencode() {
  local real_bin="${HOME}/.opencode/bin/opencode"
  if [[ ! -x "$real_bin" ]]; then
    real_bin="$(command -v opencode 2>/dev/null || true)"
  fi
  # Prefer the real binary over the DevIDE shim (shim re-enters launch + worktree).
  if [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
    real_bin="${HOME}/.opencode/bin/opencode"
  elif [[ -L "${HOME}/.devide/real-bins/opencode" ]]; then
    real_bin="$(readlink -f "${HOME}/.devide/real-bins/opencode")"
  fi
  if [[ ! -x "$real_bin" ]]; then
    echo "verify: opencode binary not found — skip skill/config probe" >&2
    return 0
  fi

  local skill_out cfg_out
  skill_out="$(mktemp)"
  cfg_out="$(mktemp)"
  if ! (cd "$CHECKOUT" && timeout 30 "$real_bin" debug skill >"$skill_out" 2>/dev/null); then
    echo "verify: opencode debug skill failed" >&2
    rm -f "$skill_out" "$cfg_out"
    return 1
  fi
  if ! (cd "$CHECKOUT" && timeout 30 "$real_bin" debug config >"$cfg_out" 2>/dev/null); then
    echo "verify: opencode debug config failed" >&2
    rm -f "$skill_out" "$cfg_out"
    return 1
  fi
  python3 - "$skill_out" "$cfg_out" "$WORKSPACE_NAME" <<'PY'
import json, sys
skills = json.load(open(sys.argv[1]))
cfg = json.load(open(sys.argv[2]))
ws = sys.argv[3]
names = {s.get("name") for s in skills}
need = {"preview-ui-walk", "workspace-agent-pair", "delegate-to-grok"}
missing = sorted(need - names)
print(f"verify: opencode skills present={sorted(names & need)}")
if missing:
    print(f"verify: WARN missing skills {missing}", file=sys.stderr)
mcp = cfg.get("mcp") or {}
keys = [k for k in mcp if k.startswith("devide-")]
print(f"verify: opencode MCP servers={keys}")
matched = [k for k in keys if ws in k]
if not keys:
    print("verify: FAIL no devide-* MCP in opencode config", file=sys.stderr)
    sys.exit(1)
if not any("terminal" in k for k in keys):
    print("verify: FAIL no terminal MCP server", file=sys.stderr)
    sys.exit(1)
if not matched:
    print(f"verify: WARN MCP servers do not mention workspace name {ws!r}: {keys}", file=sys.stderr)
print("verify: opencode config ok")
PY
  local rc=$?
  rm -f "$skill_out" "$cfg_out"
  return "$rc"
}

if [[ "$VERIFY" -eq 1 ]]; then
  log "verifying…"
  verify_terminal_mcp
  case "$RUNTIME" in
    opencode|all) verify_opencode || true ;;
  esac
fi

cat <<EOF

ok: workspace agent pair ready
  workspace:  ${WORKSPACE_NAME}
  checkout:   ${CHECKOUT}
  staging:    ${STAGING}
  runtime:    ${RUNTIME}
  skills:     ${DEVIDE_GLOBAL_AGENT_SKILLS}

Next:
  source ${ENV_SH}
  cd ${CHECKOUT}
  # OpenCode (restart existing sessions so config reloads):
  opencode
  # or Claude / Grok / Codex via:
  #   bash ${ROOT}/scripts/launch-devide-agent.sh <runtime>

Host skills now available: preview-ui-walk, delegate-to-grok, workspace-agent-pair
EOF
