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
# Trust model: this poller only builds + deploys. It does NOT re-run the test
# suite — the .githooks/pre-push gate already runs the full suite + coverage at
# push time. A deliberate `git push --no-verify` that skips that gate will
# still auto-deploy here, by design.
#
# Idempotent and safe to run by hand or repeatedly: exits 0 with no action when
# origin/master already matches the deployed revision. Single-flight via flock,
# so an overlapping timer tick during a multi-minute build is a no-op.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
DEPLOY_ROOT="${DEV_IDE_DEPLOY_ROOT:-/opt/devide}"
WORKTREE="${DEVIDE_DEPLOY_WORKTREE:-${DEPLOY_ROOT}/deploy-build}"
BRANCH="${DEVIDE_DEPLOY_BRANCH:-master}"
LOCK="${DEVIDE_DEPLOY_LOCK:-/tmp/devide-deploy-poller.lock}"

log() { printf '>>> [deploy-poller] %s\n' "$*"; }

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
  log "origin/${BRANCH} (${target_short}) already deployed — nothing to do"
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
if git worktree list --porcelain | grep -qx "worktree ${WORKTREE}"; then
  log "reusing worktree ${WORKTREE}"
  git -C "$WORKTREE" -c advice.detachedHead=false checkout --detach --quiet "$target"
  git -C "$WORKTREE" reset --hard --quiet "$target"
  git -C "$WORKTREE" clean -fdq
else
  log "creating worktree ${WORKTREE}"
  git -c advice.detachedHead=false worktree add --force --detach "$WORKTREE" "$target"
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

log "deployed ${target_short} to ${DEPLOY_ROOT}/release"
