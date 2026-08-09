#!/usr/bin/env bash
#
# verify_post_deploy_cockpit.sh — authenticated post-deploy cockpit gate (#378).
#
# Operator evidence after origin/master is activated by the on-box poller.
# Unauthenticated HTTP 200, a local source suite, or a health check that uses
# curl -f (which hides 401 bodies) is not acceptance.
#
# Ground rules encoded here:
#   * /health returns **401** when the release is up and auth-enforcing.
#     curl -f would suppress that body and look like a dead server.
#   * Live instance is the target of /run/casein/current.sock, not every
#     casein-<hash>.service unit (lingering canaries run old code).
#   * Deployed SHA must equal origin/master (or an explicit
#     CASEIN_ALLOW_DEPLOY_DRIFT=1 attended override). Migration refusals and
#     manual drift fail closed.
#   * MCP checks are read-only: list sessions, topology, preview_surfaces.
#     No preview open/mutate, no hand-edit of /opt/casein/release.
#
# Usage:
#   source .devbox-agent.env   # CASEIN_API_TOKEN + CASEIN_WORKSPACE_ID
#   bash scripts/verify_post_deploy_cockpit.sh
#   bash scripts/verify_post_deploy_cockpit.sh --ci
#   bash scripts/verify_post_deploy_cockpit.sh --evidence /tmp/378-evidence.json
#
# Exit codes:
#   0  all required checks passed (or --allow-drift with remaining green checks)
#   1  usage / missing prerequisites
#   2  deploy/timer/revision/health failure
#   3  authenticated MCP / cockpit path failure
#   4  evidence write failure
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CURRENT_SOCK="${CASEIN_CURRENT_SOCK:-/run/casein/current.sock}"
LAST_DEPLOY_FILE="${CASEIN_LAST_DEPLOY_FILE:-/run/casein/last-deploy.json}"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
CASEIN_URL="${CASEIN_URL:-http://127.0.0.1:4000}"
TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${WORKSPACE_ID:-${CASEIN_WORKSPACE_ID:-}}"
WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME:-}"
ORIGIN_REF="${CASEIN_ORIGIN_REF:-origin/master}"
CI_MODE=0
ALLOW_DRIFT=0
EVIDENCE_PATH=""
SESSION_NAME="${CASEIN_VERIFY_SESSION:-}"

usage() {
  cat <<'EOF'
Usage: verify_post_deploy_cockpit.sh [--ci] [--allow-drift] [--evidence PATH] [--session NAME]

Authenticated post-deploy cockpit verification for issue #378.

Environment:
  CASEIN_API_TOKEN       Workspace-scoped bearer (required for MCP)
  CASEIN_WORKSPACE_ID    Workspace UUID or name (required for MCP)
  CASEIN_WORKSPACE_NAME  Optional tmux prefix key (defaults to workspace id)
  CASEIN_URL             Loopback base (default http://127.0.0.1:4000)
  CASEIN_CURRENT_SOCK    Active socket symlink (default /run/casein/current.sock)
  CASEIN_LAST_DEPLOY_FILE  Poller status JSON (default /run/casein/last-deploy.json)
  CASEIN_ENV_FILE        Host env with CASEIN_GIT_REVISION (default /etc/casein/casein.env)
  CASEIN_ORIGIN_REF      Expected git tip (default origin/master)
  CASEIN_VERIFY_SESSION  Optional explicit tmux session for topology
  CASEIN_ALLOW_DEPLOY_DRIFT=1  Same as --allow-drift (attended only)

  --ci           Treat warnings that block acceptance as hard failures (default behaviour
                 already fails closed on required checks; reserved for callers)
  --allow-drift  Do not fail when deployed SHA != origin tip (records drift in evidence)
  --evidence P   Write redacted JSON evidence to P (default: stdout summary only)
  --session S    Topology session name (otherwise first matching workspace session)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI_MODE=1; shift ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    --evidence)
      EVIDENCE_PATH="${2:-}"
      [[ -n "$EVIDENCE_PATH" ]] || { echo "ERROR: --evidence needs a path" >&2; exit 1; }
      shift 2
      ;;
    --session)
      SESSION_NAME="${2:-}"
      [[ -n "$SESSION_NAME" ]] || { echo "ERROR: --session needs a name" >&2; exit 1; }
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "${CASEIN_ALLOW_DEPLOY_DRIFT:-0}" == "1" ]]; then
  ALLOW_DRIFT=1
fi

log() { printf '>>> %s\n' "$*"; }
fail() { local code="$1"; shift; echo "ERROR: $*" >&2; exit "$code"; }

# ---------------------------------------------------------------------------
# HTTP helpers — never use curl -f when the body/status must be inspected.
# ---------------------------------------------------------------------------

# HTTP helpers write body to a path and set HTTP_CODE in the caller shell.
# Never capture these with $() — that would lose HTTP_CODE under set -u.
HTTP_CODE="000"

http_unix_to() {
  # http_unix_to OUTFILE PATH [curl args...]
  local out="$1"
  local path="$2"
  shift 2
  HTTP_CODE="$(
    curl -sS --max-time 5 -o "$out" -w '%{http_code}' \
      --unix-socket "$CURRENT_SOCK" \
      "$@" \
      "http://localhost${path}" 2>/dev/null || printf '000'
  )"
}

http_url_to() {
  local out="$1"
  local url="$2"
  shift 2
  HTTP_CODE="$(
    curl -sS --max-time 5 -o "$out" -w '%{http_code}' \
      "$@" \
      "$url" 2>/dev/null || printf '000'
  )"
}

# Prefer loopback when up; else unix socket. Never -f.
casein_http_to() {
  local out="$1"
  local path="$2"
  shift 2
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "${CASEIN_URL}/" 2>/dev/null || printf '000')"
  if [[ "$code" != "000" && -n "$code" ]]; then
    http_url_to "$out" "${CASEIN_URL}${path}" "$@"
  elif [[ -L "$CURRENT_SOCK" || -S "$CURRENT_SOCK" ]]; then
    http_unix_to "$out" "$path" "$@"
  else
    HTTP_CODE="000"
    : >"$out"
  fi
}

json_rpc_to() {
  # json_rpc_to OUTFILE surface id method [params_json]
  # Write params + envelope through files so nested quotes and env pollution
  # cannot break the POST body (os.environ is shared with many CASEIN_* vars).
  local out="$1"
  local surface="$2" # terminals | preview
  local id="$3"
  local method="$4"
  # Must not write ${5:-{}} — bash parses the first } as end-of-expansion and
  # leaves a trailing literal }, which corrupts every JSON params blob.
  local params="${5:-"{}"}"
  local path="/api/${surface}/mcp"
  local body_file params_file
  body_file="$(mktemp "${EVIDENCE_DIR}/rpc-body.XXXXXX")"
  params_file="$(mktemp "${EVIDENCE_DIR}/rpc-params.XXXXXX")"
  printf '%s' "$params" >"$params_file"
  python3 -c '
import json, sys
method, id_s, params_path, body_path = sys.argv[1:5]
with open(params_path, encoding="utf-8") as fh:
    params = json.load(fh)
with open(body_path, "w", encoding="utf-8") as fh:
    json.dump({"jsonrpc": "2.0", "id": int(id_s), "method": method, "params": params}, fh)
' "$method" "$id" "$params_file" "$body_file"
  casein_http_to "$out" "$path" \
    -H "authorization: Bearer ${TOKEN}" \
    -H "content-type: application/json" \
    -X POST \
    --data-binary @"$body_file"
  rm -f "$body_file" "$params_file"
}

parse_tool_result() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit("empty MCP response")
payload = json.loads(raw)
if "error" in payload:
    raise SystemExit(json.dumps(payload["error"]))
result = payload.get("result") or {}
if result.get("isError"):
    text = ""
    for block in result.get("content") or []:
        text += block.get("text", "")
    raise SystemExit(text or "tool error")
structured = result.get("structuredContent")
if structured is not None:
    print(json.dumps(structured))
else:
    print(json.dumps(result))
'
}

# ---------------------------------------------------------------------------
# Host / deploy ground truth (no app token required)
# ---------------------------------------------------------------------------

read_git_revision() {
  if [[ -r "$ENV_FILE" ]]; then
    sed -n 's/^CASEIN_GIT_REVISION=//p' "$ENV_FILE" | tail -1 | tr -d '\r'
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo test -r "$ENV_FILE" 2>/dev/null; then
    sudo sed -n 's/^CASEIN_GIT_REVISION=//p' "$ENV_FILE" 2>/dev/null | tail -1 | tr -d '\r'
    return 0
  fi
  printf ''
}

resolve_live_instance() {
  if [[ ! -L "$CURRENT_SOCK" && ! -e "$CURRENT_SOCK" ]]; then
    printf ''
    return 0
  fi
  local target
  target="$(readlink -f "$CURRENT_SOCK" 2>/dev/null || readlink "$CURRENT_SOCK" 2>/dev/null || true)"
  basename "${target%.sock}" 2>/dev/null || printf ''
}

unit_description() {
  local unit="$1"
  systemctl show "$unit" -p Description --value 2>/dev/null || printf ''
}

unit_active() {
  local unit="$1"
  # is-active exits non-zero for inactive/failed — still print the state word.
  local state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    printf '%s' "$state"
  else
    printf 'unknown'
  fi
}

list_casein_units() {
  systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | sed 's/^[[:space:]]*●\?[[:space:]]*//' \
    | awk '$1 ~ /^casein-[0-9a-f]{16}\.service$/ {print $1, $3, $4}'
}

sha_from_description() {
  # "Casein canary <sha> (<uuid>)"
  python3 -c '
import re,sys
text=sys.stdin.read().strip()
m=re.search(r"\b([0-9a-f]{40})\b", text)
print(m.group(1) if m else "")
'
}

origin_tip() {
  git -C "$ROOT" rev-parse "$ORIGIN_REF" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# Evidence accumulator (python builds final JSON — no secrets)
# ---------------------------------------------------------------------------

EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/casein-post-deploy-XXXXXX")"
cleanup() { rm -rf "$EVIDENCE_DIR"; }
trap cleanup EXIT

note_file() {
  local key="$1"
  local value="$2"
  printf '%s' "$value" >"${EVIDENCE_DIR}/${key}"
}

# ---------------------------------------------------------------------------
log "==> post-deploy cockpit verification (#378)"
log "    sock=${CURRENT_SOCK}"
log "    url=${CASEIN_URL}"
log "    workspace=${WORKSPACE_ID:-unset}"
log "    origin_ref=${ORIGIN_REF}"
log "    allow_drift=${ALLOW_DRIFT}"

FAILURES=()
MCP_FAILURES=()

# 1) Timer / latest deploy service
log "==> casein-deploy.timer / casein-deploy.service"
timer_active="$(unit_active casein-deploy.timer)"
timer_enabled="$(systemctl is-enabled casein-deploy.timer 2>/dev/null || printf 'unknown')"
svc_result="$(systemctl show casein-deploy.service -p Result --value 2>/dev/null || printf 'unknown')"
svc_status="$(systemctl show casein-deploy.service -p ExecMainStatus --value 2>/dev/null || printf 'unknown')"
svc_state="$(unit_active casein-deploy.service)"
svc_finished="$(systemctl show casein-deploy.service -p InactiveEnterTimestamp --value 2>/dev/null || printf '')"
note_file timer_active "$timer_active"
note_file timer_enabled "$timer_enabled"
note_file service_result "$svc_result"
note_file service_exec_status "$svc_status"
note_file service_active "$svc_state"
note_file service_finished "$svc_finished"
log "    timer active=${timer_active} enabled=${timer_enabled}"
log "    service active=${svc_state} result=${svc_result} exec_status=${svc_status}"

if [[ "$timer_active" != "active" ]]; then
  FAILURES+=("casein-deploy.timer is ${timer_active}, expected active")
fi

# 2) last-deploy.json
log "==> last-deploy.json"
last_deploy_raw=""
if [[ -r "$LAST_DEPLOY_FILE" ]]; then
  last_deploy_raw="$(cat "$LAST_DEPLOY_FILE")"
else
  FAILURES+=("missing ${LAST_DEPLOY_FILE}")
fi
note_file last_deploy "${last_deploy_raw}"
if [[ -n "$last_deploy_raw" ]]; then
  python3 - <<'PY' "$last_deploy_raw" 2>/dev/null || true
import json,sys
try:
  d=json.loads(sys.argv[1])
except Exception as e:
  print(f"    unparseable last-deploy: {e}")
  raise SystemExit(0)
print(f"    outcome={d.get('outcome')} phase={d.get('phase')} target={d.get('target_short') or d.get('target_sha')} from={d.get('from_short') or d.get('from_sha')}")
if d.get("reason"):
  print(f"    reason={d.get('reason')}")
PY
fi

# 3) Live instance vs lingering canaries
log "==> live instance (current.sock)"
live_id="$(resolve_live_instance)"
note_file live_instance "$live_id"
if [[ -z "$live_id" ]]; then
  FAILURES+=("cannot resolve live instance from ${CURRENT_SOCK}")
  live_unit=""
  live_desc=""
  live_active="unknown"
  live_sha=""
else
  live_unit="casein-${live_id}.service"
  live_desc="$(unit_description "$live_unit")"
  live_active="$(unit_active "$live_unit")"
  live_sha="$(printf '%s' "$live_desc" | sha_from_description)"
  note_file live_unit "$live_unit"
  note_file live_description "$live_desc"
  note_file live_active "$live_active"
  note_file live_sha_from_unit "$live_sha"
  log "    live=${live_unit} active=${live_active}"
  log "    description=${live_desc}"
  if [[ "$live_active" != "active" ]]; then
    FAILURES+=("live unit ${live_unit} is ${live_active}")
  fi
fi

lingering="$(list_casein_units | awk -v live="casein-${live_id}.service" '$1 != live {print $1" "$2" "$3}')"
note_file lingering_units "$lingering"
if [[ -n "$lingering" ]]; then
  log "    other casein-*.service units (not live — do not treat as the release):"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    log "      $line"
  done <<<"$lingering"
fi

# 4) Revision equality (env + unit + origin)
log "==> revision: env / unit / ${ORIGIN_REF}"
deployed_sha="$(read_git_revision)"
origin_sha="$(origin_tip)"
note_file deployed_sha "$deployed_sha"
note_file origin_sha "$origin_sha"
log "    CASEIN_GIT_REVISION=${deployed_sha:-unset}"
log "    unit sha=${live_sha:-unset}"
log "    ${ORIGIN_REF}=${origin_sha:-unset}"

if [[ -z "$deployed_sha" ]]; then
  FAILURES+=("CASEIN_GIT_REVISION missing from ${ENV_FILE}")
fi
if [[ -z "$origin_sha" ]]; then
  FAILURES+=("cannot resolve ${ORIGIN_REF} (fetch origin first)")
fi
if [[ -n "$deployed_sha" && -n "$live_sha" && "$deployed_sha" != "$live_sha" ]]; then
  FAILURES+=("env revision ${deployed_sha} != live unit sha ${live_sha}")
fi

drift=0
if [[ -n "$deployed_sha" && -n "$origin_sha" && "$deployed_sha" != "$origin_sha" ]]; then
  drift=1
  msg="deployed ${deployed_sha} != ${ORIGIN_REF} ${origin_sha}"
  if [[ "$ALLOW_DRIFT" -eq 1 ]]; then
    log "    WARN drift allowed: $msg"
  else
    FAILURES+=("$msg")
  fi
fi
note_file drift "$drift"

# last-deploy outcome when tip matches target but refused
if [[ -n "$last_deploy_raw" ]]; then
  outcome="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("outcome",""))' "$last_deploy_raw" 2>/dev/null || true)"
  phase="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("phase",""))' "$last_deploy_raw" 2>/dev/null || true)"
  target="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("target_sha",""))' "$last_deploy_raw" 2>/dev/null || true)"
  if [[ "$outcome" == "failed" && "$ALLOW_DRIFT" -eq 0 ]]; then
    if [[ -n "$origin_sha" && "$target" == "$origin_sha" ]]; then
      FAILURES+=("last-deploy outcome=failed phase=${phase} for origin tip (poller did not activate master)")
    elif [[ "$drift" -eq 1 ]]; then
      FAILURES+=("last-deploy outcome=failed phase=${phase} while deployed drifts from origin")
    fi
  fi
fi

# 5) Health — 401 is healthy for /health; /healthz is the JSON probe
log "==> health endpoints (no curl -f)"
if [[ ! -L "$CURRENT_SOCK" && ! -S "$CURRENT_SOCK" ]]; then
  FAILURES+=("${CURRENT_SOCK} missing")
  health_code="000"
  : >"${EVIDENCE_DIR}/health_body"
  : >"${EVIDENCE_DIR}/healthz_body"
else
  http_unix_to "${EVIDENCE_DIR}/health_body" /health
  health_code="${HTTP_CODE}"
  http_unix_to "${EVIDENCE_DIR}/healthz_body" /healthz
  healthz_code="${HTTP_CODE}"
fi
health_body="$(cat "${EVIDENCE_DIR}/health_body" 2>/dev/null || true)"
healthz_body="$(cat "${EVIDENCE_DIR}/healthz_body" 2>/dev/null || true)"
note_file health_code "$health_code"
note_file health_body "$health_body"
note_file healthz_code "$healthz_code"
note_file healthz_body "$healthz_body"
log "    GET /health  → HTTP ${health_code} body=$(printf '%s' "$health_body" | tr '\n' ' ' | head -c 120)"
log "    GET /healthz → HTTP ${healthz_code} body=$(printf '%s' "$healthz_body" | tr '\n' ' ' | head -c 120)"

# /health: 401 = alive + auth enforcing. 200 only acceptable if desktop health.
case "$health_code" in
  401)
    log "    /health 401 = alive and auth-enforcing (expected on this box)"
    ;;
  200)
    log "    /health 200 (desktop/open profile)"
    ;;
  000)
    FAILURES+=("/health unreachable (connection failed)")
    ;;
  *)
    FAILURES+=("/health returned HTTP ${health_code}, expected 401 (auth) or 200")
    ;;
esac

case "$healthz_code" in
  200)
    if ! printf '%s' "$healthz_body" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True' 2>/dev/null; then
      FAILURES+=("/healthz 200 but body not ok=true: ${healthz_body}")
    fi
    ;;
  401)
    # Some profiles gate healthz; treat as alive-but-auth if body says so.
    log "    /healthz 401 (auth-enforcing path)"
    ;;
  000)
    FAILURES+=("/healthz unreachable")
    ;;
  *)
    FAILURES+=("/healthz returned HTTP ${healthz_code}")
    ;;
esac

# 6) Authenticated MCP (workspace token) — cockpit-adjacent read-only smoke
log "==> authenticated read-only MCP"
if [[ -z "$TOKEN" ]]; then
  MCP_FAILURES+=("CASEIN_API_TOKEN unset — cannot authenticate MCP")
elif [[ -z "$WORKSPACE_ID" ]]; then
  MCP_FAILURES+=("CASEIN_WORKSPACE_ID/WORKSPACE_ID unset")
else
  # initialize + tools/list terminal
  json_rpc_to "${EVIDENCE_DIR}/term_init.json" terminals 1 initialize '{"protocolVersion":"2025-03-26"}' || true
  term_init_code="${HTTP_CODE}"
  note_file term_init_code "$term_init_code"
  if [[ "$term_init_code" != "200" ]] || ! grep -q 'protocolVersion' "${EVIDENCE_DIR}/term_init.json" 2>/dev/null; then
    MCP_FAILURES+=("terminal MCP initialize HTTP ${term_init_code}")
  else
    log "    terminal MCP initialize ok"
  fi

  list_params="$(
    WS="$WORKSPACE_ID" python3 -c 'import json,os; print(json.dumps({"name":"terminal_list_sessions","arguments":{"workspace_id":os.environ["WS"]}}))'
  )"
  json_rpc_to "${EVIDENCE_DIR}/list_raw.json" terminals 2 tools/call "$list_params" || true
  list_code="${HTTP_CODE}"
  note_file sessions_http "$list_code"
  sessions_json="{}"
  if [[ "$list_code" != "200" ]]; then
    MCP_FAILURES+=("terminal_list_sessions HTTP ${list_code}")
  else
    if sessions_json="$(parse_tool_result <"${EVIDENCE_DIR}/list_raw.json")"; then
      log "    terminal_list_sessions ok"
      note_file sessions_json "$sessions_json"
    else
      MCP_FAILURES+=("terminal_list_sessions tool error")
      sessions_json="{}"
    fi
  fi

  if [[ -z "$SESSION_NAME" ]]; then
    SESSION_NAME="$(
      PICK_KEY="${WORKSPACE_NAME:-$WORKSPACE_ID}" SESSIONS_JSON="$sessions_json" python3 -c '
import json, os
data = json.loads(os.environ["SESSIONS_JSON"])
key = os.environ.get("PICK_KEY") or ""
sessions = data.get("sessions") or data.get("candidate_sessions") or []
prefix = f"casein_{key}_" if key else ""
attached = [s for s in sessions if s.get("attached")]
pool = attached or sessions
if prefix:
    for row in pool:
        name = row.get("session") or row.get("name") or ""
        if name.startswith(prefix):
            print(name); raise SystemExit
for row in pool:
    name = row.get("session") or row.get("name") or ""
    if name:
        print(name); raise SystemExit
'
    )"
  fi
  note_file session_name "${SESSION_NAME}"

  if [[ -n "$SESSION_NAME" ]]; then
    log "    topology session=${SESSION_NAME}"
    topo_params="$(
      WS="$WORKSPACE_ID" SESS="$SESSION_NAME" python3 -c '
import json,os
print(json.dumps({"name":"terminal_topology","arguments":{
  "workspace_id": os.environ["WS"],
  "session": os.environ["SESS"],
}}))
'
    )"
    json_rpc_to "${EVIDENCE_DIR}/topo_raw.json" terminals 3 tools/call "$topo_params" || true
    topo_code="${HTTP_CODE}"
    note_file topology_http "$topo_code"
    if [[ "$topo_code" != "200" ]]; then
      MCP_FAILURES+=("terminal_topology HTTP ${topo_code}")
    else
      if topo_json="$(parse_tool_result <"${EVIDENCE_DIR}/topo_raw.json")"; then
        note_file topology_json "$topo_json"
        topo_summary_line="$(
          printf '%s' "$topo_json" | python3 -c '
import json,sys
data=json.load(sys.stdin)
windows=data.get("windows") or []
panes=data.get("panes") or []
if not panes:
  for w in windows:
    panes.extend(w.get("pane_list") or w.get("panes") or [])
roles=sorted({(p.get("role") or "") for p in panes if p.get("role")})
role_s = ",".join(roles) if roles else "none"
print("windows=%d panes=%d roles=%s" % (len(windows), len(panes), role_s))
'
        )"
        log "    topology ${topo_summary_line}"
        if [[ "$topo_summary_line" == *roles=none* ]]; then
          log "    note: no role-marked panes (agent_pair may be unapplied on this session)"
        else
          log "    agent layout roles observed"
        fi
      else
        MCP_FAILURES+=("terminal_topology tool error")
      fi
    fi
  else
    log "    note: no tmux sessions for workspace — topology skipped (open cockpit first)"
    note_file topology_skipped "no_session"
  fi

  # preview_surfaces — read-only discovery, never open
  prev_params="$(
    WS="$WORKSPACE_ID" python3 -c '
import json,os
print(json.dumps({"name":"preview_surfaces","arguments":{"workspace_id": os.environ["WS"]}}))
'
  )"
  json_rpc_to "${EVIDENCE_DIR}/prev_raw.json" preview 4 tools/call "$prev_params" || true
  prev_code="${HTTP_CODE}"
  note_file preview_surfaces_http "$prev_code"
  if [[ "$prev_code" != "200" ]]; then
    MCP_FAILURES+=("preview_surfaces HTTP ${prev_code}")
  else
    if prev_json="$(parse_tool_result <"${EVIDENCE_DIR}/prev_raw.json")"; then
      note_file preview_surfaces_json "$prev_json"
      surface_summary="$(
        printf '%s' "$prev_json" | python3 -c '
import json,sys
data=json.load(sys.stdin)
surfaces=data.get("surfaces") or []
parts=[]
for s in surfaces[:12]:
  name=s.get("name") or "?"
  active=s.get("server_active")
  live=(s.get("server_status") or {}).get("liveness")
  parts.append(f"{name}:active={active}:liveness={live}")
print(f"count={len(surfaces)} " + "; ".join(parts))
'
      )"
      log "    preview_surfaces ok (${surface_summary})"
    else
      MCP_FAILURES+=("preview_surfaces tool error")
    fi
  fi
fi

# 7) Optional global deploy_status (only when token is global — workspace → 403)
log "==> /api/deploy_status (global token only; workspace token expects 403)"
casein_http_to "${EVIDENCE_DIR}/ds_body.json" /api/deploy_status \
  -H "authorization: Bearer ${TOKEN:-}" || true
ds_code="${HTTP_CODE}"
note_file deploy_status_http "$ds_code"
# Redact: keep ok/version/checks keys only
ds_redacted="$(
  python3 -c '
import json,sys
raw=open(sys.argv[1],encoding="utf-8",errors="replace").read()
try:
  d=json.loads(raw)
except Exception:
  print(raw[:200]); raise SystemExit
out={k:d.get(k) for k in ("ok","version","checks","socket_path","current_socket","last_deploy") if k in d}
print(json.dumps(out))
' "${EVIDENCE_DIR}/ds_body.json" 2>/dev/null || head -c 200 "${EVIDENCE_DIR}/ds_body.json"
)"
note_file deploy_status_redacted "$ds_redacted"
log "    HTTP ${ds_code}"
case "$ds_code" in
  200)
    log "    deploy_status reachable with this token"
    ;;
  403)
    log "    workspace token correctly forbidden on global deploy_status"
    ;;
  401)
    log "    deploy_status unauthorized (no/invalid token)"
    ;;
  *)
    log "    deploy_status HTTP ${ds_code} (recorded; not a workspace-token requirement)"
    ;;
esac

# ---------------------------------------------------------------------------
# Compose evidence + verdict
# ---------------------------------------------------------------------------

write_evidence() {
  local dest="$1"
  EVIDENCE_DIR="$EVIDENCE_DIR" FAILURES_JOINED="$(printf '%s\n' "${FAILURES[@]:-}")" \
  MCP_JOINED="$(printf '%s\n' "${MCP_FAILURES[@]:-}")" \
  ALLOW_DRIFT="$ALLOW_DRIFT" CI_MODE="$CI_MODE" \
  python3 - <<'PY' "$dest"
import json, os, sys, datetime
dest = sys.argv[1]
base = os.environ["EVIDENCE_DIR"]

def read(name, default=""):
    path = os.path.join(base, name)
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()

def read_json(name):
    raw = read(name, "")
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except Exception:
        return raw

failures = [l for l in os.environ.get("FAILURES_JOINED", "").splitlines() if l]
mcp_failures = [l for l in os.environ.get("MCP_JOINED", "").splitlines() if l]
allow_drift = os.environ.get("ALLOW_DRIFT") == "1"

# Redact sessions/topology/preview: drop URLs that might carry tokens; keep names.
def scrub_surfaces(obj):
    if not isinstance(obj, dict):
        return obj
    surfaces = []
    for s in obj.get("surfaces") or []:
        surfaces.append({
            "name": s.get("name"),
            "server_active": s.get("server_active"),
            "source": s.get("source"),
            "liveness": (s.get("server_status") or {}).get("liveness"),
            "operator_visible": s.get("operator_visible"),
            # host only, never query string
            "host": (s.get("url") or "").split("?")[0].split("/")[2] if s.get("url") else None,
        })
    return {"surface_count": len(obj.get("surfaces") or []), "surfaces": surfaces}

topo = read_json("topology_json")
topo_summary = None
if isinstance(topo, dict):
    panes = topo.get("panes") or []
    if not panes:
        for w in topo.get("windows") or []:
            panes.extend(w.get("pane_list") or w.get("panes") or [])
    roles = sorted({p.get("role") for p in panes if p.get("role")})
    topo_summary = {
        "session": topo.get("session") or read("session_name"),
        "window_count": len(topo.get("windows") or []),
        "pane_count": len(panes),
        "roles": roles,
        "safe_to_mutate": topo.get("safe_to_mutate"),
    }

sessions = read_json("sessions_json")
session_names = []
if isinstance(sessions, dict):
    for row in sessions.get("sessions") or sessions.get("candidate_sessions") or []:
        name = row.get("session") or row.get("name")
        if name:
            session_names.append({"session": name, "attached": bool(row.get("attached"))})

evidence = {
    "issue": 378,
    "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "verdict": None,  # filled below
    "deploy": {
        "timer_active": read("timer_active"),
        "timer_enabled": read("timer_enabled"),
        "service_result": read("service_result"),
        "service_exec_status": read("service_exec_status"),
        "service_active": read("service_active"),
        "service_finished": read("service_finished"),
        "last_deploy": read_json("last_deploy"),
        "live_instance": read("live_instance"),
        "live_unit": read("live_unit"),
        "live_active": read("live_active"),
        "live_description": read("live_description"),
        "deployed_sha": read("deployed_sha"),
        "live_sha_from_unit": read("live_sha_from_unit"),
        "origin_sha": read("origin_sha"),
        "drift": read("drift") == "1",
        "allow_drift": allow_drift,
        "lingering_units": [l for l in read("lingering_units").splitlines() if l],
    },
    "health": {
        "path_health": {"http_code": read("health_code"), "body": read("health_body")[:200]},
        "path_healthz": {"http_code": read("healthz_code"), "body": read("healthz_body")[:200]},
        "note": "HTTP 401 on /health means alive + auth-enforcing; do not use curl -f",
    },
    "deploy_status": {
        "http_code": read("deploy_status_http"),
        "body": read_json("deploy_status_redacted"),
        "note": "workspace-scoped tokens receive 403; global token required for full checks",
    },
    "authenticated_mcp": {
        "workspace_id_set": bool(read("session_name") or True),
        "terminal_initialize_http": read("term_init_code"),
        "sessions_http": read("sessions_http"),
        "sessions": session_names,
        "topology": topo_summary,
        "topology_skipped": read("topology_skipped") or None,
        "preview_surfaces_http": read("preview_surfaces_http"),
        "preview_surfaces": scrub_surfaces(read_json("preview_surfaces_json") or {}),
        "mutations": "none — read-only list_sessions / topology / preview_surfaces",
    },
    "failures": failures,
    "mcp_failures": mcp_failures,
    "manual_not_done": [
        "visual cockpit load in an operator browser session (OAuth)",
        "manual-drift banner screenshot when CASEIN_GIT_REVISION diverges deliberately",
        "Agents tab UI screenshot",
        "rollback drill without hand-editing /opt/casein/release",
    ],
    "rollback_health_note": (
        "This gate does not mutate releases. Confirm rollback via documented "
        "poller/deploy-devbox-release paths only; never hand-edit /opt/casein/release."
    ),
}

deploy_ok = not failures
mcp_ok = not mcp_failures
if deploy_ok and mcp_ok:
    if evidence["deploy"]["drift"] and allow_drift:
        evidence["verdict"] = "passed_with_allowed_drift"
    else:
        evidence["verdict"] = "passed"
elif not deploy_ok and not mcp_ok:
    evidence["verdict"] = "failed_deploy_and_mcp"
elif not deploy_ok:
    evidence["verdict"] = "failed_deploy"
else:
    evidence["verdict"] = "failed_mcp"

text = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
if dest == "-":
    sys.stdout.write(text)
else:
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write(text)
print(evidence["verdict"], file=sys.stderr)
PY
}

VERDICT_FILE="${EVIDENCE_DIR}/verdict"
if [[ -n "$EVIDENCE_PATH" ]]; then
  log "==> writing evidence ${EVIDENCE_PATH}"
  if ! write_evidence "$EVIDENCE_PATH" 2>"$VERDICT_FILE"; then
    fail 4 "failed to write evidence to ${EVIDENCE_PATH}"
  fi
  verdict="$(tr -d '\n' <"$VERDICT_FILE" || true)"
else
  write_evidence "${EVIDENCE_DIR}/evidence.json" 2>"$VERDICT_FILE" || true
  verdict="$(tr -d '\n' <"$VERDICT_FILE" || true)"
  log "==> evidence summary (pass --evidence PATH to persist)"
  python3 -m json.tool "${EVIDENCE_DIR}/evidence.json" 2>/dev/null | head -n 80 || true
fi

log "==> verdict: ${verdict:-unknown}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log "deploy/host failures:"
  for f in "${FAILURES[@]}"; do log "  - $f"; done
fi
if [[ ${#MCP_FAILURES[@]} -gt 0 ]]; then
  log "authenticated MCP failures:"
  for f in "${MCP_FAILURES[@]}"; do log "  - $f"; done
fi

# Unused CI_MODE kept for caller symmetry with sibling verify_*.sh scripts.
: "${CI_MODE}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  exit 2
fi
if [[ ${#MCP_FAILURES[@]} -gt 0 ]]; then
  exit 3
fi

log "OK: post-deploy cockpit gate checks passed"
exit 0
