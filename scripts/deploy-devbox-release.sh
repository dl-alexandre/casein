#!/usr/bin/env bash
#
# Deploy a prebuilt DevIDE release tarball on the devbox host.
#
# Intended caller:
#   scripts/build-release.sh
#   tar -C release-out -czf /tmp/dev_ide-release.tgz .
#   ssh devbox@host 'bash -s' -- /tmp/dev_ide-release.tgz < scripts/deploy-devbox-release.sh

set -euo pipefail

TARBALL="${1:?usage: deploy-devbox-release.sh /path/to/release.tgz [revision]}"
REVISION="${2:-manual}"

APP_ROOT="${DEV_IDE_DEPLOY_ROOT:-/opt/devide}"
SERVICE="${DEV_IDE_SYSTEMD_SERVICE:-devide}"
ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
USER_NAME="${DEV_IDE_DEPLOY_USER:-devbox}"
GROUP_NAME="${DEV_IDE_DEPLOY_GROUP:-devbox}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
STAGING="${APP_ROOT}/release.staging.${REVISION}.${TS}"
FAILED_RELEASE="${APP_ROOT}/release.failed.${REVISION}.${TS}"
ACTIVE_RELEASE="${APP_ROOT}/release"
PREVIOUS_RELEASE="${APP_ROOT}/release.prev"
DEPLOY_STARTED=0
SUCCESS=0

log() {
  printf '>>> %s\n' "$*"
}

rollback() {
  status=$?

  if [ "${SUCCESS}" = "1" ] || [ "${DEPLOY_STARTED}" != "1" ]; then
    exit "${status}"
  fi

  log "deploy failed; attempting rollback to ${PREVIOUS_RELEASE}"
  sudo systemctl stop "${SERVICE}" >/dev/null 2>&1 || true

  if sudo test -e "${ACTIVE_RELEASE}"; then
    sudo mv "${ACTIVE_RELEASE}" "${FAILED_RELEASE}" || true
  fi

  if sudo test -e "${PREVIOUS_RELEASE}"; then
    sudo mv "${PREVIOUS_RELEASE}" "${ACTIVE_RELEASE}"
    sudo "${ACTIVE_RELEASE}/bin/activate_devbox_deploy" || true
    sudo systemctl restart "${SERVICE}" || true
  fi

  exit "${status}"
}

trap rollback EXIT

if [ ! -f "${TARBALL}" ]; then
  echo "error: release tarball not found: ${TARBALL}" >&2
  exit 1
fi

log "extracting ${TARBALL} to ${STAGING}"
sudo rm -rf "${STAGING}"
sudo mkdir -p "${STAGING}"
sudo tar -xzf "${TARBALL}" -C "${STAGING}"

sudo test -x "${STAGING}/bin/dev_ide"
sudo test -x "${STAGING}/bin/migrate"
sudo test -f "${STAGING}/deploy/devide.service"
sudo test -f "${STAGING}/deploy/docker-compose.postgres.yml"

log "placing release under ${ACTIVE_RELEASE}"
if sudo test -e "${PREVIOUS_RELEASE}"; then
  sudo mv "${PREVIOUS_RELEASE}" "${PREVIOUS_RELEASE}.${TS}"
fi

if sudo test -e "${ACTIVE_RELEASE}"; then
  sudo mv "${ACTIVE_RELEASE}" "${PREVIOUS_RELEASE}"
fi

DEPLOY_STARTED=1
sudo mv "${STAGING}" "${ACTIVE_RELEASE}"
sudo chown -R "${USER_NAME}:${GROUP_NAME}" "${ACTIVE_RELEASE}"

log "activating deploy artifacts"
sudo "${ACTIVE_RELEASE}/bin/activate_devbox_deploy"

scripts_dir="$(
  sudo find "${ACTIVE_RELEASE}/lib" -maxdepth 4 -type d -path '*/priv/scripts' -print -quit 2>/dev/null
)"

if [ -n "${scripts_dir}" ] &&
  sudo test -f "${scripts_dir}/node_modules/playwright/cli.js" &&
  command -v node >/dev/null 2>&1; then
  log "ensuring Chromium is installed for ${USER_NAME}"
  (
    cd "${scripts_dir}"
    sudo -u "${USER_NAME}" env HOME="/home/${USER_NAME}" \
      node node_modules/playwright/cli.js install chromium
  )
fi

log "restarting ${SERVICE}"
sudo systemctl restart "${SERVICE}"
systemctl is-active --quiet "${SERVICE}"

token="$(
  sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "${ENV_FILE}" |
    tail -n 1
)"

if [ -z "${token}" ]; then
  echo "error: DEV_IDE_API_TOKEN missing from ${ENV_FILE}" >&2
  exit 1
fi

log "waiting for ${SERVICE} API readiness"
api_ready=0
for _ in $(seq 1 60); do
  if curl -fsS \
    -H "authorization: Bearer ${token}" \
    http://127.0.0.1:4000/api/workspaces >/dev/null 2>&1; then
    api_ready=1
    break
  fi

  sleep 1
done

if [ "${api_ready}" != "1" ]; then
  echo "error: ${SERVICE} API did not become ready within 60 seconds" >&2
  exit 1
fi

log "smoke checking Preview MCP"
tools_json="$(
  curl -fsS -X POST http://127.0.0.1:4000/api/preview/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${tools_json}" | grep -q '"preview_open_app"'
printf '%s' "${tools_json}" | grep -q '"preview_close"'

log "recent ${SERVICE} warnings/errors, if any"
sudo journalctl -u "${SERVICE}" --since "2 minutes ago" --no-pager |
  grep -Ei 'error|failed|warning' || true

SUCCESS=1
log "deployed ${REVISION} to ${ACTIVE_RELEASE}"
