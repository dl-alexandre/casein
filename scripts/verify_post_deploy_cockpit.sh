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
#   * Identity proof: socket peer pid == unit MainPID == heartbeat pid, and
#     heartbeat version == CASEIN_GIT_REVISION / unit description SHA.
#     A verifier that only checks "something answered" is worse than none.
#   * Deployed SHA must equal origin/master (or an explicit
#     CASEIN_ALLOW_DEPLOY_DRIFT=1 attended override). Migration refusals and
#     manual drift fail closed.
#   * MCP checks are read-only: list sessions, topology, preview_surfaces.
#     No preview open/mutate, no hand-edit of /opt/casein/release.
#   * Evidence always lists human_remaining[] (OAuth cockpit / Agents /
#     drift-banner / rollback drill). Those are never auto-closed.
#
# Modes:
#   (default)   Live host probe via current.sock + systemd + MCP.
#   --fixture D Hermetic dry-run from a fixture directory (CI / unit tests).
#               Never contacts the live release. Fail-closed on the same
#               contracts; does not false-green deploy drift.
#
# Usage:
#   source .devbox-agent.env   # CASEIN_API_TOKEN + CASEIN_WORKSPACE_ID
#   bash scripts/verify_post_deploy_cockpit.sh
#   bash scripts/verify_post_deploy_cockpit.sh --ci
#   bash scripts/verify_post_deploy_cockpit.sh --evidence /tmp/378-evidence.json
#   bash scripts/verify_post_deploy_cockpit.sh --fixture test/scripts/fixtures/post_deploy_cockpit/green
#   bash scripts/verify_post_deploy_cockpit.sh --require-operator-evidence --evidence …
#
# Exit codes:
#   0  all required software checks passed (human_remaining may still be listed)
#   1  usage / missing prerequisites
#   2  deploy/timer/revision/health/identity failure
#   3  authenticated MCP / cockpit path failure
#   4  evidence write failure
#   5  software green but operator evidence still required
#      (--require-operator-evidence only; default live path stays 0 so the
#      poller/operator gate is not blocked on OAuth screenshots)
#
# NEED template (printed when human_remaining is non-empty):
#   NEED (human): operator-attended post-deploy evidence after tip is live —
#   (1) OAuth cockpit load + Agents tab screenshot,
#   (2) live SHA == origin/master (no manual-drift banner) or document
#       migration_refused, (3) rollback/health drill without hand-editing
#       /opt/casein/release, (4) attach redacted evidence JSON + screenshots
#   on #378. Clear by: owner posts those artifacts. Unblocks: close #378.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CURRENT_SOCK="${CASEIN_CURRENT_SOCK:-/run/casein/current.sock}"
LAST_DEPLOY_FILE="${CASEIN_LAST_DEPLOY_FILE:-/run/casein/last-deploy.json}"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
INSTANCES_DIR="${CASEIN_INSTANCES_DIR:-/run/casein/instances}"
CASEIN_URL="${CASEIN_URL:-http://127.0.0.1:4000}"
TOKEN="${CASEIN_API_TOKEN:-}"
WORKSPACE_ID="${WORKSPACE_ID:-${CASEIN_WORKSPACE_ID:-}}"
WORKSPACE_NAME="${CASEIN_WORKSPACE_NAME:-}"
ORIGIN_REF="${CASEIN_ORIGIN_REF:-origin/master}"
CI_MODE=0
ALLOW_DRIFT=0
REQUIRE_OPERATOR_EVIDENCE=0
EVIDENCE_PATH=""
SESSION_NAME="${CASEIN_VERIFY_SESSION:-}"
FIXTURE_DIR=""

# Fixed human checklist — matches #378 acceptance. Never auto-satisfied.
HUMAN_REMAINING_DEFAULT=(
  "oauth_cockpit_load: OAuth browser load of cockpit (https://devide.devbox.milcgroup.com or PHX_HOST)"
  "agents_tab_screenshot: Agents tab UI screenshot with layout/status visible"
  "drift_banner_or_clean: confirm no manual-drift banner when live SHA == origin/master, or screenshot banner when deliberately diverged"
  "rollback_drill_note: documented rollback/health drill without hand-editing /opt/casein/release"
  "attach_evidence_on_issue: attach redacted evidence JSON + screenshots on GitHub issue #378"
)

usage() {
  cat <<'EOF'
Usage: verify_post_deploy_cockpit.sh [options]

Authenticated post-deploy cockpit verification for issue #378.

Options:
  --ci                         Fail closed (default already does on software checks)
  --allow-drift                Do not fail when deployed SHA != origin tip
  --evidence PATH              Write redacted JSON evidence to PATH
  --session NAME               Topology session name
  --fixture DIR                Hermetic dry-run from fixture directory (no live I/O)
  --require-operator-evidence  Exit 5 when software is green but human_remaining
                               is non-empty (CI tracking; default live path exits 0)

Environment:
  CASEIN_API_TOKEN       Workspace-scoped bearer (required for live MCP)
  CASEIN_WORKSPACE_ID    Workspace UUID or name (required for live MCP)
  CASEIN_WORKSPACE_NAME  Optional tmux prefix key
  CASEIN_URL             Loopback base (default http://127.0.0.1:4000)
  CASEIN_CURRENT_SOCK    Active socket symlink (default /run/casein/current.sock)
  CASEIN_LAST_DEPLOY_FILE  Poller status JSON
  CASEIN_ENV_FILE        Host env with CASEIN_GIT_REVISION
  CASEIN_INSTANCES_DIR   Instance heartbeat directory
  CASEIN_ORIGIN_REF      Expected git tip (default origin/master)
  CASEIN_VERIFY_SESSION  Optional explicit tmux session for topology
  CASEIN_ALLOW_DEPLOY_DRIFT=1  Same as --allow-drift (attended only)
  CASEIN_REQUIRE_OPERATOR_EVIDENCE=1  Same as --require-operator-evidence

Fixture layout (DIR):
  env                      lines like CASEIN_GIT_REVISION=<sha>
  last-deploy.json         poller record
  live_id                  instance hash (no casein- prefix / .service)
  live_unit_active         e.g. active
  live_unit_description    e.g. Casein canary <40-hex> (<id>)
  timer_active / timer_enabled / service_result / service_active / service_exec_status
  origin_sha               expected tip
  health_code / health_body / healthz_code / healthz_body
  socket_peer_pid / unit_main_pid
  instances/<live_id>.json heartbeat (pid, version, socket_path, …)
  lingering_units          optional multiline "unit state substate"
  caddy_dial               optional; default unix//run/casein/current.sock
  mcp/term_init.json, mcp/list.json, mcp/topo.json, mcp/preview.json
                           optional canned MCP tool results (HTTP 200 assumed)
  allow_drift              file present or contents "1" → allow drift
  expect_verdict           optional expected verdict string (asserted at end)

Exit codes: 0 software ok · 1 usage · 2 deploy/identity · 3 MCP · 4 evidence ·
            5 software ok but operator evidence required (--require-operator-evidence)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI_MODE=1; shift ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    --require-operator-evidence) REQUIRE_OPERATOR_EVIDENCE=1; shift ;;
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
    --fixture)
      FIXTURE_DIR="${2:-}"
      [[ -n "$FIXTURE_DIR" ]] || { echo "ERROR: --fixture needs a directory" >&2; exit 1; }
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "${CASEIN_ALLOW_DEPLOY_DRIFT:-0}" == "1" ]]; then
  ALLOW_DRIFT=1
fi
if [[ "${CASEIN_REQUIRE_OPERATOR_EVIDENCE:-0}" == "1" ]]; then
  REQUIRE_OPERATOR_EVIDENCE=1
fi

if [[ -n "$FIXTURE_DIR" ]]; then
  if [[ ! -d "$FIXTURE_DIR" ]]; then
    echo "ERROR: fixture dir not found: $FIXTURE_DIR" >&2
    exit 1
  fi
  # Resolve once; never fall through to live host paths.
  FIXTURE_DIR="$(cd "$FIXTURE_DIR" && pwd)"
  if [[ -f "${FIXTURE_DIR}/allow_drift" ]]; then
    ad="$(tr -d '[:space:]' <"${FIXTURE_DIR}/allow_drift" || true)"
    if [[ -z "$ad" || "$ad" == "1" ]]; then
      ALLOW_DRIFT=1
    fi
  fi
fi

log() { printf '>>> %s\n' "$*"; }
fail() { local code="$1"; shift; echo "ERROR: $*" >&2; exit "$code"; }

fixture_read() {
  local name="$1"
  local default="${2:-}"
  if [[ -n "$FIXTURE_DIR" && -f "${FIXTURE_DIR}/${name}" ]]; then
    cat "${FIXTURE_DIR}/${name}"
  else
    printf '%s' "$default"
  fi
}

# ---------------------------------------------------------------------------
# HTTP helpers — never use curl -f when the body/status must be inspected.
# ---------------------------------------------------------------------------

HTTP_CODE="000"

http_unix_to() {
  local out="$1"
  local path="$2"
  shift 2
  if [[ -n "$FIXTURE_DIR" ]]; then
    case "$path" in
      /health)
        fixture_read health_body >"$out"
        HTTP_CODE="$(fixture_read health_code 000 | tr -d '[:space:]')"
        ;;
      /healthz)
        fixture_read healthz_body >"$out"
        HTTP_CODE="$(fixture_read healthz_code 000 | tr -d '[:space:]')"
        ;;
      /api/deploy_status)
        fixture_read deploy_status_body '{"error":"fixture"}' >"$out"
        HTTP_CODE="$(fixture_read deploy_status_code 403 | tr -d '[:space:]')"
        ;;
      *)
        : >"$out"
        HTTP_CODE="000"
        ;;
    esac
    return 0
  fi
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
  if [[ -n "$FIXTURE_DIR" ]]; then
    : >"$out"
    HTTP_CODE="000"
    return 0
  fi
  HTTP_CODE="$(
    curl -sS --max-time 5 -o "$out" -w '%{http_code}' \
      "$@" \
      "$url" 2>/dev/null || printf '000'
  )"
}

casein_http_to() {
  local out="$1"
  local path="$2"
  shift 2
  if [[ -n "$FIXTURE_DIR" ]]; then
    http_unix_to "$out" "$path" "$@"
    return 0
  fi
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
  local out="$1"
  local surface="$2"
  local id="$3"
  local method="$4"
  local params="${5:-"{}"}"
  local path="/api/${surface}/mcp"

  if [[ -n "$FIXTURE_DIR" ]]; then
    local canned=""
    case "${method}:${id}" in
      initialize:1) canned="${FIXTURE_DIR}/mcp/term_init.json" ;;
      tools/call:2) canned="${FIXTURE_DIR}/mcp/list.json" ;;
      tools/call:3) canned="${FIXTURE_DIR}/mcp/topo.json" ;;
      tools/call:4) canned="${FIXTURE_DIR}/mcp/preview.json" ;;
    esac
    if [[ -n "$canned" && -f "$canned" ]]; then
      cp "$canned" "$out"
      HTTP_CODE="200"
    else
      printf '%s' '{"jsonrpc":"2.0","id":0,"error":{"message":"fixture missing canned MCP response"}}' >"$out"
      HTTP_CODE="500"
    fi
    return 0
  fi

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
# Host / deploy ground truth
# ---------------------------------------------------------------------------

read_git_revision() {
  if [[ -n "$FIXTURE_DIR" ]]; then
    sed -n 's/^CASEIN_GIT_REVISION=//p' "${FIXTURE_DIR}/env" 2>/dev/null | tail -1 | tr -d '\r' || true
    return 0
  fi
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
  if [[ -n "$FIXTURE_DIR" ]]; then
    fixture_read live_id | tr -d '[:space:]'
    return 0
  fi
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
  if [[ -n "$FIXTURE_DIR" ]]; then
    fixture_read live_unit_description
    return 0
  fi
  systemctl show "$unit" -p Description --value 2>/dev/null || printf ''
}

unit_active() {
  local unit="$1"
  if [[ -n "$FIXTURE_DIR" ]]; then
    case "$unit" in
      casein-deploy.timer) fixture_read timer_active unknown | tr -d '[:space:]' ;;
      casein-deploy.service) fixture_read service_active unknown | tr -d '[:space:]' ;;
      *) fixture_read live_unit_active unknown | tr -d '[:space:]' ;;
    esac
    return 0
  fi
  local state
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    printf '%s' "$state"
  else
    printf 'unknown'
  fi
}

unit_main_pid() {
  local unit="$1"
  if [[ -n "$FIXTURE_DIR" ]]; then
    fixture_read unit_main_pid | tr -d '[:space:]'
    return 0
  fi
  systemctl show "$unit" -p MainPID --value 2>/dev/null | tr -d '[:space:]' || printf ''
}

socket_peer_pid() {
  local sock="$1"
  if [[ -n "$FIXTURE_DIR" ]]; then
    fixture_read socket_peer_pid | tr -d '[:space:]'
    return 0
  fi
  # ss line: users:(("beam.smp",pid=1126605,fd=47))
  ss -xlpn 2>/dev/null | python3 -c '
import re, sys
sock = sys.argv[1]
for line in sys.stdin:
    if sock in line:
        m = re.search(r"pid=(\d+)", line)
        print(m.group(1) if m else "")
        break
' "$sock" 2>/dev/null || printf ''
}

list_casein_units() {
  if [[ -n "$FIXTURE_DIR" ]]; then
    # include live unit line so the awk filter still works
    local live_id
    live_id="$(fixture_read live_id | tr -d '[:space:]')"
    local active
    active="$(fixture_read live_unit_active active | tr -d '[:space:]')"
    if [[ -n "$live_id" ]]; then
      printf 'casein-%s.service %s running\n' "$live_id" "$active"
    fi
    fixture_read lingering_units
    return 0
  fi
  systemctl list-units --type=service --all --no-legend 2>/dev/null \
    | sed 's/^[[:space:]]*●\?[[:space:]]*//' \
    | awk '$1 ~ /^casein-[0-9a-f]{16}\.service$/ {print $1, $3, $4}'
}

sha_from_description() {
  python3 -c '
import re,sys
text=sys.stdin.read().strip()
m=re.search(r"\b([0-9a-f]{40})\b", text)
print(m.group(1) if m else "")
'
}

origin_tip() {
  if [[ -n "$FIXTURE_DIR" ]]; then
    fixture_read origin_sha | tr -d '[:space:]'
    return 0
  fi
  git -C "$ROOT" rev-parse "$ORIGIN_REF" 2>/dev/null || printf ''
}

read_heartbeat() {
  local live_id="$1"
  if [[ -z "$live_id" ]]; then
    printf ''
    return 0
  fi
  local path
  if [[ -n "$FIXTURE_DIR" ]]; then
    path="${FIXTURE_DIR}/instances/${live_id}.json"
  else
    path="${INSTANCES_DIR}/${live_id}.json"
  fi
  if [[ -r "$path" ]]; then
    cat "$path"
  else
    printf ''
  fi
}

caddy_app_dial() {
  if [[ -n "$FIXTURE_DIR" ]]; then
    local d
    d="$(fixture_read caddy_dial | tr -d '[:space:]')"
    if [[ -n "$d" ]]; then
      printf '%s' "$d"
    else
      printf 'unix//run/casein/current.sock'
    fi
    return 0
  fi
  local host="${CASEIN_PHX_HOST:-casein.devbox.milcgroup.com}"
  curl -sS --max-time 3 http://localhost:2019/config/ 2>/dev/null | python3 -c '
import json, sys
host = sys.argv[1]
try:
    cfg = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
servers = ((cfg.get("apps") or {}).get("http") or {}).get("servers") or {}

def find_dial(obj, depth=0):
    if depth > 24:
        return None
    if isinstance(obj, dict):
        if obj.get("handler") == "reverse_proxy" and obj.get("upstreams"):
            if (obj.get("rewrite") or {}).get("uri") == "/oauth2/auth":
                return None
            for u in obj["upstreams"]:
                if isinstance(u, dict) and u.get("dial"):
                    return u["dial"]
        for k, v in obj.items():
            if k == "handle_response":
                continue
            d = find_dial(v, depth + 1)
            if d:
                return d
    elif isinstance(obj, list):
        for item in obj:
            d = find_dial(item, depth + 1)
            if d:
                return d
    return None

for _name, srv in servers.items():
    for route in srv.get("routes") or []:
        hosts = []
        for m in route.get("match") or []:
            hosts.extend(m.get("host") or [])
        if host in hosts:
            d = find_dial(route)
            if d:
                print(d)
                raise SystemExit(0)
print("")
' "$host" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# Evidence accumulator
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
if [[ -n "$FIXTURE_DIR" ]]; then
  log "    mode=fixture dir=${FIXTURE_DIR}"
else
  log "    mode=live"
fi
log "    sock=${CURRENT_SOCK}"
log "    url=${CASEIN_URL}"
log "    workspace=${WORKSPACE_ID:-unset}"
log "    origin_ref=${ORIGIN_REF}"
log "    allow_drift=${ALLOW_DRIFT}"
log "    require_operator_evidence=${REQUIRE_OPERATOR_EVIDENCE}"

FAILURES=()
MCP_FAILURES=()

# 1) Timer / latest deploy service
log "==> casein-deploy.timer / casein-deploy.service"
timer_active="$(unit_active casein-deploy.timer)"
if [[ -n "$FIXTURE_DIR" ]]; then
  timer_enabled="$(fixture_read timer_enabled unknown | tr -d '[:space:]')"
  svc_result="$(fixture_read service_result unknown | tr -d '[:space:]')"
  svc_status="$(fixture_read service_exec_status unknown | tr -d '[:space:]')"
  svc_finished="$(fixture_read service_finished)"
else
  timer_enabled="$(systemctl is-enabled casein-deploy.timer 2>/dev/null || printf 'unknown')"
  svc_result="$(systemctl show casein-deploy.service -p Result --value 2>/dev/null || printf 'unknown')"
  svc_status="$(systemctl show casein-deploy.service -p ExecMainStatus --value 2>/dev/null || printf 'unknown')"
  svc_finished="$(systemctl show casein-deploy.service -p InactiveEnterTimestamp --value 2>/dev/null || printf '')"
fi
svc_state="$(unit_active casein-deploy.service)"
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
if [[ -n "$FIXTURE_DIR" ]]; then
  if [[ -f "${FIXTURE_DIR}/last-deploy.json" ]]; then
    last_deploy_raw="$(cat "${FIXTURE_DIR}/last-deploy.json")"
  else
    FAILURES+=("fixture missing last-deploy.json")
  fi
elif [[ -r "$LAST_DEPLOY_FILE" ]]; then
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
  live_sock=""
else
  live_unit="casein-${live_id}.service"
  live_desc="$(unit_description "$live_unit")"
  live_active="$(unit_active "$live_unit")"
  live_sha="$(printf '%s' "$live_desc" | sha_from_description)"
  if [[ -n "$FIXTURE_DIR" ]]; then
    live_sock="${FIXTURE_DIR}/instances/${live_id}.sock"
  else
    live_sock="$(readlink -f "$CURRENT_SOCK" 2>/dev/null || readlink "$CURRENT_SOCK" 2>/dev/null || true)"
  fi
  note_file live_unit "$live_unit"
  note_file live_description "$live_desc"
  note_file live_active "$live_active"
  note_file live_sha_from_unit "$live_sha"
  note_file live_sock "$live_sock"
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

# 3b) Release identity — prove WHICH process answered
log "==> release identity (socket peer / unit MainPID / heartbeat)"
heartbeat_raw="$(read_heartbeat "$live_id")"
note_file heartbeat_raw "$heartbeat_raw"
hb_pid=""
hb_version=""
hb_socket=""
if [[ -n "$heartbeat_raw" ]]; then
  hb_pid="$(printf '%s' "$heartbeat_raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("pid") or "")' 2>/dev/null || true)"
  hb_version="$(printf '%s' "$heartbeat_raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("version") or "")' 2>/dev/null || true)"
  hb_socket="$(printf '%s' "$heartbeat_raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("socket_path") or "")' 2>/dev/null || true)"
else
  if [[ -n "$live_id" ]]; then
    FAILURES+=("missing instance heartbeat for ${live_id} under ${INSTANCES_DIR:-fixture}")
  fi
fi
main_pid=""
peer_pid=""
if [[ -n "$live_unit" ]]; then
  main_pid="$(unit_main_pid "$live_unit")"
fi
if [[ -n "$live_sock" ]]; then
  peer_pid="$(socket_peer_pid "$live_sock")"
fi
note_file unit_main_pid "$main_pid"
note_file socket_peer_pid "$peer_pid"
note_file heartbeat_pid "$hb_pid"
note_file heartbeat_version "$hb_version"
note_file heartbeat_socket "$hb_socket"
log "    unit MainPID=${main_pid:-unset}"
log "    socket peer pid=${peer_pid:-unset}"
log "    heartbeat pid=${hb_pid:-unset} version=${hb_version:-unset}"

if [[ -n "$main_pid" && "$main_pid" != "0" && -n "$peer_pid" && "$main_pid" != "$peer_pid" ]]; then
  FAILURES+=("identity mismatch: unit MainPID ${main_pid} != socket peer pid ${peer_pid} (stale canary may be answering)")
fi
if [[ -n "$main_pid" && "$main_pid" != "0" && -n "$hb_pid" && "$main_pid" != "$hb_pid" ]]; then
  FAILURES+=("identity mismatch: unit MainPID ${main_pid} != heartbeat pid ${hb_pid}")
fi
if [[ -n "$peer_pid" && -n "$hb_pid" && "$peer_pid" != "$hb_pid" ]]; then
  FAILURES+=("identity mismatch: socket peer pid ${peer_pid} != heartbeat pid ${hb_pid}")
fi
if [[ -n "$hb_version" && -n "$live_sha" && "$hb_version" != "$live_sha" ]]; then
  FAILURES+=("identity mismatch: heartbeat version ${hb_version} != unit description sha ${live_sha}")
fi

# 4) Revision equality (env + unit + origin + heartbeat)
log "==> revision: env / unit / heartbeat / ${ORIGIN_REF}"
deployed_sha="$(read_git_revision)"
origin_sha="$(origin_tip)"
note_file deployed_sha "$deployed_sha"
note_file origin_sha "$origin_sha"
log "    CASEIN_GIT_REVISION=${deployed_sha:-unset}"
log "    unit sha=${live_sha:-unset}"
log "    heartbeat version=${hb_version:-unset}"
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
if [[ -n "$deployed_sha" && -n "$hb_version" && "$deployed_sha" != "$hb_version" ]]; then
  FAILURES+=("env revision ${deployed_sha} != heartbeat version ${hb_version}")
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
if [[ -z "$FIXTURE_DIR" && ! -L "$CURRENT_SOCK" && ! -S "$CURRENT_SOCK" ]]; then
  FAILURES+=("${CURRENT_SOCK} missing")
  health_code="000"
  : >"${EVIDENCE_DIR}/health_body"
  : >"${EVIDENCE_DIR}/healthz_body"
  healthz_code="000"
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
    log "    /healthz 401 (auth-enforcing path)"
    ;;
  000)
    FAILURES+=("/healthz unreachable")
    ;;
  *)
    FAILURES+=("/healthz returned HTTP ${healthz_code}")
    ;;
esac

# 5b) Caddy upstream (read-only admin probe) — must not be legacy devide sock
log "==> caddy upstream dial (read-only)"
caddy_dial="$(caddy_app_dial)"
note_file caddy_dial "$caddy_dial"
log "    dial=${caddy_dial:-unset}"
case "$caddy_dial" in
  "unix//run/casein/current.sock"|"127.0.0.1:4000")
    log "    caddy dial ok"
    ;;
  "unix//run/devide/current.sock")
    FAILURES+=("caddy still points at legacy unix//run/devide/current.sock")
    ;;
  "")
    log "    note: caddy dial unavailable (admin probe empty); recorded only"
    ;;
  *)
    log "    WARN unexpected caddy dial ${caddy_dial} (recorded; not hard-fail unless legacy)"
    ;;
esac

# 6) Authenticated MCP (workspace token) — cockpit-adjacent read-only smoke
log "==> authenticated read-only MCP"
if [[ -n "$FIXTURE_DIR" ]]; then
  # Fixture path always exercises MCP parsing when canned files exist.
  TOKEN="${TOKEN:-fixture-token}"
  WORKSPACE_ID="${WORKSPACE_ID:-fixture-workspace}"
fi
if [[ -z "$TOKEN" ]]; then
  MCP_FAILURES+=("CASEIN_API_TOKEN unset — cannot authenticate MCP")
elif [[ -z "$WORKSPACE_ID" ]]; then
  MCP_FAILURES+=("CASEIN_WORKSPACE_ID/WORKSPACE_ID unset")
else
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

# 7) Optional global deploy_status (workspace → 403)
log "==> /api/deploy_status (global token only; workspace token expects 403)"
casein_http_to "${EVIDENCE_DIR}/ds_body.json" /api/deploy_status \
  -H "authorization: Bearer ${TOKEN:-}" || true
ds_code="${HTTP_CODE}"
note_file deploy_status_http "$ds_code"
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
    # When global token works, cross-check version against identity.
    ds_version="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version") or "")' "$ds_redacted" 2>/dev/null || true)"
    note_file deploy_status_version "$ds_version"
    if [[ -n "$ds_version" && -n "$deployed_sha" && "$ds_version" != "$deployed_sha" ]]; then
      FAILURES+=("deploy_status version ${ds_version} != CASEIN_GIT_REVISION ${deployed_sha}")
    fi
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
  REQUIRE_OPERATOR_EVIDENCE="$REQUIRE_OPERATOR_EVIDENCE" \
  FIXTURE_MODE="$([[ -n "$FIXTURE_DIR" ]] && echo 1 || echo 0)" \
  HUMAN_JOINED="$(printf '%s\n' "${HUMAN_REMAINING_DEFAULT[@]}")" \
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
fixture_mode = os.environ.get("FIXTURE_MODE") == "1"
human_remaining = [l for l in os.environ.get("HUMAN_JOINED", "").splitlines() if l]

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

identity = {
    "live_instance": read("live_instance"),
    "live_unit": read("live_unit"),
    "live_sock": read("live_sock"),
    "unit_main_pid": read("unit_main_pid"),
    "socket_peer_pid": read("socket_peer_pid"),
    "heartbeat_pid": read("heartbeat_pid"),
    "heartbeat_version": read("heartbeat_version"),
    "heartbeat_socket": read("heartbeat_socket"),
    "matched": bool(
        read("unit_main_pid")
        and read("unit_main_pid") not in ("", "0")
        and read("unit_main_pid") == read("socket_peer_pid") == read("heartbeat_pid")
        and (not read("heartbeat_version") or read("heartbeat_version") == read("live_sha_from_unit") or not read("live_sha_from_unit"))
    ),
    "note": (
        "Proves WHICH release answered: socket peer pid, systemd MainPID, and "
        "instance heartbeat pid/version must agree. Lingering canaries run old "
        "code against prod DB — never treat them as live."
    ),
}

evidence = {
    "issue": 378,
    "schema": "casein_post_deploy_cockpit_evidence",
    "schema_version": 2,
    "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mode": "fixture" if fixture_mode else "live",
    "verdict": None,
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
        "caddy_dial": read("caddy_dial") or None,
    },
    "identity": identity,
    "health": {
        "path_health": {"http_code": read("health_code"), "body": read("health_body")[:200]},
        "path_healthz": {"http_code": read("healthz_code"), "body": read("healthz_body")[:200]},
        "note": "HTTP 401 on /health means alive + auth-enforcing; do not use curl -f",
    },
    "deploy_status": {
        "http_code": read("deploy_status_http"),
        "body": read_json("deploy_status_redacted"),
        "version": read("deploy_status_version") or None,
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
    "human_remaining": human_remaining,
    "manual_not_done": human_remaining,
    "need_template": (
        "NEED (human): operator-attended post-deploy evidence after tip is live — "
        "(1) OAuth load of https://devide.devbox.milcgroup.com cockpit + Agents tab screenshot, "
        "(2) confirm live SHA == origin/master (no manual-drift banner) or document migration_refused, "
        "(3) rollback/health drill note without hand-editing /opt/casein/release, "
        "(4) attach redacted evidence JSON from `bash scripts/verify_post_deploy_cockpit.sh --evidence PATH` "
        "plus screenshots on #378. Clear by: owner posts those artifacts on #378. "
        "Unblocks: close #378 / parent #371 checklist item."
    ),
    "rollback_health_note": (
        "This gate does not mutate releases. Confirm rollback via documented "
        "poller/deploy-devbox-release paths only; never hand-edit /opt/casein/release."
    ),
    "exit_contract": {
        "0": "software checks passed (human_remaining may still be listed)",
        "2": "deploy/timer/revision/health/identity failure",
        "3": "authenticated MCP failure",
        "4": "evidence write failure",
        "5": "software green but operator evidence required (--require-operator-evidence)",
    },
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
  python3 -m json.tool "${EVIDENCE_DIR}/evidence.json" 2>/dev/null | head -n 100 || true
  if [[ -z "$EVIDENCE_PATH" && -f "${EVIDENCE_DIR}/evidence.json" ]]; then
    EVIDENCE_FOR_ASSERT="${EVIDENCE_DIR}/evidence.json"
  fi
fi

if [[ -n "$EVIDENCE_PATH" ]]; then
  EVIDENCE_FOR_ASSERT="$EVIDENCE_PATH"
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

# Always surface the human NEED when software path is the only green half.
if [[ ${#FAILURES[@]} -eq 0 && ${#MCP_FAILURES[@]} -eq 0 ]]; then
  log "==> human_remaining (not auto-closed by this gate):"
  for h in "${HUMAN_REMAINING_DEFAULT[@]}"; do
    log "  - $h"
  done
  cat <<'NEED'

NEED (human): operator-attended post-deploy evidence after tip is live — (1) OAuth load of https://devide.devbox.milcgroup.com cockpit + Agents tab screenshot, (2) confirm live SHA == origin/master (no manual-drift banner) or document migration_refused, (3) rollback/health drill note without hand-editing /opt/casein/release, (4) attach redacted evidence JSON from `bash scripts/verify_post_deploy_cockpit.sh --evidence PATH` plus screenshots on this issue.
Clear by: owner posts those artifacts on #378.
Unblocks: close #378 / parent #371 checklist item.

NEED
fi

# Fixture expect_verdict assertion (CI dry-run contract)
if [[ -n "$FIXTURE_DIR" && -f "${FIXTURE_DIR}/expect_verdict" ]]; then
  expected="$(tr -d '[:space:]' <"${FIXTURE_DIR}/expect_verdict")"
  if [[ -n "$expected" && "$verdict" != "$expected" ]]; then
    fail 2 "fixture expect_verdict=${expected} but got ${verdict}"
  fi
  log "    fixture expect_verdict matched: ${expected}"
fi

: "${CI_MODE}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  exit 2
fi
if [[ ${#MCP_FAILURES[@]} -gt 0 ]]; then
  exit 3
fi

if [[ "$REQUIRE_OPERATOR_EVIDENCE" -eq 1 ]]; then
  log "OK: software checks passed; operator evidence still required (exit 5)"
  exit 5
fi

log "OK: post-deploy cockpit gate software checks passed"
exit 0
