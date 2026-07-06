#!/usr/bin/env bash
#
# On-box auto-deploy poller — the self-hosted replacement for the GitHub
# Actions deploy job while Actions is billing-blocked (see
# .github/workflows/deploy-devbox.yml, push trigger commented out).
#
# Driven by devide-deploy.timer (every ~2 min). Each tick:
#   1. Reads the deployed revision (DEVIDE_GIT_REVISION in /etc/devide/devide.env).
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
set -euo pipefail

# DEVIDE_POLLER_ROOT is set by self_update() before it re-execs the canonical
# copy from a /tmp path — without it, ROOT would be derived from the temp $0 and
# point outside the repo, breaking every git call.
ROOT="${DEVIDE_POLLER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
DEPLOY_ROOT="${DEV_IDE_DEPLOY_ROOT:-/opt/devide}"
WORKTREE="${DEVIDE_DEPLOY_WORKTREE:-${DEPLOY_ROOT}/deploy-build}"
BRANCH="${DEVIDE_DEPLOY_BRANCH:-master}"
LOCK="${DEVIDE_DEPLOY_LOCK:-/tmp/devide-deploy-poller.lock}"
ACTIVE_RELEASE="${DEPLOY_ROOT}/release"
CURRENT_SOCK="${DEVIDE_CURRENT_SOCK:-/run/devide/current.sock}"
CACHE_ROOT="${DEVIDE_DEPLOY_CACHE_ROOT:-${DEPLOY_ROOT}/cache}"

log() { printf '>>> [deploy-poller] %s\n' "$*"; }

setup_build_cache() {
  mkdir -p "${CACHE_ROOT}/mix-home" "${CACHE_ROOT}/hex-home" "${CACHE_ROOT}/mix-deps"
  export MIX_HOME="${MIX_HOME:-${CACHE_ROOT}/mix-home}"
  export HEX_HOME="${HEX_HOME:-${CACHE_ROOT}/hex-home}"
  export MIX_DEPS_PATH="${MIX_DEPS_PATH:-${CACHE_ROOT}/mix-deps}"
}

# --- self-update -------------------------------------------------------------
# devide-deploy.service execs this file straight out of the shared agent
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
  [ -n "${DEVIDE_POLLER_SELFUPDATED:-}" ] && return 0  # already re-exec'd this tick
  command -v git >/dev/null 2>&1 || return 0
  env -u GH_TOKEN -u GITHUB_TOKEN git -C "$ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null || return 0

  local canon
  canon="$(mktemp "${TMPDIR:-/tmp}/deploy-poller-canon-XXXXXX.sh")" || return 0
  if git -C "$ROOT" show "origin/${BRANCH}:scripts/deploy-poller.sh" >"$canon" 2>/dev/null &&
    [ -s "$canon" ] && ! cmp -s "$canon" "$0"; then
    log "self-update: re-exec origin/${BRANCH} copy of deploy-poller.sh"
    exec env DEVIDE_POLLER_SELFUPDATED=1 DEVIDE_POLLER_CANON="$canon" DEVIDE_POLLER_ROOT="$ROOT" bash "$canon" "$@"
  fi
  rm -f "$canon"
}
self_update "$@"
# The re-exec'd run executes from a temp copy; unlink it on exit (the open inode
# keeps it valid for the lifetime of the run).
[ -n "${DEVIDE_POLLER_CANON:-}" ] && trap 'rm -f "${DEVIDE_POLLER_CANON}"' EXIT

# --- liveness self-heal ------------------------------------------------------
# This box is multi-tenant: many concurrent agent sessions share one host and
# one systemd. The DevIDE release node gets terminated as collateral — by a
# neighbour's broad `pkill beam.smp`, a stray `systemctl stop devide-<uuid>`,
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

  if [ ! -x "${ACTIVE_RELEASE}/bin/dev_ide" ]; then
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
  heal_tarball="$(sudo mktemp "${DEPLOY_ROOT}/dev_ide-selfheal-XXXXXX.tgz")"
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
    log "agent shims: install failed — leaving existing shims in place"
  fi
}

# --- single-flight -----------------------------------------------------------
# A release build can outlast the timer interval; never run two at once.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another deploy-poller run holds ${LOCK} — skipping this tick"
  exit 0
fi

# --- read the deployed revision ----------------------------------------------
# devide.env is sourced (set -a) by deploy-local.sh, so it's a normal env file.
# Read it tolerantly: plain source first, fall back to sudo if unreadable.
read_deployed() {
  local val=""
  if [ -r "$ENV_FILE" ]; then
    val="$(set -a; . "$ENV_FILE" >/dev/null 2>&1; printf '%s' "${DEVIDE_GIT_REVISION:-}")"
  elif sudo test -r "$ENV_FILE" 2>/dev/null; then
    val="$(sudo sed -n 's/^DEVIDE_GIT_REVISION=//p' "$ENV_FILE" | tail -1)"
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
  ensure_agent_shims "$target"
  exit 0
fi

# Guard against deploying an older commit (e.g. a force-push / rollback on the
# box) unless explicitly allowed: only roll forward.
if [ -n "$deployed_full" ] && git merge-base --is-ancestor "$target" "$deployed_full" 2>/dev/null; then
  if [ "${DEVIDE_DEPLOY_ALLOW_ROLLBACK:-0}" != "1" ]; then
    log "origin/${BRANCH} (${target_short}) is BEHIND deployed ${deployed:0:12} — refusing to roll back"
    log "set DEVIDE_DEPLOY_ALLOW_ROLLBACK=1 to deploy it anyway"
    exit 0
  fi
  log "rolling BACK to ${target_short} (DEVIDE_DEPLOY_ALLOW_ROLLBACK=1)"
fi

if [ -n "$deployed" ]; then from_label="${deployed:0:12}"; else from_label="none"; fi
log "deploy due: ${from_label} -> ${target_short}"

# --- prepare a clean detached worktree at the target SHA ---------------------
mkdir -p "$(dirname "$WORKTREE")"
if git worktree list --porcelain | grep -Fx "worktree ${WORKTREE}" >/dev/null; then
  log "reusing worktree ${WORKTREE}"
  git -C "$WORKTREE" -c advice.detachedHead=false checkout --detach --quiet "$target"
  git -C "$WORKTREE" reset --hard --quiet "$target"
  git -C "$WORKTREE" clean -fdq
else
  log "creating worktree ${WORKTREE}"
  git -c advice.detachedHead=false worktree add --force --detach "$WORKTREE" "$target"
fi

# --- test gate (same suite as pre-push hook) ---------------------------------
setup_build_cache
log "using deploy cache ${CACHE_ROOT}"
log "running pre-push gate in worktree ${target_short}"
if ! ( cd "$WORKTREE" && bash scripts/pre-push-check.sh ); then
  log "error: pre-push gate failed in deploy worktree — aborting deploy"
  exit 1
fi

# --- build + activate --------------------------------------------------------
log "building release from ${target_short}"
( cd "$WORKTREE" && ./scripts/build-release.sh )

# Fail fast if the build did not actually populate release-out, rather than
# packaging an empty/partial tarball and failing later in activation.
if [ ! -d "$WORKTREE/release-out" ] || [ -z "$(ls -A "$WORKTREE/release-out" 2>/dev/null)" ]; then
  log "error: build produced no release-out artifacts — aborting deploy"
  exit 1
fi

tarball="$(mktemp /tmp/dev_ide-autodeploy-XXXXXX.tgz)"
trap 'rm -f "$tarball"' EXIT
tar -C "$WORKTREE/release-out" -czf "$tarball" .

log "activating ${target_short} via deploy-devbox-release.sh"
"$WORKTREE/scripts/deploy-devbox-release.sh" "$tarball" "$target"

ensure_agent_shims "$target"

log "deployed ${target_short} to ${DEPLOY_ROOT}/release"
