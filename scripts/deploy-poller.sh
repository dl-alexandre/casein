#!/usr/bin/env bash
#
# On-box auto-deploy poller — the self-hosted replacement for the GitHub
# Actions deploy job while Actions is billing-blocked (see
# .github/workflows/deploy-devbox.yml, push trigger commented out).
#
# Driven by casein-deploy.timer (every ~2 min). Each tick:
#   1. Reads the deployed revision (CASEIN_GIT_REVISION in /etc/casein/casein.env).
#   2. Fetches origin/master.
#   3. If origin/master advanced past the deployed revision, builds a release
#      from a CLEAN DETACHED WORKTREE pinned to that exact SHA — never the
#      shared checkout, which agents keep dirty / on feature branches — then
#      activates it via deploy-devbox-release.sh.
#
# Trust model: after checking out a clean detached worktree at origin/master,
# this poller re-runs the same pre-push gate (`scripts/pre-push-check.sh`) before
# packaging the release. A push that bypassed the hook with `git push --no-verify`
# can still land on master, but it will not activate until the worktree gate passes.
#
# Idempotent and safe to run by hand or repeatedly: exits 0 with no action when
# origin/master already matches the deployed revision. Single-flight via flock,
# so an overlapping timer tick during a multi-minute build is a no-op.
#
# Migration safety: unattended runs refuse any target that adds files under
# priv/repo/migrations/. For a deliberate, attended service update only, run a
# single poller invocation with CASEIN_ALLOW_MIGRATION_DEPLOY=1. Do not persist
# this override in the timer service environment.
#
set -euo pipefail

# CASEIN_POLLER_ROOT is set by self_update() before it re-execs the canonical
# copy from a /tmp path — without it, ROOT would be derived from the temp $0 and
# point outside the repo, breaking every git call.
ROOT="${CASEIN_POLLER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
DEPLOY_ROOT="${CASEIN_DEPLOY_ROOT:-/opt/casein}"
WORKTREE="${CASEIN_DEPLOY_WORKTREE:-${DEPLOY_ROOT}/deploy-build}"
BRANCH="${CASEIN_DEPLOY_BRANCH:-master}"
LOCK="${CASEIN_DEPLOY_LOCK:-/tmp/casein-deploy-poller.lock}"
ACTIVE_RELEASE="${DEPLOY_ROOT}/release"
CURRENT_SOCK="${CASEIN_CURRENT_SOCK:-/run/casein/current.sock}"
CACHE_ROOT="${CASEIN_DEPLOY_CACHE_ROOT:-${DEPLOY_ROOT}/cache}"
LAST_DEPLOY_FILE="${CASEIN_LAST_DEPLOY_FILE:-/run/casein/last-deploy.json}"
CANONICAL_DEVBOX_HOST="casein.devbox.milcgroup.com"

log() { printf '>>> [deploy-poller] %s\n' "$*"; }

# Atomically records deploy-poller outcomes for the running release to read via
# Casein.Deployment.LastDeploy (/run/casein/last-deploy.json by default).
write_deploy_status() {
  local outcome="$1"
  local target_sha="${2:-}"
  local phase="${3:-}"
  local reason="${4:-}"
  local from_sha="${5:-}"

  local target_short="" from_short=""
  if [ -n "$target_sha" ]; then
    target_short="$(printf '%s' "$target_sha" | cut -c1-12)"
  fi
  if [ -n "$from_sha" ]; then
    from_short="$(printf '%s' "$from_sha" | cut -c1-12)"
  fi

  if [ "$outcome" = "in_progress" ]; then
    DEPLOY_STARTED_AT="${DEPLOY_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    export DEPLOY_STARTED_AT
    export DEPLOY_IN_FLIGHT=1
  else
    unset DEPLOY_IN_FLIGHT
  fi

  local tmp
  tmp="$(mktemp /tmp/last-deploy-XXXXXX.json)"

  OUTCOME="$outcome" \
  TARGET_SHA="$target_sha" \
  TARGET_SHORT="$target_short" \
  FROM_SHA="$from_sha" \
  FROM_SHORT="$from_short" \
  PHASE="$phase" \
  REASON="$reason" \
  STARTED_AT="${DEPLOY_STARTED_AT:-}" \
  FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  LAST_DEPLOY_TMP="$tmp" \
  python3 -c '
import json, os, sys

outcome = os.environ["OUTCOME"]
record = {
    "outcome": outcome,
    "target_sha": os.environ.get("TARGET_SHA") or None,
    "target_short": os.environ.get("TARGET_SHORT") or None,
    "from_sha": os.environ.get("FROM_SHA") or None,
    "from_short": os.environ.get("FROM_SHORT") or None,
    "phase": os.environ.get("PHASE") or None,
    "reason": os.environ.get("REASON") or None,
    "started_at": os.environ.get("STARTED_AT") or None,
    "finished_at": None if outcome == "in_progress" else os.environ.get("FINISHED_AT"),
}
path = os.environ["LAST_DEPLOY_TMP"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, separators=(",", ":"))
    handle.write("\n")
' || {
    rm -f "$tmp"
    log "warning: failed to encode ${LAST_DEPLOY_FILE}"
    return 0
  }

  # /run/casein is root-owned on the devbox; stage in /tmp then install atomically.
  if sudo install -o devbox -g devbox -m 664 "$tmp" "$LAST_DEPLOY_FILE" 2>/dev/null; then
    :
  elif install -o "$(id -un)" -g "$(id -gn)" -m 664 "$tmp" "$LAST_DEPLOY_FILE" 2>/dev/null; then
    :
  else
    log "warning: failed to write ${LAST_DEPLOY_FILE}"
  fi
  rm -f "$tmp"
}

record_deploy_failure() {
  local phase="$1"
  local reason="$2"
  write_deploy_status failed "${target:-}" "$phase" "$reason" "${deployed_full:-}"
}

setup_build_cache() {
  mkdir -p "${CACHE_ROOT}/mix-home" "${CACHE_ROOT}/hex-home" "${CACHE_ROOT}/mix-deps"
  export MIX_HOME="${MIX_HOME:-${CACHE_ROOT}/mix-home}"
  export HEX_HOME="${HEX_HOME:-${CACHE_ROOT}/hex-home}"
  export MIX_DEPS_PATH="${MIX_DEPS_PATH:-${CACHE_ROOT}/mix-deps}"
}

# --- self-update -------------------------------------------------------------
# casein-deploy.service execs this file straight out of the shared agent
# checkout (ROOT), which sits on arbitrary feature branches and carries stray
# uncommitted edits — so the deploy logic that runs would otherwise be hostage
# to whatever state the working tree happens to be in. Re-exec the canonical
# origin/<BRANCH> copy each tick so production deploy behaviour always tracks
# master, never the local tree.
#
# Read the canonical script via `git show` (object DB only) so the shared
# working tree + index are NEVER mutated. Re-exec only when it actually differs
# from what's running, and guard against an exec loop with an env flag. Every
# failure path falls through to the on-disk script (current behaviour), so a
# fetch hiccup can never block a deploy or the self-heal below.
self_update() {
  # Older installed pollers only staged this script before re-execing it. When
  # that copy first picks up companion-file support, hydrate the missing helper
  # once more instead of treating the legacy self-update flag as sufficient.
  if [ -n "${CASEIN_POLLER_SELFUPDATED:-}" ] &&
    [ -r "${CASEIN_POLLER_CADDY_LIB:-}" ]; then
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 0
  env -u GH_TOKEN -u GITHUB_TOKEN git -C "$ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null || return 0

  local canon_dir canon canon_caddy_lib
  canon_dir="$(mktemp -d "${TMPDIR:-/tmp}/deploy-poller-canon-XXXXXX")" || return 0
  canon="${canon_dir}/deploy-poller.sh"
  canon_caddy_lib="${canon_dir}/caddy-upstream.sh"
  if git -C "$ROOT" show "origin/${BRANCH}:scripts/deploy-poller.sh" >"$canon" 2>/dev/null &&
    git -C "$ROOT" show "origin/${BRANCH}:scripts/lib/caddy-upstream.sh" >"$canon_caddy_lib" 2>/dev/null &&
    [ -s "$canon" ] && [ -s "$canon_caddy_lib" ] &&
    { ! cmp -s "$canon" "$0" || [ ! -r "${CASEIN_POLLER_CADDY_LIB:-}" ]; }; then
    log "self-update: re-exec origin/${BRANCH} copy of deploy-poller.sh"
    exec env \
      CASEIN_POLLER_SELFUPDATED=1 \
      CASEIN_POLLER_CANON="$canon" \
      CASEIN_POLLER_CANON_DIR="$canon_dir" \
      CASEIN_POLLER_CADDY_LIB="$canon_caddy_lib" \
      CASEIN_POLLER_ROOT="$ROOT" \
      bash "$canon" "$@"
  fi
  rm -rf "$canon_dir"
}
self_update "$@"
# The re-exec'd run executes from a temp copy; unlink it on exit (the open inode
# keeps it valid for the lifetime of the run).
[ -n "${CASEIN_POLLER_CANON_DIR:-}" ] && trap 'rm -rf "${CASEIN_POLLER_CANON_DIR}"' EXIT

CADDY_UPSTREAM_LIB="${CASEIN_POLLER_CADDY_LIB:-${ROOT}/scripts/lib/caddy-upstream.sh}"
if [ ! -r "$CADDY_UPSTREAM_LIB" ]; then
  log "error: canonical Caddy helper is missing: ${CADDY_UPSTREAM_LIB}"
  exit 1
fi
# shellcheck source=scripts/lib/caddy-upstream.sh
source "$CADDY_UPSTREAM_LIB"

# --- liveness self-heal ------------------------------------------------------
# This box is multi-tenant: many concurrent agent sessions share one host and
# one systemd. The Casein release node gets terminated as collateral — by a
# neighbour's broad `pkill beam.smp`, a stray `systemctl stop casein-<uuid>`,
# or any signal that hits the BEAM. When that happens, the on-disk release at
# ${ACTIVE_RELEASE} is still valid and the deployed revision still matches
# origin/master, so the revision-only deploy check below says "nothing to do"
# and the outage persists indefinitely (the dead current.sock keeps serving
# 502s through Caddy/loopback).
#
# Guard against that: probe the active socket every tick. If nothing answers,
# relaunch an instance from the existing release via the same battle-tested
# activation path (deploy-devbox-release.sh handles the systemd-run start,
# API/MCP health checks, atomic symlink swap and stale-record cleanup). No
# rebuild — we repackage the already-activated release as-is. Turns any stray
# kill into a <=2-min blip instead of a hard outage.
ensure_live_instance() {
  local rev="$1"

  if [ ! -x "${ACTIVE_RELEASE}/bin/casein" ]; then
    log "self-heal: no release at ${ACTIVE_RELEASE} — skipping liveness check"
    return 0
  fi

  # A reachable socket returns *some* HTTP response (200/302/401); curl exits 0.
  # A dead/missing socket gives connection-refused (exit 7) — that is our cue.
  if curl -s -o /dev/null --max-time 5 --unix-socket "${CURRENT_SOCK}" \
      http://localhost/ >/dev/null 2>&1; then
    return 0
  fi

  log "self-heal: ${CURRENT_SOCK} is not answering — relaunching instance from ${ACTIVE_RELEASE}"

  local heal_tarball
  # Create the tarball as root outside /tmp. Linux sticky-dir protections can
  # reject sudo tar opening a devbox-owned mktemp file under /tmp.
  heal_tarball="$(sudo mktemp "${DEPLOY_ROOT}/casein-selfheal-XXXXXX.tgz")"
  if ! sudo tar -C "${ACTIVE_RELEASE}" -czf "${heal_tarball}" .; then
    log "self-heal: failed to package ${ACTIVE_RELEASE} — aborting heal"
    sudo rm -f "${heal_tarball}"
    return 1
  fi

  sudo chown "$(id -un):$(id -gn)" "${heal_tarball}"

  if "${ROOT}/scripts/deploy-devbox-release.sh" "${heal_tarball}" "${rev:-manual}"; then
    log "self-heal: instance relaunched from ${ACTIVE_RELEASE}"
  else
    log "self-heal: relaunch via deploy-devbox-release.sh FAILED"
  fi
  sudo rm -f "${heal_tarball}"
}

ensure_agent_shims() {
  local expected_rev="$1"
  local name missing=""

  if [ ! -x "${WORKTREE}/scripts/install-agent-shims.sh" ]; then
    log "agent shims: ${WORKTREE}/scripts/install-agent-shims.sh missing — skipping"
    return 0
  fi

  local worktree_rev
  worktree_rev="$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ "$worktree_rev" != "$expected_rev" ]; then
    log "agent shims: deploy worktree is not at target revision — skipping"
    return 0
  fi

  log "agent shims: installing from clean deploy worktree"
  if ! (cd "$WORKTREE" && bash scripts/install-agent-shims.sh >/dev/null); then
    log "agent shims: install FAILED — leaving existing shims in place"
  fi

  # Fail-loud completeness check even when install exited 0 but a later
  # clobber removed a single runtime (historically: claude missing, siblings ok).
  if ! (cd "$WORKTREE" && bash scripts/install-agent-shims.sh --check >/dev/null 2>&1); then
    missing=""
    for name in grok claude codex opencode agent casein; do
      if [ ! -x "${CASEIN_AGENT_BIN_DIR:-${HOME}/.casein/agent-shims}/${name}" ]; then
        missing="${missing} ${name}"
      fi
    done
    log "agent shims: INCOMPLETE after ensure — missing:${missing:- unknown}"
    log "agent shims: run: bash ${WORKTREE}/scripts/install-agent-shims.sh"
    return 1
  fi

  log "agent shims: complete (grok claude codex opencode agent casein)"
  return 0
}

ensure_caddy_upstream() {
  local host
  # This helper is sourced by a long-lived poller. Never let a prior eligible
  # outcome authorize the canonical attestation if this tick returns early.
  CADDY_RECONCILE_OUTCOME="not_attempted"

  host="$(
    if [ -r "$ENV_FILE" ]; then
      awk -F= '/^PHX_HOST=/{print $2}' "$ENV_FILE" | tail -n 1
    elif sudo test -r "$ENV_FILE" 2>/dev/null; then
      sudo awk -F= '/^PHX_HOST=/{print $2}' "$ENV_FILE" | tail -n 1
    fi
  )"
  host="${host:-${CANONICAL_DEVBOX_HOST}}"

  if [ "$host" != "$CANONICAL_DEVBOX_HOST" ]; then
    log "refusing Caddy reconciliation for non-canonical PHX_HOST=${host}"
    return 1
  fi

  casein_reconcile_caddy_upstream "$host" repair
}

read_casein_api_token() {
  casein_read_casein_api_token "$ENV_FILE"
}

canonical_route_attests_current_handoff() {
  local expected_revision="$1"
  local current_target=""
  local token=""

  current_target="$(readlink "$CURRENT_SOCK" 2>/dev/null || true)"
  token="$(read_casein_api_token)"

  casein_canonical_route_attests_caddy_unavailable \
    "$CANONICAL_DEVBOX_HOST" "$expected_revision" "$current_target" "$token"
}

# --- single-flight -----------------------------------------------------------
# A release build can outlast the timer interval; never run two at once.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy-poller run holds ${LOCK} — skipping this tick"
  exit 0
fi

# --- read the deployed revision ----------------------------------------------
# casein.env is sourced (set -a) by deploy-local.sh, so it's a normal env file.
# Read it tolerantly: plain source first, fall back to sudo if unreadable.
read_deployed() {
  local val=""
  if [ -r "$ENV_FILE" ]; then
    val="$(set -a; . "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${CASEIN_GIT_REVISION:-}")"
  elif sudo test -r "$ENV_FILE" 2>/dev/null; then
    val="$(sudo sed -n 's/^CASEIN_GIT_REVISION=//p' "$ENV_FILE" | tail -1)"
  fi
  printf '%s' "$val"
}

deployed="$(read_deployed)"

# --- fetch origin/master -----------------------------------------------------
# Clear ambient GH_TOKEN/GITHUB_TOKEN so they can't shadow the repo-local
# credential helper in .git/config (a known "repository not found" trap).
cd "$ROOT"
log "fetching origin/${BRANCH}"
env -u GH_TOKEN -u GITHUB_TOKEN git fetch --quiet origin "$BRANCH"

target="$(git rev-parse "origin/${BRANCH}")"
target_short="$(git rev-parse --short "origin/${BRANCH}")"

deployed_full=""
if [ -n "$deployed" ]; then
  deployed_full="$(git rev-parse --verify --quiet "${deployed}^{commit}" 2>/dev/null || true)"
fi

if [ "$deployed_full" = "$target" ]; then
  log "origin/${BRANCH} (${target_short}) already deployed — checking liveness"
  ensure_live_instance "${deployed:-$target}"
  if ! ensure_caddy_upstream; then
    if casein_caddy_reconcile_allows_attestation &&
        canonical_route_attests_current_handoff "$target"; then
      log "warning: retaining exact canonical route after Caddy admin unavailability"
    else
      write_deploy_status failed "$target" caddy \
        "canonical Caddy upstream repair failed" "$deployed_full"
      exit 1
    fi
  fi
  if [ "${CADDY_UPSTREAM_PATCHED:-0}" = "1" ] ||
    grep -q '"phase":"caddy"' "$LAST_DEPLOY_FILE" 2>/dev/null; then
    write_deploy_status success "$target" "" "" "$deployed_full"
  fi
  # Incomplete shims are worth a non-zero tick so journal/timer health shows red.
  ensure_agent_shims "$target"
  exit 0
fi

# Guard against deploying an older commit (e.g. a force-push / rollback on the
# box) unless explicitly allowed: only roll forward.
if [ -n "$deployed_full" ] && git merge-base --is-ancestor "$target" "$deployed_full" 2>/dev/null; then
  if [ "${CASEIN_DEPLOY_ALLOW_ROLLBACK:-0}" != "1" ]; then
    log "origin/${BRANCH} (${target_short}) is BEHIND deployed ${deployed:0:12} — refusing to roll back"
    log "set CASEIN_DEPLOY_ALLOW_ROLLBACK=1 to deploy it anyway"
    write_deploy_status failed "$target" rollback_refused \
      "origin/${BRANCH} (${target_short}) is behind deployed ${deployed:0:12}" \
      "$deployed_full"
    exit 0
  fi
  log "rolling BACK to ${target_short} (CASEIN_DEPLOY_ALLOW_ROLLBACK=1)"
fi

# Automatic deploys must never be the operation that introduces a database
# migration. deploy-devbox-release.sh runs bin/migrate as an ExecStartPre after
# replacing the active release directory, so this check must happen before the
# clean worktree, build, or activation path changes anything on disk.
migration_base="$deployed_full"
if [ -z "$migration_base" ]; then
  # With no trustworthy deployed revision, treat every migration in the target
  # as new. A deliberate local service update can establish the first revision.
  migration_base="$(git hash-object -t tree /dev/null)"
fi

mapfile -t new_migrations < <(
  git diff --name-only --diff-filter=A \
    "${migration_base}..${target}" -- priv/repo/migrations/
)

if [ "${#new_migrations[@]}" -gt 0 ] && [ "${CASEIN_ALLOW_MIGRATION_DEPLOY:-0}" != "1" ]; then
  log "automatic deploy REFUSED: ${target_short} introduces database migrations:"
  for migration in "${new_migrations[@]}"; do
    log "  ${migration}"
  done
  log "apply this revision with a deliberate local service update"
  log "attended override: CASEIN_ALLOW_MIGRATION_DEPLOY=1 bash scripts/deploy-poller.sh"
  migration_reason="automatic deploy refused: new migrations: $(
    IFS=,
    printf '%s' "${new_migrations[*]}"
  )"
  write_deploy_status failed "$target" migration_refused \
    "$migration_reason" "$deployed_full"
  exit 1
fi

if [ "${#new_migrations[@]}" -gt 0 ]; then
  log "migration deploy explicitly allowed by CASEIN_ALLOW_MIGRATION_DEPLOY=1:"
  for migration in "${new_migrations[@]}"; do
    log "  ${migration}"
  done
fi

if [ -n "$deployed" ]; then from_label="${deployed:0:12}"; else from_label="none"; fi
log "deploy due: ${from_label} -> ${target_short}"

write_deploy_status in_progress "$target" "" "" "$deployed_full"
trap 'if [ -n "${DEPLOY_IN_FLIGHT:-}" ]; then record_deploy_failure unexpected "deploy-poller exited during deploy"; fi' EXIT

# --- prepare a clean detached worktree at the target SHA ---------------------
mkdir -p "$(dirname "$WORKTREE")"
if git worktree list --porcelain | grep -Fx "worktree ${WORKTREE}" >/dev/null; then
  log "reusing worktree ${WORKTREE}"
  # The build and activation steps may leave tracked or untracked runtime
  # artifacts behind. Reset directly to the target so those leftovers cannot
  # block a preliminary checkout before the cleanup gets a chance to run.
  git -C "$WORKTREE" reset --hard --quiet "$target"
  git -C "$WORKTREE" clean -fdq
else
  log "creating worktree ${WORKTREE}"
  git -c advice.detachedHead=false worktree add --force --detach "$WORKTREE" "$target"
fi

# --- test gate (same suite as pre-push hook) ---------------------------------
setup_build_cache
write_deploy_status in_progress "$target" gate "" "$deployed_full"
log "using deploy cache ${CACHE_ROOT}"
log "running pre-push gate in worktree ${target_short}"
if ! ( cd "$WORKTREE" && mise exec -- bash scripts/pre-push-check.sh ); then
  log "error: pre-push gate failed in deploy worktree — aborting deploy"
  record_deploy_failure gate "pre-push gate failed"
  trap - EXIT
  exit 1
fi

# --- build + activate --------------------------------------------------------
write_deploy_status in_progress "$target" build "" "$deployed_full"
log "building release from ${target_short}"
if ! ( cd "$WORKTREE" && ./scripts/build-release.sh ); then
  log "error: build-release.sh failed — aborting deploy"
  record_deploy_failure build "build-release.sh failed"
  trap - EXIT
  exit 1
fi

# Fail fast if the build did not actually populate release-out, rather than
# packaging an empty/partial tarball and failing later in activation.
if [ ! -d "$WORKTREE/release-out" ] || [ -z "$(ls -A "$WORKTREE/release-out" 2>/dev/null)" ]; then
  log "error: build produced no release-out artifacts — aborting deploy"
  record_deploy_failure build "build produced no release-out artifacts"
  trap - EXIT
  exit 1
fi

tarball="$(mktemp /tmp/casein-autodeploy-XXXXXX.tgz)"
trap 'rm -f "$tarball"' EXIT
tar -C "$WORKTREE/release-out" -czf "$tarball" .

write_deploy_status in_progress "$target" activate "" "$deployed_full"
log "activating ${target_short} via deploy-devbox-release.sh"
if ! "$WORKTREE/scripts/deploy-devbox-release.sh" "$tarball" "$target"; then
  log "error: deploy-devbox-release.sh failed — aborting deploy"
  record_deploy_failure activate "deploy-devbox-release.sh failed"
  trap - EXIT
  exit 1
fi

# Release is already live; do not roll back success status if only shims fail.
if ! ensure_agent_shims "$target"; then
  log "agent shims incomplete after successful activation — release is live; re-run install-agent-shims.sh"
fi

write_deploy_status success "$target" "" "" "$deployed_full"
trap - EXIT

log "deployed ${target_short} to ${DEPLOY_ROOT}/release"
