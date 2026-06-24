#!/usr/bin/env bash
#
# Provision (or re-register) the self-hosted GitHub Actions runner that backs
# the PR gate (.github/workflows/pr-gate.yml). GitHub-hosted Actions are
# billing-blocked, so the PR gate runs here on the devbox.
#
# Run once per box. Idempotent: re-running re-registers with a fresh token.
# Requires: gh (authenticated with repo admin scope), curl, tar, and sudo for
# the systemd service install.
#
#   bash scripts/ensure-ci-runner.sh                 # install + start
#   bash scripts/ensure-ci-runner.sh --remove        # unregister + remove
#
# After install, mark the "PR gate / gate" check Required on master under
# Settings → Branches → branch protection (or via gh api — see AGENTS.md).

set -euo pipefail

REPO="${CI_RUNNER_REPO:-dl-alexandre/dev_ide}"
RUNNER_DIR="${CI_RUNNER_DIR:-$HOME/actions-runner}"
RUNNER_LABELS="${CI_RUNNER_LABELS:-self-hosted,devbox}"
RUNNER_NAME="${CI_RUNNER_NAME:-devbox-$(hostname -s)}"
RUNNER_VERSION="${CI_RUNNER_VERSION:-2.319.1}"

log() { printf '>>> %s\n' "$*"; }

# Use the repo-local credential helper, never an ambient GH_TOKEN (which shadows
# it — see AGENTS.md "Friction we hit").
gh_api() { env -u GH_TOKEN gh api "$@"; }

reg_token() {
  gh_api -X POST "repos/${REPO}/actions/runners/registration-token" -q .token
}

remove_runner() {
  if [[ -x "${RUNNER_DIR}/svc.sh" ]]; then
    log "stopping + uninstalling runner service"
    sudo "${RUNNER_DIR}/svc.sh" stop || true
    sudo "${RUNNER_DIR}/svc.sh" uninstall || true
  fi
  if [[ -x "${RUNNER_DIR}/config.sh" ]]; then
    log "unregistering runner from ${REPO}"
    (cd "${RUNNER_DIR}" && ./config.sh remove --token "$(reg_token)") || true
  fi
  log "removed. (runner dir ${RUNNER_DIR} left in place)"
}

if [[ "${1:-}" == "--remove" ]]; then
  remove_runner
  exit 0
fi

command -v gh >/dev/null || { echo "gh CLI required"; exit 1; }

if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
  log "downloading actions-runner ${RUNNER_VERSION} into ${RUNNER_DIR}"
  mkdir -p "${RUNNER_DIR}"
  arch="$(uname -m)"; case "$arch" in x86_64) rarch=x64;; aarch64|arm64) rarch=arm64;; *) echo "unsupported arch $arch"; exit 1;; esac
  tarball="actions-runner-linux-${rarch}-${RUNNER_VERSION}.tar.gz"
  curl -fsSL -o "${RUNNER_DIR}/${tarball}" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
  tar -xzf "${RUNNER_DIR}/${tarball}" -C "${RUNNER_DIR}"
  rm -f "${RUNNER_DIR}/${tarball}"
fi

log "registering runner '${RUNNER_NAME}' (labels: ${RUNNER_LABELS}) with ${REPO}"
(
  cd "${RUNNER_DIR}"
  # --replace makes re-runs idempotent if a runner with this name already exists.
  ./config.sh \
    --unattended --replace \
    --url "https://github.com/${REPO}" \
    --token "$(reg_token)" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}"
)

log "installing + starting the runner systemd service"
sudo "${RUNNER_DIR}/svc.sh" install
sudo "${RUNNER_DIR}/svc.sh" start

log "done. verify under repo Settings → Actions → Runners (status: Idle)."
log "then make 'PR gate / gate' a required check on master (see AGENTS.md)."
