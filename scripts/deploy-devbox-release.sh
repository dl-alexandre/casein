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
DEPLOY_ID="${TS}.$$"
STAGING="${APP_ROOT}/release.staging.${REVISION}.${TS}"
FAILED_RELEASE="${APP_ROOT}/release.failed.${REVISION}.${DEPLOY_ID}"
ACTIVE_RELEASE="${APP_ROOT}/release"
PREVIOUS_RELEASE="${APP_ROOT}/release.prev"
RELEASE_BACKUP_KEEP="${DEV_IDE_RELEASE_BACKUP_KEEP:-5}"
ENV_BACKUP="${ENV_FILE}.prev.${REVISION}.${DEPLOY_ID}"
INST_DIR="/run/devide/instances"
CURRENT_SYMLINK="/run/devide/current.sock"
OLD_CURRENT_TARGET=""
CURRENT_SYMLINK_SWAPPED=0
CADDY_UPSTREAM_PATCHED=0
CADDY_UPSTREAM_PATH=""
CADDY_PREVIOUS_DIAL=""
DEPLOY_STARTED=0
SUCCESS=0

log() {
  printf '>>> %s\n' "$*"
}

neutralize_legacy_service() {
  dropin_dir="/etc/systemd/system/${SERVICE}.service.d"

  log "installing no-op drop-in for legacy ${SERVICE}.service"
  sudo mkdir -p "${dropin_dir}"
  sudo tee "${dropin_dir}/90-devide-canary-noop.conf" >/dev/null <<EOF
# Managed by DevIDE deploy-devbox-release.sh.
# Traffic is served by transient devide-<uuid> units via /run/devide/current.sock.
# Keep the legacy enabled unit harmless on boot instead of binding the active socket.
[Service]
Type=oneshot
ExecStartPre=
ExecStart=
ExecStart=/bin/true
ExecStop=
Restart=no
RemainAfterExit=no
EOF
  sudo systemctl daemon-reload
  sudo systemctl reset-failed "${SERVICE}" >/dev/null 2>&1 || true
}

unique_path() {
  base="$1"
  candidate="${base}"
  counter=1

  while sudo test -e "${candidate}"; do
    candidate="${base}.${counter}"
    counter=$((counter + 1))
  done

  printf '%s\n' "${candidate}"
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

  log "deploy failed; stopping new canary unit and restoring release directory"
  # Stop the new transient unit if it was started; the old instance(s) are
  # still running and Caddy still points at the (unchanged) current.sock symlink
  # so existing sessions are unaffected.
  if [ -n "${NEW_UUID:-}" ]; then
    sudo systemctl stop "devide-${NEW_UUID}" >/dev/null 2>&1 || true
  fi

  if [ "${CURRENT_SYMLINK_SWAPPED}" = "1" ]; then
    if [ -n "${OLD_CURRENT_TARGET}" ]; then
      log "restoring ${CURRENT_SYMLINK} -> ${OLD_CURRENT_TARGET}"
      sudo ln -sfn "${OLD_CURRENT_TARGET}" "${CURRENT_SYMLINK}.rollback" || true
      sudo mv -f "${CURRENT_SYMLINK}.rollback" "${CURRENT_SYMLINK}" || true
    else
      log "removing ${CURRENT_SYMLINK}; it did not exist before this deploy"
      sudo rm -f "${CURRENT_SYMLINK}" "${CURRENT_SYMLINK}.rollback" || true
    fi
  fi

  if [ "${CADDY_UPSTREAM_PATCHED}" = "1" ] &&
    [ -n "${CADDY_UPSTREAM_PATH}" ] &&
    [ -n "${CADDY_PREVIOUS_DIAL}" ]; then
    log "restoring Caddy upstream to ${CADDY_PREVIOUS_DIAL}"
    sudo curl -fsS -X PATCH \
      "http://localhost:2019/config${CADDY_UPSTREAM_PATH}" \
      -H "content-type: application/json" \
      -d "\"${CADDY_PREVIOUS_DIAL}\"" >/dev/null || true
  fi

  if sudo test -f "${ENV_BACKUP}"; then
    log "restoring ${ENV_FILE} from ${ENV_BACKUP}"
    sudo cp -a "${ENV_BACKUP}" "${ENV_FILE}" || true
    sudo chmod 600 "${ENV_FILE}" || true
    sudo rm -f "${ENV_BACKUP}" || true
  fi

  if sudo test -e "${PREVIOUS_RELEASE}"; then
    if sudo test -e "${ACTIVE_RELEASE}"; then
      failed_release_path="$(unique_path "${FAILED_RELEASE}")"
      log "moving failed candidate release to ${failed_release_path}"
      sudo mv "${ACTIVE_RELEASE}" "${failed_release_path}" || true
    fi

    if sudo test -e "${ACTIVE_RELEASE}"; then
      log "warning: ${ACTIVE_RELEASE} still exists; cannot restore ${PREVIOUS_RELEASE}"
    else
      log "restoring previous release to ${ACTIVE_RELEASE}"
      sudo mv "${PREVIOUS_RELEASE}" "${ACTIVE_RELEASE}" || true
      sudo "${ACTIVE_RELEASE}/bin/activate_devbox_deploy" || true
    fi
  elif ! sudo test -e "${ACTIVE_RELEASE}"; then
    log "warning: no ${PREVIOUS_RELEASE} exists and ${ACTIVE_RELEASE} is missing"
  else
    log "warning: no ${PREVIOUS_RELEASE} exists; leaving ${ACTIVE_RELEASE} in place"
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

if [ -z "${token}" ]; then
  echo "error: DEV_IDE_API_TOKEN missing from ${ENV_FILE}" >&2
  exit 1
fi

sudo mkdir -p "${INST_DIR}"
sudo chown "${USER_NAME}:${GROUP_NAME}" "${INST_DIR}"

NEW_UUID="$(openssl rand -hex 8)"
NEW_SOCKET="${INST_DIR}/${NEW_UUID}.sock"

if [ -S "${NEW_SOCKET}" ]; then
  log "removing stale socket at ${NEW_SOCKET}"
  sudo rm -f "${NEW_SOCKET}"
fi

log "pinning DEVIDE_GIT_REVISION=${REVISION} and DEVIDE_HTTP_SOCKET=${NEW_SOCKET} in ${ENV_FILE}"
log "backing up ${ENV_FILE} to ${ENV_BACKUP}"
sudo cp -a "${ENV_FILE}" "${ENV_BACKUP}"
sudo chmod 600 "${ENV_BACKUP}"
sudo sed -i '/^DEVIDE_GIT_REVISION=/d; /^DEVIDE_HTTP_SOCKET=/d; /^DEVIDE_INSTANCE_UUID=/d' "${ENV_FILE}"
printf 'DEVIDE_GIT_REVISION=%s\nDEVIDE_HTTP_SOCKET=%s\nDEVIDE_INSTANCE_UUID=%s\n' \
  "${REVISION}" "${NEW_SOCKET}" "${NEW_UUID}" | sudo tee -a "${ENV_FILE}" >/dev/null

# ── Start new instance via systemd transient unit ───────────────────────────
# systemd-run gives us full EnvironmentFile support, correct user/group,
# and the same cgroup as the main unit — without hard-killing the old instance.
# Each Erlang release needs a unique node name — RELEASE_NODE is overridden
# per-instance so two instances can coexist on the same host.
HOST_SHORT="$(hostname -s)"
NEW_RELEASE_NODE="dev_ide_${NEW_UUID}@${HOST_SHORT}"

log "starting new instance ${NEW_UUID} on ${NEW_SOCKET} (node ${NEW_RELEASE_NODE})"
sudo systemd-run \
  --unit="devide-${NEW_UUID}" \
  --description="DevIDE canary ${REVISION} (${NEW_UUID})" \
  --property="User=${USER_NAME}" \
  --property="Group=${GROUP_NAME}" \
  --property="EnvironmentFile=${ENV_FILE}" \
  --property="WorkingDirectory=${APP_ROOT}" \
  --property="KillMode=process" \
  --property="Environment=RELEASE_NODE=${NEW_RELEASE_NODE}" \
  --property="ExecStartPre=/usr/bin/docker compose -f /opt/devide/deploy/docker-compose.postgres.yml --env-file ${ENV_FILE} up -d --wait" \
  --property="ExecStartPre=${ACTIVE_RELEASE}/bin/migrate" \
  "${ACTIVE_RELEASE}/bin/dev_ide" start

# ── Health-check the new instance via its Unix socket ───────────────────────
log "waiting for new instance API readiness on ${NEW_SOCKET}"
api_ready=0
for _ in $(seq 1 60); do
  if [ -S "${NEW_SOCKET}" ] && curl -fsS \
    --unix-socket "${NEW_SOCKET}" \
    -H "authorization: Bearer ${token}" \
    http://localhost/api/workspaces >/dev/null 2>&1; then
    api_ready=1
    break
  fi
  sleep 1
done

if [ "${api_ready}" != "1" ]; then
  echo "error: new instance did not become ready within 60 seconds" >&2
  sudo systemctl stop "devide-${NEW_UUID}" 2>/dev/null || true
  exit 1
fi

# ── Smoke-check new instance MCP endpoints before switching traffic ─────────
log "smoke checking Preview MCP and Terminal MCP on new instance"
tools_json="$(
  curl -fsS --unix-socket "${NEW_SOCKET}" \
    -X POST http://localhost/api/preview/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${tools_json}" | grep -q '"preview_open_app"'
printf '%s' "${tools_json}" | grep -q '"preview_close"'

terminal_tools_json="$(
  curl -fsS --unix-socket "${NEW_SOCKET}" \
    -X POST http://localhost/api/terminals/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${terminal_tools_json}" | grep -q '"terminal_list_sessions"'
printf '%s' "${terminal_tools_json}" | grep -q '"terminal_capture"'

# ── Atomic symlink swap — new traffic goes to new instance ───────────────────
log "swapping ${CURRENT_SYMLINK} → ${NEW_SOCKET}"
if [ -L "${CURRENT_SYMLINK}" ]; then
  OLD_CURRENT_TARGET="$(readlink "${CURRENT_SYMLINK}" || true)"
fi
sudo ln -sfn "${NEW_SOCKET}" "${CURRENT_SYMLINK}.new"
sudo mv -f "${CURRENT_SYMLINK}.new" "${CURRENT_SYMLINK}"
CURRENT_SYMLINK_SWAPPED=1

# ── One-time Caddy migration: switch from 127.0.0.1:4000 to the symlink ─────
# Safe to re-run: if already pointing at the unix socket this is a no-op.
CADDY_UPSTREAM_PATH="$(sudo curl -s http://localhost:2019/config/ 2>/dev/null | \
  python3 -c "
import json,sys
c=json.load(sys.stdin)
def find(o,path=''):
  if isinstance(o,dict):
    if o.get('dial')=='127.0.0.1:4000': return path+'/dial'
    for k,v in o.items():
      r=find(v,path+'/'+str(k))
      if r: return r
  elif isinstance(o,list):
    for i,v in enumerate(o):
      r=find(v,path+'/'+str(i))
      if r: return r
result=find(c)
if result: print(result)
" 2>/dev/null || true)"

if [ -n "${CADDY_UPSTREAM_PATH}" ]; then
  log "migrating Caddy upstream from 127.0.0.1:4000 → unix//run/devide/current.sock"
  CADDY_PREVIOUS_DIAL="127.0.0.1:4000"
  sudo curl -fsS -X PATCH \
    "http://localhost:2019/config${CADDY_UPSTREAM_PATH}" \
    -H "content-type: application/json" \
    -d '"unix//run/devide/current.sock"' >/dev/null
  CADDY_UPSTREAM_PATCHED=1
  log "Caddy upstream patched (persists across Caddy restarts via autosave)"
fi

# The historical enabled devide.service is no longer the process that should
# serve traffic. Leaving it enabled with DEVIDE_HTTP_SOCKET set lets boot or a
# manual restart race the active canary and fail with Bandit :eaddrinuse.
# sudo policy on the devbox intentionally forbids stop/disable/mask, so make
# future legacy starts a successful no-op instead.
neutralize_legacy_service

# ── Clean up stale instance records ─────────────────────────────────────────
# JSON files from killed/rolled-back instances persist because terminate/2 only
# runs on graceful shutdown. Remove any record whose PID is no longer running.
for inst_file in "${INST_DIR}"/*.json; do
  [ -f "${inst_file}" ] || continue
  inst_pid="$(grep -o '"pid":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  if [ -n "${inst_pid}" ] && ! kill -0 "${inst_pid}" 2>/dev/null; then
    inst_sock_stale="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    sudo rm -f "${inst_file}" ${inst_sock_stale:+"${inst_sock_stale}"}
  fi
done

# ── Signal all old instances to drain ───────────────────────────────────────
log "signalling old instances to drain (if any)"
drain_count=0
for inst_file in "${INST_DIR}"/*.json; do
  [ -f "${inst_file}" ] || continue
  inst_uuid="$(grep -o '"id":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  if [ "${inst_uuid}" = "${NEW_UUID}" ]; then
    continue  # skip the instance we just started
  fi

  old_socket="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  old_port="$(grep -o '"http_port":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  old_revision="$(grep -o '"version":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"

  commits_behind=0
  if [ -n "${old_revision}" ] && [ "${old_revision}" != "dev" ] && \
     git cat-file -e "${old_revision}" 2>/dev/null; then
    commits_behind="$(git rev-list "${old_revision}..HEAD" --count 2>/dev/null || echo 0)"
  fi

  drain_payload="{\"commits_behind\": ${commits_behind}}"

  if [ -n "${old_socket}" ] && [ -S "${old_socket}" ]; then
    if curl -fsS -X POST \
      -H "authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      -d "${drain_payload}" \
      --unix-socket "${old_socket}" \
      http://localhost/api/drain >/dev/null 2>&1; then
      drain_count=$((drain_count + 1))
      log "drain signalled (socket ${old_socket}, ${commits_behind} commits behind)"
    else
      log "drain failed (socket ${old_socket}) — instance may already be stopped"
    fi
  elif [ -n "${old_port}" ]; then
    if curl -fsS -X POST \
      -H "authorization: Bearer ${token}" \
      -H "content-type: application/json" \
      -d "${drain_payload}" \
      "http://127.0.0.1:${old_port}/api/drain" >/dev/null 2>&1; then
      drain_count=$((drain_count + 1))
      log "drain signalled (port ${old_port}, ${commits_behind} commits behind)"
    else
      log "drain failed (port ${old_port}) — instance may already be stopped"
    fi
  fi
done
if [ "${drain_count}" = "0" ]; then
  log "no old instances found to drain"
fi

# Old instances call System.stop(0) when their connection count hits zero;
# the systemd unit (devide.service) will then show as inactive until next boot.

log "recent ${SERVICE} and canary unit warnings/errors, if any"
{ sudo journalctl -u "${SERVICE}" --since "2 minutes ago" --no-pager 2>/dev/null; \
  sudo journalctl -u "devide-${NEW_UUID}" --since "2 minutes ago" --no-pager 2>/dev/null; } |
  grep -Ei 'error|failed|warning' || true

SUCCESS=1
sudo rm -f "${ENV_BACKUP}" || true
cleanup_release_backups || log "warning: release backup cleanup failed"
log "deployed ${REVISION} to ${ACTIVE_RELEASE}"
