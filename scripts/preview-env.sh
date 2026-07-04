#!/usr/bin/env bash
#
# preview-env.sh — ephemeral DevIDE preview environments, one per git ref.
#
# Each environment is fully isolated from the shared checkout and from every
# other environment:
#   * its own detached git WORKTREE at a specific commit (not the live tree, so
#     uncommitted edits / broken assets elsewhere can't leak in)
#   * its own allocated PORT
#   * its own isolated DATABASE (dev_ide_preview_<id>, dropped on teardown)
#   * its own seeded local sandbox workspace (no manager, no tmux collision)
# Instances are tracked in a JSON REGISTRY so they can be listed, stopped, and
# garbage-collected.
#
# Commands:
#   preview-env.sh up   [<ref>] [--port N] [--keep]   # default ref = HEAD
#   preview-env.sh dirty [--port N] [--foreground]  # working tree (live checkout)
#   preview-env.sh ls
#   preview-env.sh down <id|all> [--keep-db]
#   preview-env.sh gc                                  # reap dead instances
#   preview-env.sh logs <id>
#   preview-env.sh url  <id>
#   preview-env.sh tidewave <id>
#   preview-env.sh tidewave-latest
#   preview-env.sh agent-env <id>
#
# State lives on the SAME filesystem as the repo so _build can be hardlink-copied
# (cp -al) into each worktree — turning a ~47s cold compile into a ~8s one.
#
# NOTE: this builds a *committed ref*. To preview uncommitted working-tree edits,
# use scripts/dev-preview-instance.sh (wrapper for `dirty --foreground`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${DEVIDE_PREVIEW_HOME:-$(dirname "$ROOT")/.devide-preview}"
INST_DIR="$STATE/instances"
WT_DIR="$STATE/worktrees"
WS_DIR="$STATE/workspaces"
LOG_DIR="$STATE/logs"
# Each preview's canonical front door is a unix socket (collision-free, derived
# purely from the id), mirroring the live /run/devide/current.sock model. The
# Caddy preview router dials this socket. The TCP port (below) is kept only as a
# loopback convenience for local tooling + the Tidewave agent dial.
SOCK_DIR="$STATE/sockets"
PORT_BASE="${DEVIDE_PREVIEW_PORT_BASE:-41000}"
PORT_MAX="${DEVIDE_PREVIEW_PORT_MAX:-41049}"
SANDBOX="${DEVIDE_PREVIEW_WORKSPACE:-preview-sandbox}"
MISE=(mise exec elixir@1.20.0-otp-28 erlang@28.5 --)

mkdir -p "$INST_DIR" "$WT_DIR" "$WS_DIR" "$LOG_DIR" "$SOCK_DIR"
# Socket path is a pure function of the id — no allocation, no registry lookup.
sock_for() { printf '%s/%s.sock' "$SOCK_DIR" "$1"; }

log() { printf '>>> %s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- DB helpers: reuse the release creds/host, swap the database name ----------
base_db_url() {
  local url
  url="$(grep -E '^DATABASE_URL=' /etc/devide/devide.env | cut -d= -f2- | tr -d '"')"
  [ -n "$url" ] || die "no DATABASE_URL in /etc/devide/devide.env"
  printf '%s' "$url"
}
db_url_for() { printf '%s/%s' "$(base_db_url | sed 's#/[^/]*$##')" "$1"; }
psql_admin() { psql "$(base_db_url | sed 's#^ecto://#postgresql://#; s#/[^/]*$#/postgres#')" "$@"; }

# --- registry helpers (no jq) -------------------------------------------------
json_get() { sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1"; }

# Emit `export NAME='value'` with the value single-quote-escaped so the output
# is safe to `eval`, even when value (e.g. an API-derived workspace id) contains
# a single quote. Replaces each ' with the '\'' idiom.
emit_export() { printf "export %s='%s'\n" "$1" "${2//\'/\'\\\'\'}"; }
port_taken() {
  ss -tln 2>/dev/null | grep -q ":$1 " && return 0
  grep -lq "\"port\":\"$1\"" "$INST_DIR"/*.json 2>/dev/null && return 0
  return 1
}
# Deterministic-first allocation: an id maps to a stable preferred port that is
# a pure function of the id (the worktree-name trick), so relaunching the same
# ref reclaims the same port — stable URLs across restarts, no ledger lookup in
# the common case. The scan then wraps from that offset, so a hash clash or a
# cramped range still resolves to a free port instead of failing. Passing no id
# falls back to the old base-up linear scan.
alloc_port() {
  local id="${1:-}" slots=$((PORT_MAX - PORT_BASE + 1)) start off p
  if [ -n "$id" ]; then
    start=$(( $(cksum <<<"$id" | cut -d' ' -f1) % slots ))
  else
    start=0
  fi
  for off in $(seq 0 $((slots - 1))); do
    p=$(( PORT_BASE + (start + off) % slots ))
    port_taken "$p" || { printf '%s' "$p"; return 0; }
  done
  die "no free port in $PORT_BASE-$PORT_MAX"
}
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
router_sync() { bash "$ROOT/scripts/preview-router.sh" reload >/dev/null 2>&1 || true; }

tidewave_url_for() { printf 'http://127.0.0.1:%s/tidewave' "$1"; }
tidewave_mcp_url_for() { printf 'http://127.0.0.1:%s/tidewave/mcp' "$1"; }

ensure_asset_node_deps() {
  local dir="$1/assets"
  [ -f "$dir/package-lock.json" ] || return 0
  [ -d "$dir/node_modules/@codemirror/state" ] &&
    [ -d "$dir/node_modules/@codemirror/view" ] &&
    [ -d "$dir/node_modules/@codemirror/commands" ] && return 0

  log "installing assets npm dependencies"
  ( cd "$dir" && NODE_ENV=development npm ci --include=dev --no-audit --no-fund --no-progress )
}

start_preview_server() {
  local checkout="$1" sock="$2" port="$3" ws="$4" db_url="$5" logf="$6"
  local pidf="${logf}.pid"
  local api_token
  local -a env_args
  rm -f "$pidf"
  api_token="$(preview_api_token 2>/dev/null || true)"
  env_args=(
    "MIX_ENV=dev"
    "PHX_SERVER=true"
    "DEVIDE_URL=http://127.0.0.1:$port"
    "DEVIDE_HTTP_SOCKET=$sock"
    "DEVIDE_PREVIEW_TIDEWAVE_PORT=$port"
    "DEV_IDE_WORKSPACE_SOURCE=local"
    "DEV_IDE_WORKSPACES_ROOT=$ws"
    "DATABASE_URL=$db_url"
  )
  if [ -n "$api_token" ]; then
    env_args+=("DEV_IDE_API_TOKEN=$api_token")
  fi

  (
    cd "$checkout"
    setsid env "${env_args[@]}" \
      "${MISE[@]}" mix run --no-halt > "$logf" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$pidf"
  )

  cat "$pidf"
}

running_instances() {
  shopt -s nullglob
  local f
  for f in "$INST_DIR"/*.json; do
    local status pid
    status="$(json_get "$f" status)"
    pid="$(json_get "$f" pid)"
    if [ "$status" = running ] && pid_alive "$pid"; then
      printf '%s\n' "$f"
    fi
  done
}

running_count() {
  running_instances | wc -l | tr -d ' '
}

resolve_running_json() {
  local want_id="${DEVIDE_PREVIEW_ENV_ID:-}"
  if [ -n "$want_id" ]; then
    local f="$INST_DIR/${want_id}.json"
    [ -f "$f" ] || die "no such running preview env: $want_id"
    printf '%s' "$f"
    return 0
  fi

  local files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(running_instances)

  [ ${#files[@]} -gt 0 ] || die "no running preview environments"
  if [ ${#files[@]} -gt 1 ]; then
    warn "multiple preview environments running — using newest (set DEVIDE_PREVIEW_ENV_ID to pin)"
  fi

  ls -t "${files[@]}" | head -1
}

seed_sandbox() {
  local dir="$1/$SANDBOX"
  [ -d "$dir/.git" ] && return 0
  mkdir -p "$dir/lib"
  printf '# Preview Sandbox\n\nThrowaway workspace for an ephemeral DevIDE preview env.\n' > "$dir/README.md"
  printf 'defmodule Sandbox do\n  def hello, do: :world\nend\n' > "$dir/lib/sandbox.ex"
  ( cd "$dir" && git init -q \
      && git -c user.email=dev@local -c user.name=dev add -A \
      && git -c user.email=dev@local -c user.name=dev commit -qm "seed" )
}

write_registry() {
  local id="$1" ref="$2" sha="$3" port="$4" pid="$5" db="$6" wt="$7" ws="$8" logf="$9"
  local kind="${10}" checkout="${11}" status="${12}"
  local tw_url tw_mcp started socket
  tw_url="$(tidewave_url_for "$port")"
  tw_mcp="$(tidewave_mcp_url_for "$port")"
  started="$(date -u +%FT%TZ)"
  socket="$(sock_for "$id")"

  printf '{"id":"%s","kind":"%s","ref":"%s","sha":"%s","port":"%s","socket":"%s","pid":"%s","db":"%s","worktree":"%s","checkout":"%s","workspaces_root":"%s","log":"%s","started_at":"%s","status":"%s","tidewave_url":"%s","tidewave_mcp_url":"%s"}\n' \
    "$id" "$kind" "$ref" "$sha" "$port" "$socket" "${pid:-}" "$db" "$wt" "$checkout" "$ws" "$logf" "$started" "$status" "$tw_url" "$tw_mcp" \
    > "$INST_DIR/$id.json"
}

cmd_up() {
  local ref="HEAD" want_port="" keep=0
  while [ $# -gt 0 ]; do case "$1" in
    --port) want_port="$2"; shift 2;;
    --keep) keep=1; shift;;
    -*) die "unknown flag $1";;
    *) ref="$1"; shift;;
  esac; done

  local sha; sha="$(git -C "$ROOT" rev-parse --short "$ref")" || die "bad ref: $ref"
  local id="prev-$sha" n=2
  while [ -e "$INST_DIR/$id.json" ]; do id="prev-$sha-$n"; n=$((n+1)); done
  local db="dev_ide_preview_${id//-/_}"
  local wt="$WT_DIR/$id" ws="$WS_DIR/$id" logf="$LOG_DIR/$id.log"
  local port="${want_port:-$(alloc_port "$id")}"
  port_taken "$port" && [ -n "$want_port" ] && die "port $port is taken"
  local sock; sock="$(sock_for "$id")"
  rm -f "$sock"  # clear any stale socket from a crashed prior run so bind succeeds

  log "[$id] ref=$ref sha=$sha port=$port sock=$sock db=$db"

  log "[$id] creating worktree"
  git -C "$ROOT" worktree add --detach "$wt" "$sha" >/dev/null 2>&1 || die "worktree add failed"
  ln -sfn "$ROOT/deps" "$wt/deps"
  ln -sfn "$ROOT/assets/node_modules" "$wt/assets/node_modules"
  ln -sfn "$ROOT/priv/scripts/node_modules" "$wt/priv/scripts/node_modules"
  log "[$id] hardlinking _build (fast compile)"
  cp -al "$ROOT/_build" "$wt/_build" 2>/dev/null || cp -a "$ROOT/_build" "$wt/_build" 2>/dev/null || true

  seed_sandbox "$ws"
  ensure_asset_node_deps "$ROOT"

  export DATABASE_URL; DATABASE_URL="$(db_url_for "$db")"
  ( cd "$wt"
    log "[$id] ecto.create + migrate"
    "${MISE[@]}" mix ecto.create --quiet 2>/dev/null || true
    "${MISE[@]}" mix ecto.migrate >/dev/null
    log "[$id] building assets"
    "${MISE[@]}" mix assets.build >/dev/null 2>&1 \
      || { log "[$id] assets.build failed — building CSS only"; "${MISE[@]}" mix tailwind dev_ide >/dev/null 2>&1 || true; }
  )

  log "[$id] booting preview server"
  # DEVIDE_HTTP_SOCKET makes the endpoint bind the unix socket (runtime.exs);
  # DEVIDE_PREVIEW_TIDEWAVE_PORT spins the second loopback listener that serves
  # the same endpoint (Tidewave + local tooling) on the TCP port.
  local pid; pid="$(start_preview_server "$wt" "$sock" "$port" "$ws" "$(db_url_for "$db")" "$logf")"

  # The socket is the front door — wait for it to appear as the readiness signal.
  local up=0 i
  for i in $(seq 1 60); do
    if ! pid_alive "$pid"; then break; fi
    [ -S "$sock" ] && { up=1; break; }
    sleep 1
  done
  [ "$up" = 1 ] || { log "[$id] did not come up — see $logf"; tail -5 "$logf" >&2 || true; }

  write_registry "$id" "$ref" "$sha" "$port" "$pid" "$db" "$wt" "$ws" "$logf" "ref" "$wt" "$([ "$up" = 1 ] && echo running || echo failed)"

  router_sync

  echo
  echo "  id:    $id"
  echo "  socket: $sock  (router dials this)"
  echo "  local: http://127.0.0.1:$port/workspaces/$SANDBOX?host=local"
  echo "  tidewave: $(tidewave_url_for "$port")"
  echo "  tidewave_mcp: $(tidewave_mcp_url_for "$port")"
  echo "  url:   https://$id.${DEVIDE_PREVIEW_DOMAIN:-devbox.milcgroup.com}/workspaces/$SANDBOX?host=local  (once edge hookup is live)"
  echo "  shot:  node $ROOT/scripts/dev-preview-shot.mjs http://127.0.0.1:$port/workspaces/$SANDBOX?host=local out.png 390x844"
  echo "  logs:  $0 logs $id"
  [ "$keep" = 1 ] && echo "  (--keep: env left running)"
}

cmd_dirty() {
  local want_port="" foreground=0
  while [ $# -gt 0 ]; do case "$1" in
    --port) want_port="$2"; shift 2;;
    --foreground) foreground=1; shift;;
    -*) die "unknown flag $1";;
    *) die "unexpected arg: $1";;
  esac; done

  # `id` must be declared before it's referenced: bash expands all `local`
  # arguments before assigning, so cramming `ws="$WS_DIR/$id"` onto the same
  # line trips `set -u` (id still unbound at expansion time).
  local id="dirty-$(date +%s)"
  local ws="$WS_DIR/$id" logf="$LOG_DIR/$id.log"
  local db="${DEVIDE_PREVIEW_DB:-dev_ide_preview}"
  local port="${want_port:-$(alloc_port "$id")}"
  port_taken "$port" && [ -n "$want_port" ] && die "port $port is taken"
  local sock; sock="$(sock_for "$id")"
  rm -f "$sock"  # clear any stale socket so bind succeeds
  local sha; sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dirty)"

  log "[$id] working-tree preview port=$port sock=$sock db=$db"

  seed_sandbox "$ws"
  ensure_asset_node_deps "$ROOT"

  export DATABASE_URL; DATABASE_URL="$(db_url_for "$db")"
  log "[$id] ecto.create + migrate"
  ( cd "$ROOT"
    "${MISE[@]}" mix ecto.create --quiet 2>/dev/null || true
    "${MISE[@]}" mix ecto.migrate
    log "[$id] building assets"
    "${MISE[@]}" mix assets.build >/dev/null 2>&1 \
      || { log "[$id] assets.build failed — building CSS only"; "${MISE[@]}" mix tailwind dev_ide >/dev/null 2>&1 || true; }
  )

  if [ "$foreground" = 1 ]; then
    write_registry "$id" "working-tree" "$sha" "$port" "$$" "$db" "" "$ws" "$logf" "dirty" "$ROOT" "running"
    router_sync
    echo ">>> DevIDE dirty preview up:"
    echo ">>>   socket: $sock  (router dials this)"
    echo ">>>   http://127.0.0.1:${port}/workspaces/${SANDBOX}?host=local"
    echo ">>>   tidewave: $(tidewave_url_for "$port")"
    export MIX_ENV=dev PHX_SERVER=true
    export DEVIDE_HTTP_SOCKET="$sock" DEVIDE_PREVIEW_TIDEWAVE_PORT="$port"
    export DEV_IDE_WORKSPACE_SOURCE=local DEV_IDE_WORKSPACES_ROOT="$ws"
    exec "${MISE[@]}" mix phx.server
  fi

  log "[$id] booting preview server (background)"
  local pid; pid="$(start_preview_server "$ROOT" "$sock" "$port" "$ws" "$(db_url_for "$db")" "$logf")"

  local up=0 i
  for i in $(seq 1 60); do
    if ! pid_alive "$pid"; then break; fi
    [ -S "$sock" ] && { up=1; break; }
    sleep 1
  done
  [ "$up" = 1 ] || { log "[$id] did not come up — see $logf"; tail -5 "$logf" >&2 || true; }

  write_registry "$id" "working-tree" "$sha" "$port" "$pid" "$db" "" "$ws" "$logf" "dirty" "$ROOT" "$([ "$up" = 1 ] && echo running || echo failed)"

  router_sync

  echo
  echo "  id:    $id"
  echo "  socket: $sock  (router dials this)"
  echo "  local: http://127.0.0.1:$port/workspaces/$SANDBOX?host=local"
  echo "  tidewave: $(tidewave_url_for "$port")"
  echo "  tidewave_mcp: $(tidewave_mcp_url_for "$port")"
  echo "  logs:  $0 logs $id"
}

cmd_ls() {
  shopt -s nullglob
  local files=("$INST_DIR"/*.json)
  [ ${#files[@]} -eq 0 ] && { echo "(no preview environments)"; return 0; }

  local running; running="$(running_count)"
  if [ "$running" -gt 1 ]; then
    warn "$running preview environments running — pin one with DEVIDE_PREVIEW_ENV_ID for agent pairing"
  fi

  printf '%-16s %-8s %-10s %-6s %-8s %-36s %s\n' ID KIND REF PORT PID TIDEWAVE URL
  local f
  for f in "${files[@]}"; do
    local id kind ref port pid started tw
    id="$(json_get "$f" id)"
    kind="$(json_get "$f" kind)"; [ -z "$kind" ] && kind="ref"
    ref="$(json_get "$f" ref)"; port="$(json_get "$f" port)"
    pid="$(json_get "$f" pid)"; started="$(json_get "$f" started_at)"
    tw="$(json_get "$f" tidewave_mcp_url)"; [ -z "$tw" ] && tw="$(tidewave_mcp_url_for "$port")"
    local alive="dead"; pid_alive "$pid" && alive="$pid"
    printf '%-16s %-8s %-10s %-6s %-8s %-36s http://127.0.0.1:%s/\n' \
      "$id" "$kind" "$ref" "$port" "$alive" "$tw" "$port"
  done
}

teardown() {
  local f="$1" keep_db="$2"
  [ -f "$f" ] || return 0
  local id pid db wt ws logf kind socket
  id="$(json_get "$f" id)"; pid="$(json_get "$f" pid)"; db="$(json_get "$f" db)"
  wt="$(json_get "$f" worktree)"; ws="$(json_get "$f" workspaces_root)"; logf="$(json_get "$f" log)"
  kind="$(json_get "$f" kind)"; socket="$(json_get "$f" socket)"
  log "[$id] stopping (pid=$pid)"
  if pid_alive "$pid"; then kill "$pid" 2>/dev/null || true; sleep 2; pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true; fi
  [ -n "$socket" ] && rm -f "$socket"
  if [ "$keep_db" != 1 ] && [ -n "$db" ] && [ "$kind" != dirty ]; then
    log "[$id] dropping db $db"; psql_admin -tAc "DROP DATABASE IF EXISTS \"$db\";" >/dev/null 2>&1 || true
  fi
  if [ -n "$wt" ] && [ -d "$wt" ] && [ "$kind" != dirty ]; then
    git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  if [ -n "$ws" ] && [ "$kind" = dirty ]; then
    : # keep shared sandbox root for dirty previews
  elif [ -n "$ws" ]; then
    rm -rf "$ws"
  fi
  [ -n "$logf" ] && rm -f "$logf"
  rm -f "$f"
  log "[$id] removed"
}

cmd_down() {
  local target="${1:-}" keep_db=0
  [ "${2:-}" = "--keep-db" ] && keep_db=1
  [ -n "$target" ] || die "usage: down <id|all> [--keep-db]"
  if [ "$target" = all ]; then
    shopt -s nullglob; for f in "$INST_DIR"/*.json; do teardown "$f" "$keep_db"; done
  else
    teardown "$INST_DIR/$target.json" "$keep_db"
  fi
  router_sync
}

cmd_gc() {
  shopt -s nullglob
  local reaped=0 f
  for f in "$INST_DIR"/*.json; do
    pid_alive "$(json_get "$f" pid)" || { teardown "$f" 0; reaped=$((reaped+1)); }
  done
  router_sync
  echo "gc: reaped $reaped dead environment(s)"
}

cmd_logs() { local f="$INST_DIR/${1:?usage: logs <id>}.json"; [ -f "$f" ] || die "no such env"; tail -n "${2:-40}" "$(json_get "$f" log)"; }
cmd_url()  { local f="$INST_DIR/${1:?usage: url <id>}.json"; [ -f "$f" ] || die "no such env"; echo "http://127.0.0.1:$(json_get "$f" port)/workspaces/$SANDBOX?host=local"; }

cmd_tidewave() {
  local f="$INST_DIR/${1:?usage: tidewave <id>}.json"
  [ -f "$f" ] || die "no such env"
  local tw; tw="$(json_get "$f" tidewave_url)"
  [ -n "$tw" ] || tw="$(tidewave_url_for "$(json_get "$f" port)")"
  echo "$tw"
}

cmd_tidewave_latest() {
  local f; f="$(resolve_running_json)"
  local count; count="$(running_count)"
  if [ "$count" -gt 1 ] && [ -z "${DEVIDE_PREVIEW_ENV_ID:-}" ]; then
    warn "$count preview environments running — using newest (set DEVIDE_PREVIEW_ENV_ID to pin)"
  fi
  local tw; tw="$(json_get "$f" tidewave_mcp_url)"
  [ -n "$tw" ] || tw="$(tidewave_mcp_url_for "$(json_get "$f" port)")"
  echo "$tw"
}

preview_api_token() {
  awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' /etc/devide/devide.env 2>/dev/null | tail -n 1 | tr -d '"'
}

preview_workspace_id() {
  local base_url="$1" token="$2" workspace_name="${3:-$SANDBOX}"
  curl -fsS -H "authorization: Bearer ${token}" "${base_url}/api/workspaces" 2>/dev/null |
    WORKSPACE_NAME="$workspace_name" python3 -c "import json, os, sys
name = os.environ.get('WORKSPACE_NAME', '')
for ws in json.load(sys.stdin):
    if ws.get('name') == name or ws.get('id') == name:
        print(ws.get('id', ''))
        break" 2>/dev/null || true
}

cmd_agent_env() {
  local env_id="${1:?usage: agent-env ID}"
  local f="$INST_DIR/${env_id}.json"
  [ -f "$f" ] || die "no such env"
  local id port checkout token ws_id base_url tw_mcp mcp_home
  id=$(json_get "$f" id)
  port=$(json_get "$f" port)
  checkout=$(json_get "$f" checkout)
  [ -n "$checkout" ] || checkout=$(json_get "$f" worktree)
  [ -n "$checkout" ] || checkout="$ROOT"
  base_url="http://127.0.0.1:${port}"
  tw_mcp=$(json_get "$f" tidewave_mcp_url)
  [ -n "$tw_mcp" ] || tw_mcp=$(tidewave_mcp_url_for "$port")
  token=$(preview_api_token)
  [ -n "$token" ] || die "DEV_IDE_API_TOKEN missing from /etc/devide/devide.env"
  ws_id=$(preview_workspace_id "$base_url" "$token" "$SANDBOX")
  [ -n "$ws_id" ] || die "workspace $SANDBOX not found on preview env — is it up"
  mcp_home="\${HOME}/.devide/agent-mcp/${SANDBOX}"

  emit_export DEV_IDE_API_TOKEN "${token}"
  emit_export DEVIDE_URL "${base_url}"
  emit_export DEVIDE_API_BASE_URL "${base_url}"
  emit_export DEVIDE_WORKSPACE_ID "${ws_id}"
  emit_export DEVIDE_WORKSPACE_NAME "${SANDBOX}"
  emit_export DEVIDE_TERMINAL_MCP_URL "${base_url}/api/terminals/mcp?workspace_id=${ws_id}"
  emit_export DEVIDE_PREVIEW_MCP_URL "${base_url}/api/preview/mcp?workspace_id=${ws_id}"
  emit_export DEVIDE_ARTIFACT_MCP_URL "${base_url}/api/artifacts/mcp?workspace_id=${ws_id}"
  emit_export DEVIDE_TIDEWAVE_MCP_URL "${tw_mcp}"
  emit_export DEVIDE_PREVIEW_ENV_ID "${id}"
  emit_export DEVIDE_CHECKOUT "${checkout}"
  emit_export DEVIDE_SCRIPTS "${ROOT}/scripts"
  emit_export DEVIDE_AGENT_MCP_HOME "${mcp_home}"
}

case "${1:-}" in
  up)   shift; cmd_up "$@";;
  dirty) shift; cmd_dirty "$@";;
  ls)   shift; cmd_ls "$@";;
  down) shift; cmd_down "$@";;
  gc)   shift; cmd_gc "$@";;
  logs) shift; cmd_logs "$@";;
  url)  shift; cmd_url "$@";;
  tidewave) shift; cmd_tidewave "$@";;
  tidewave-latest) shift; cmd_tidewave_latest "$@";;
  agent-env) shift; cmd_agent_env "$@";;
  *) echo "usage: $0 {up [<ref>]|dirty [--port N] [--foreground]|ls|down <id|all>|gc|logs <id>|url <id>|tidewave <id>|tidewave-latest|agent-env <id>}" >&2; exit 2;;
esac
