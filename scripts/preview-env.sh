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
#   preview-env.sh ls
#   preview-env.sh down <id|all> [--keep-db]
#   preview-env.sh gc                                  # reap dead instances
#   preview-env.sh logs <id>
#   preview-env.sh url  <id>
#
# State lives on the SAME filesystem as the repo so _build can be hardlink-copied
# (cp -al) into each worktree — turning a ~47s cold compile into a ~8s one.
#
# NOTE: this builds a *committed ref*. To preview uncommitted working-tree edits,
# use scripts/dev-preview-instance.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${DEVIDE_PREVIEW_HOME:-$(dirname "$ROOT")/.devide-preview}"
INST_DIR="$STATE/instances"
WT_DIR="$STATE/worktrees"
WS_DIR="$STATE/workspaces"
LOG_DIR="$STATE/logs"
PORT_BASE="${DEVIDE_PREVIEW_PORT_BASE:-41000}"
PORT_MAX="${DEVIDE_PREVIEW_PORT_MAX:-41099}"
MISE=(mise exec elixir@1.20.0-otp-28 erlang@28.5 --)

mkdir -p "$INST_DIR" "$WT_DIR" "$WS_DIR" "$LOG_DIR"

log() { printf '>>> %s\n' "$*" >&2; }
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
port_taken() {
  ss -tln 2>/dev/null | grep -q ":$1 " && return 0
  grep -lq "\"port\":\"$1\"" "$INST_DIR"/*.json 2>/dev/null && return 0
  return 1
}
alloc_port() {
  local p
  for p in $(seq "$PORT_BASE" "$PORT_MAX"); do
    port_taken "$p" || { printf '%s' "$p"; return 0; }
  done
  die "no free port in $PORT_BASE-$PORT_MAX"
}
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
router_sync() { bash "$ROOT/scripts/preview-router.sh" reload >/dev/null 2>&1 || true; }

seed_sandbox() {
  local dir="$1/preview-sandbox"
  [ -d "$dir/.git" ] && return 0
  mkdir -p "$dir/lib"
  printf '# Preview Sandbox\n\nThrowaway workspace for an ephemeral DevIDE preview env.\n' > "$dir/README.md"
  printf 'defmodule Sandbox do\n  def hello, do: :world\nend\n' > "$dir/lib/sandbox.ex"
  ( cd "$dir" && git init -q \
      && git -c user.email=dev@local -c user.name=dev add -A \
      && git -c user.email=dev@local -c user.name=dev commit -qm "seed" )
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
  local port="${want_port:-$(alloc_port)}"
  port_taken "$port" && [ -n "$want_port" ] && die "port $port is taken"

  log "[$id] ref=$ref sha=$sha port=$port db=$db"

  log "[$id] creating worktree"
  git -C "$ROOT" worktree add --detach "$wt" "$sha" >/dev/null 2>&1 || die "worktree add failed"
  ln -sfn "$ROOT/deps" "$wt/deps"
  ln -sfn "$ROOT/assets/node_modules" "$wt/assets/node_modules"
  ln -sfn "$ROOT/priv/scripts/node_modules" "$wt/priv/scripts/node_modules"
  log "[$id] hardlinking _build (fast compile)"
  cp -al "$ROOT/_build" "$wt/_build" 2>/dev/null || cp -a "$ROOT/_build" "$wt/_build" 2>/dev/null || true

  seed_sandbox "$ws"

  export DATABASE_URL; DATABASE_URL="$(db_url_for "$db")"
  ( cd "$wt"
    log "[$id] ecto.create + migrate"
    "${MISE[@]}" mix ecto.create --quiet 2>/dev/null || true
    "${MISE[@]}" mix ecto.migrate >/dev/null
    log "[$id] building assets"
    "${MISE[@]}" mix assets.build >/dev/null 2>&1 \
      || { log "[$id] assets.build failed — building CSS only"; "${MISE[@]}" mix tailwind dev_ide >/dev/null 2>&1 || true; }
  )

  log "[$id] booting phx.server"
  ( cd "$wt"
    MIX_ENV=dev PHX_SERVER=true PORT="$port" \
      DEV_IDE_WORKSPACE_SOURCE=local DEV_IDE_WORKSPACES_ROOT="$ws" \
      DATABASE_URL="$(db_url_for "$db")" \
      nohup "${MISE[@]}" mix phx.server > "$logf" 2>&1 &
  )

  local up=0 i
  for i in $(seq 1 60); do ss -tln 2>/dev/null | grep -q ":$port " && { up=1; break; }; sleep 1; done
  [ "$up" = 1 ] || { log "[$id] did not come up — see $logf"; tail -5 "$logf" >&2 || true; }
  local pid; pid="$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"

  printf '{"id":"%s","ref":"%s","sha":"%s","port":"%s","pid":"%s","db":"%s","worktree":"%s","workspaces_root":"%s","log":"%s","started_at":"%s","status":"%s"}\n' \
    "$id" "$ref" "$sha" "$port" "${pid:-}" "$db" "$wt" "$ws" "$logf" "$(date -u +%FT%TZ)" "$([ "$up" = 1 ] && echo running || echo failed)" \
    > "$INST_DIR/$id.json"

  router_sync

  echo
  echo "  id:    $id"
  echo "  local: http://127.0.0.1:$port/workspaces/preview-sandbox?host=local"
  echo "  url:   https://$id.${DEVIDE_PREVIEW_DOMAIN:-devbox.milcgroup.com}/workspaces/preview-sandbox?host=local  (once edge hookup is live)"
  echo "  shot:  node $ROOT/scripts/dev-preview-shot.mjs http://127.0.0.1:$port/workspaces/preview-sandbox?host=local out.png 390x844"
  echo "  logs:  $0 logs $id"
  [ "$keep" = 1 ] && echo "  (--keep: env left running)"
}

cmd_ls() {
  shopt -s nullglob
  local files=("$INST_DIR"/*.json)
  [ ${#files[@]} -eq 0 ] && { echo "(no preview environments)"; return 0; }
  printf '%-16s %-10s %-6s %-8s %-22s %s\n' ID REF PORT PID STARTED URL
  local f
  for f in "${files[@]}"; do
    local id ref port pid started
    id="$(json_get "$f" id)"; ref="$(json_get "$f" ref)"; port="$(json_get "$f" port)"
    pid="$(json_get "$f" pid)"; started="$(json_get "$f" started_at)"
    local alive="dead"; pid_alive "$pid" && alive="$pid"
    printf '%-16s %-10s %-6s %-8s %-22s http://127.0.0.1:%s/\n' "$id" "$ref" "$port" "$alive" "$started" "$port"
  done
}

teardown() {
  local f="$1" keep_db="$2"
  [ -f "$f" ] || return 0
  local id pid db wt ws logf
  id="$(json_get "$f" id)"; pid="$(json_get "$f" pid)"; db="$(json_get "$f" db)"
  wt="$(json_get "$f" worktree)"; ws="$(json_get "$f" workspaces_root)"; logf="$(json_get "$f" log)"
  log "[$id] stopping (pid=$pid)"
  if pid_alive "$pid"; then kill "$pid" 2>/dev/null || true; sleep 2; pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true; fi
  if [ "$keep_db" != 1 ] && [ -n "$db" ]; then
    log "[$id] dropping db $db"; psql_admin -tAc "DROP DATABASE IF EXISTS \"$db\";" >/dev/null 2>&1 || true
  fi
  [ -n "$wt" ] && [ -d "$wt" ] && git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  [ -n "$ws" ] && rm -rf "$ws"
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
cmd_url()  { local f="$INST_DIR/${1:?usage: url <id>}.json"; [ -f "$f" ] || die "no such env"; echo "http://127.0.0.1:$(json_get "$f" port)/workspaces/preview-sandbox?host=local"; }

case "${1:-}" in
  up)   shift; cmd_up "$@";;
  ls)   shift; cmd_ls "$@";;
  down) shift; cmd_down "$@";;
  gc)   shift; cmd_gc "$@";;
  logs) shift; cmd_logs "$@";;
  url)  shift; cmd_url "$@";;
  *) echo "usage: $0 {up [<ref>]|ls|down <id|all>|gc|logs <id>|url <id>}" >&2; exit 2;;
esac
