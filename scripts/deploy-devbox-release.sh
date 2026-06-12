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
RELEASE_BACKUP_KEEP="${DEV_IDE_RELEASE_BACKUP_KEEP:-5}"
DEPLOY_STARTED=0
SUCCESS=0

log() {
  printf '>>> %s\n' "$*"
}

cleanup_release_backup_pattern() {
  pattern="$1"
  keep="$2"
  count=0

  while IFS= read -r -d '' dir; do
    count=$((count + 1))

    if [ "${count}" -le "${keep}" ]; then
      continue
    fi

    case "${dir}" in
      "${APP_ROOT}"/release.prev.* | "${APP_ROOT}"/release.failed.*)
        log "removing old release backup ${dir}"
        sudo rm -rf -- "${dir}" || log "warning: failed to remove ${dir}"
        ;;
      *)
        log "skipping unexpected release backup path ${dir}"
        ;;
    esac
  done < <(
    sudo find "${APP_ROOT}" -mindepth 1 -maxdepth 1 -type d -name "${pattern}" \
      -printf '%T@\t%p\0' 2>/dev/null |
      sort -z -nr |
      cut -z -f2-
  )

  return 0
}

cleanup_release_backups() {
  if ! [[ "${RELEASE_BACKUP_KEEP}" =~ ^[0-9]+$ ]]; then
    log "warning: invalid DEV_IDE_RELEASE_BACKUP_KEEP=${RELEASE_BACKUP_KEEP}; skipping release backup cleanup"
    return 0
  fi

  log "keeping last ${RELEASE_BACKUP_KEEP} timestamped release backups per kind"
  cleanup_release_backup_pattern 'release.prev.*' "${RELEASE_BACKUP_KEEP}"
  cleanup_release_backup_pattern 'release.failed.*' "${RELEASE_BACKUP_KEEP}"
  return 0
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

log "ensuring RELEASE_COOKIE is pinned in ${ENV_FILE}"
# Without a pinned RELEASE_COOKIE the release auto-generates a fresh cookie at
# every boot (releases/COOKIE), so the running node's cookie diverges from the
# on-disk file and peer commands (`bin/dev_ide stop`, `rpc`, health probes) fail
# the distribution challenge (:noconnection). That makes the graceful ExecStop
# fail and every deploy hard-SIGTERM the node mid-session, draining LiveView
# sockets and killing live tmux terminals. Generate + persist one if absent, so
# the cookie stays stable across deploys and env-file regens. Idempotent: a
# value already present (or supplied via devide.env.example) is left untouched.
if ! sudo grep -qE '^RELEASE_COOKIE=.+' "${ENV_FILE}"; then
  # Generate a URL-safe 48-char cookie. Use openssl (a documented runtime dep,
  # shipped with the release) over `tr </dev/urandom | head` — the latter trips
  # SIGPIPE under `set -o pipefail` and would abort the deploy. Fall back to a
  # bounded dd read if openssl is somehow unavailable.
  if command -v openssl >/dev/null 2>&1; then
    generated_cookie="$(openssl rand -hex 24)"
  else
    generated_cookie="$(
      LC_ALL=C dd if=/dev/urandom bs=1 count=192 2>/dev/null |
        tr -dc 'A-Za-z0-9' | cut -c1-48
    )"
  fi

  if [ "${#generated_cookie}" -lt 32 ]; then
    echo "error: failed to generate a RELEASE_COOKIE" >&2
    exit 1
  fi

  # Drop any blank/placeholder RELEASE_COOKIE= line, then append the pinned one.
  sudo sed -i '/^RELEASE_COOKIE=$/d' "${ENV_FILE}"
  printf 'RELEASE_COOKIE=%s\n' "${generated_cookie}" |
    sudo tee -a "${ENV_FILE}" >/dev/null
  sudo chmod 600 "${ENV_FILE}"
  log "generated and pinned a new RELEASE_COOKIE"
else
  log "RELEASE_COOKIE already pinned; leaving it untouched"
fi

token="$(
  sudo awk -F= '/^DEV_IDE_API_TOKEN=/{print $2}' "${ENV_FILE}" |
    tail -n 1
)"

log "pinning DEVIDE_GIT_REVISION=${REVISION} in ${ENV_FILE}"
sudo sed -i '/^DEVIDE_GIT_REVISION=/d' "${ENV_FILE}"
printf 'DEVIDE_GIT_REVISION=%s\n' "${REVISION}" | sudo tee -a "${ENV_FILE}" >/dev/null

log "signalling running instance to drain (if any)"
drain_signalled=0
inst_dir=""
if [ -d "/run/devide/instances" ]; then
  inst_dir="/run/devide/instances"
elif [ -d "/tmp/devide/instances" ]; then
  inst_dir="/tmp/devide/instances"
fi
if [ -n "${inst_dir}" ] && [ -n "${token}" ]; then
  for inst_file in "${inst_dir}"/*.json; do
    [ -f "${inst_file}" ] || continue
    inst_port="$(grep -o '"http_port":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4)"
    [ -z "${inst_port}" ] && inst_port="4000"
    old_revision="$(grep -o '"version":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    commits_behind=0
    if [ -n "${old_revision}" ] && [ "${old_revision}" != "dev" ] && \
       git cat-file -e "${old_revision}" 2>/dev/null; then
      commits_behind="$(git rev-list "${old_revision}..HEAD" --count 2>/dev/null || echo 0)"
    fi
    if curl -fsS -X POST \
      -H "authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      -d "{\"commits_behind\": ${commits_behind}}" \
      "http://127.0.0.1:${inst_port}/api/drain" >/dev/null 2>&1; then
      log "drain signalled on port ${inst_port} (${commits_behind} commits behind) — clients will see update banner"
      drain_signalled=1
    fi
  done
fi
[ "${drain_signalled}" = "0" ] && log "no running instance found to drain (first deploy or not registered)"

log "restarting ${SERVICE}"
sudo systemctl restart "${SERVICE}"
systemctl is-active --quiet "${SERVICE}"

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

log "smoke checking Preview MCP and Terminal MCP"
tools_json="$(
  curl -fsS -X POST http://127.0.0.1:4000/api/preview/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${tools_json}" | grep -q '"preview_open_app"'
printf '%s' "${tools_json}" | grep -q '"preview_close"'

terminal_tools_json="$(
  curl -fsS -X POST http://127.0.0.1:4000/api/terminals/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${terminal_tools_json}" | grep -q '"terminal_list_sessions"'
printf '%s' "${terminal_tools_json}" | grep -q '"terminal_capture"'

log "recent ${SERVICE} warnings/errors, if any"
sudo journalctl -u "${SERVICE}" --since "2 minutes ago" --no-pager |
  grep -Ei 'error|failed|warning' || true

SUCCESS=1
cleanup_release_backups || log "warning: release backup cleanup failed"
log "deployed ${REVISION} to ${ACTIVE_RELEASE}"
