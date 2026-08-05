#!/usr/bin/env bash
#
# Deploy a prebuilt Casein release tarball on the devbox host.
#
# Intended caller: run as a FILE PATH from a repo checkout so the sibling
# scripts/lib/canary-drain.sh is resolvable, e.g.
#   scripts/build-release.sh
#   tar -C release-out -czf /tmp/casein-release.tgz .
#   "$WORKTREE/scripts/deploy-devbox-release.sh" /tmp/casein-release.tgz <rev>
# (scripts/deploy-poller.sh and scripts/deploy-local.sh both invoke it this
# way). Piping the body via `bash -s < …` is unsupported now that it sources a
# lib — BASH_SOURCE would not resolve.

set -euo pipefail

TARBALL="${1:?usage: deploy-devbox-release.sh /path/to/release.tgz [revision]}"
REVISION="${2:-manual}"

APP_ROOT="${CASEIN_DEPLOY_ROOT:-/opt/casein}"
SERVICE="${CASEIN_SYSTEMD_SERVICE:-casein}"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/casein.env}"
CANONICAL_DEVBOX_HOST="casein.devbox.milcgroup.com"
OPERATOR_CONFIG_FILE="${CASEIN_OPERATOR_CONFIG_FILE:-/etc/casein/operator.json}"
USER_NAME="${CASEIN_DEPLOY_USER:-devbox}"
GROUP_NAME="${CASEIN_DEPLOY_GROUP:-devbox}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEPLOY_ID="${TS}.$$"
STAGING="${APP_ROOT}/release.staging.${REVISION}.${TS}"
FAILED_RELEASE="${APP_ROOT}/release.failed.${REVISION}.${DEPLOY_ID}"
ACTIVE_RELEASE="${APP_ROOT}/release"
PREVIOUS_RELEASE="${APP_ROOT}/release.prev"
RELEASE_BACKUP_KEEP="${CASEIN_RELEASE_BACKUP_KEEP:-5}"
ENV_BACKUP="${ENV_FILE}.prev.${REVISION}.${DEPLOY_ID}"
# Keep the run directory and active socket aligned with the Casein runtime.
# Frozen CASEIN_* overrides preserve an explicit legacy-host cutover when needed.
RUN_ROOT="${CASEIN_RUN_ROOT:-/run/casein}"
INST_DIR="${RUN_ROOT}/instances"
CURRENT_SYMLINK="${CASEIN_CURRENT_SOCK:-${RUN_ROOT}/current.sock}"
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

# Canary drain/stop helpers (casein_release_pid_alive, casein_instance_alive,
# running_canary_uuids, current_sock_uuid, canary_uuid_in_list,
# stop_canary_unit, drain_instance). Extracted into a lib so
# scripts/test-canary-drain.sh can exercise them hermetically; they read log(),
# token, INST_DIR, CURRENT_SYMLINK, and drain_count from this scope.
DEPLOY_SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -z "${DEPLOY_SCRIPT_SELF_DIR}" ] || [ ! -r "${DEPLOY_SCRIPT_SELF_DIR}/lib/canary-drain.sh" ]; then
  echo "error: cannot locate scripts/lib/canary-drain.sh next to this script." >&2
  echo "       Run deploy-devbox-release.sh as a file path from a repo checkout," >&2
  echo "       not piped via 'bash -s' (see the header comment)." >&2
  exit 1
fi
# shellcheck source=scripts/lib/canary-drain.sh
source "${DEPLOY_SCRIPT_SELF_DIR}/lib/canary-drain.sh"
# shellcheck source=scripts/lib/caddy-upstream.sh
source "${DEPLOY_SCRIPT_SELF_DIR}/lib/caddy-upstream.sh"

cleanup_stale_instance_records() {
  for inst_file in "${INST_DIR}"/*.json; do
    [ -f "${inst_file}" ] || continue
    inst_pid="$(grep -o '"pid":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    inst_uuid="$(grep -o '"id":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    if casein_instance_alive "${inst_uuid}" "${inst_pid}"; then
      continue
    fi
    inst_sock_stale="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    log "removing stale instance record ${inst_file}${inst_sock_stale:+ (socket ${inst_sock_stale})}"
    sudo rm -f "${inst_file}" ${inst_sock_stale:+"${inst_sock_stale}"}
  done
}

# True if any recorded instance is a live Casein release process. Used to refuse
# (re)generating a missing RELEASE_COOKIE while an instance is already running
# under a cookie we can no longer see — regenerating a fresh one would diverge
# from the live node and turn the next graceful drain into a hard SIGTERM.
cookie_dependent_instance_running() {
  if [ -n "$(running_canary_uuids)" ]; then
    return 0
  fi
  for inst_file in "${INST_DIR}"/*.json; do
    [ -f "${inst_file}" ] || continue
    inst_pid="$(grep -o '"pid":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
    if [ -n "${inst_pid}" ] && casein_release_pid_alive "${inst_pid}"; then
      return 0
    fi
  done
  return 1
}

neutralize_legacy_service() {
  dropin_dir="/etc/systemd/system/${SERVICE}.service.d"

  log "installing no-op drop-in for legacy ${SERVICE}.service"
  sudo mkdir -p "${dropin_dir}"
  sudo tee "${dropin_dir}/90-casein-canary-noop.conf" >/dev/null <<EOF
# Managed by Casein deploy-devbox-release.sh.
# Traffic is served by transient casein-<uuid> units via /run/casein/current.sock.
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
    log "warning: invalid CASEIN_RELEASE_BACKUP_KEEP=${RELEASE_BACKUP_KEEP}; skipping release backup cleanup"
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
    stop_canary_unit "${NEW_UUID}"
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
    casein_caddy_admin_curl -fsS -X PATCH \
      "${CASEIN_CADDY_ADMIN_URL}/config${CADDY_UPSTREAM_PATH}" \
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

sudo test -x "${STAGING}/bin/casein"
sudo test -x "${STAGING}/bin/migrate"

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
# on-disk file and peer commands (`bin/casein stop`, `rpc`, health probes) fail
# the distribution challenge (:noconnection). That makes the graceful ExecStop
# fail and every deploy hard-SIGTERM the node mid-session, draining LiveView
# sockets and killing live tmux terminals. Generate + persist one if absent, so
# the cookie stays stable across deploys and env-file regens. Idempotent: a
# value already present (or supplied via casein.env.example) is left untouched.
if ! sudo grep -qE '^RELEASE_COOKIE=.+' "${ENV_FILE}"; then
  # HARD GUARD: a missing RELEASE_COOKIE is only safe to (re)generate when NO
  # instance is already running. If a live instance exists, it is using a cookie
  # we can no longer read (e.g. the env file was rebuilt from casein.env.example
  # and silently dropped the key — see the template-rebuild warning below).
  # Minting a *fresh* cookie here would diverge from the running node, so the
  # graceful peer `bin/casein stop` fails the distribution challenge
  # (:noconnection), ExecStop fails, and systemd hard-SIGTERMs the old node
  # mid-session — draining LiveView sockets and killing live tmux terminals.
  # Abort instead so the operator can restore the real cookie before redeploying.
  if cookie_dependent_instance_running; then
    echo "error: RELEASE_COOKIE is missing from ${ENV_FILE} but a Casein instance" >&2
    echo "       is already running under a cookie this deploy can no longer read." >&2
    echo "       Regenerating it now would hard-kill that instance (and its tmux" >&2
    echo "       terminals) on handoff. The env file was likely rebuilt from" >&2
    echo "       casein.env.example. Restore RELEASE_COOKIE before redeploying:" >&2
    echo "         sudo grep -h '^RELEASE_COOKIE=' ${ENV_FILE}.prev.* 2>/dev/null | tail -1" >&2
    echo "       then append the recovered value to ${ENV_FILE} and retry." >&2
    exit 1
  fi
  log "no RELEASE_COOKIE and no running instance — minting a bootstrap cookie"
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

token="$(casein_read_casein_api_token "${ENV_FILE}")"

if [ -z "${token}" ]; then
  echo "error: CASEIN_API_TOKEN missing from ${ENV_FILE}" >&2
  exit 1
fi

# A template-rebuilt env file silently drops keys (seen 2026-06-12: the env
# was reconstructed from casein.env.example during incident recovery and lost
# commented-by-default keys). Warn loudly so a lossy rebuild is caught at the
# next deploy instead of in the UI.
for key in PHX_HOST SECRET_KEY_BASE DATABASE_URL CASEIN_FORWARD_AUTH_EMAIL_DOMAIN; do
  if ! sudo grep -q "^${key}=" "${ENV_FILE}"; then
    log "WARNING: ${key} missing from ${ENV_FILE} — env file may have been rebuilt from template"
  fi
done

configured_phx_host="$(
  sudo awk -F= '/^PHX_HOST=/{print $2}' "${ENV_FILE}" |
    tail -n 1
)"

if [ "${configured_phx_host}" != "${CANONICAL_DEVBOX_HOST}" ]; then
  echo "error: PHX_HOST must be ${CANONICAL_DEVBOX_HOST} for a devbox deploy; got ${configured_phx_host:-<missing>}" >&2
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

log "pinning CASEIN_GIT_REVISION=${REVISION} and CASEIN_HTTP_SOCKET=${NEW_SOCKET} in ${ENV_FILE}"
log "backing up ${ENV_FILE} to ${ENV_BACKUP}"
sudo cp -a "${ENV_FILE}" "${ENV_BACKUP}"
sudo chmod 600 "${ENV_BACKUP}"
sudo sed -i '/^CASEIN_GIT_REVISION=/d; /^CASEIN_HTTP_SOCKET=/d; /^CASEIN_INSTANCE_UUID=/d' "${ENV_FILE}"
printf 'CASEIN_GIT_REVISION=%s\nCASEIN_HTTP_SOCKET=%s\nCASEIN_INSTANCE_UUID=%s\n' \
  "${REVISION}" "${NEW_SOCKET}" "${NEW_UUID}" | sudo tee -a "${ENV_FILE}" >/dev/null

# ── Start new instance via systemd transient unit ───────────────────────────
# systemd-run gives us full EnvironmentFile support, correct user/group,
# and the same cgroup as the main unit — without hard-killing the old instance.
# Each Erlang release needs a unique node name — RELEASE_NODE is overridden
# per-instance so two instances can coexist on the same host.
HOST_SHORT="$(hostname -s)"
NEW_RELEASE_NODE="casein_${NEW_UUID}@${HOST_SHORT}"

log "starting new instance ${NEW_UUID} on ${NEW_SOCKET} (node ${NEW_RELEASE_NODE})"

operator_property=()
if sudo -u "${USER_NAME}" test -r "${OPERATOR_CONFIG_FILE}"; then
  log "using operator profile ${OPERATOR_CONFIG_FILE}"
  operator_property+=(--property="Environment=CASEIN_OPERATOR_CONFIG_FILE=${OPERATOR_CONFIG_FILE}")
else
  log "operator profile not installed; deployment capabilities remain disabled"
fi

sudo systemd-run \
  --unit="casein-${NEW_UUID}" \
  --description="Casein canary ${REVISION} (${NEW_UUID})" \
  --property="User=${USER_NAME}" \
  --property="Group=${GROUP_NAME}" \
  --property="EnvironmentFile=${ENV_FILE}" \
  "${operator_property[@]}" \
  --property="WorkingDirectory=${APP_ROOT}" \
  --property="KillMode=process" \
  --property="Environment=RELEASE_NODE=${NEW_RELEASE_NODE}" \
  --property="ExecStartPre=/usr/bin/docker compose -f /opt/casein/deploy/docker-compose.postgres.yml --env-file ${ENV_FILE} up -d --wait" \
  --property="ExecStartPre=${ACTIVE_RELEASE}/bin/clean_casein_socket" \
  --property="ExecStartPre=${ACTIVE_RELEASE}/bin/migrate" \
  "${ACTIVE_RELEASE}/bin/casein" start

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
  stop_canary_unit "${NEW_UUID}"
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

# preview_open_app is in the always-on tool-search CORE set, so it is advertised
# whether CASEIN_MCP_TOOL_SEARCH is on or off. preview_close is NOT in core, so
# when tool-search is armed it moves behind the search_tools/invoke_tool meta-
# tools and drops out of tools/list — a hard-coded grep for it fails the smoke
# check and blocks the deploy even though preview MCP is healthy. Accept either
# the full-list tool (tool-search off) or the meta-tool (tool-search on).
printf '%s' "${tools_json}" | grep -q '"preview_open_app"'
printf '%s' "${tools_json}" | grep -qE '"preview_close"|"invoke_tool"'

preview_script_dir="$(
  sudo find "${ACTIVE_RELEASE}/lib" -maxdepth 4 -type f -path '*/priv/scripts/casein-preview' -print -quit 2>/dev/null
)"
if [ -z "${preview_script_dir}" ]; then
  echo "error: casein-preview script missing from release priv/scripts" >&2
  exit 1
fi
if [ ! -x "${preview_script_dir}" ]; then
  echo "error: casein-preview is not executable in release priv/scripts" >&2
  exit 1
fi

casein_curl_script_dir="$(
  sudo find "${ACTIVE_RELEASE}/lib" -maxdepth 4 -type f -path '*/priv/scripts/casein-curl.sh' -print -quit 2>/dev/null
)"
if [ -z "${casein_curl_script_dir}" ]; then
  echo "error: casein-curl.sh missing from release priv/scripts" >&2
  exit 1
fi

# Agent hook scripts staged per-workspace by the materializer (copied out of the
# release's priv/scripts). Missing here means non-Casein workspaces get no live
# agent-state / codex notify hook.
for hook_script in casein-agent-state.sh casein-codex-notify.sh; do
  hook_script_path="$(
    sudo find "${ACTIVE_RELEASE}/lib" -maxdepth 4 -type f -path "*/priv/scripts/${hook_script}" -print -quit 2>/dev/null
  )"
  if [ -z "${hook_script_path}" ]; then
    echo "error: ${hook_script} missing from release priv/scripts" >&2
    exit 1
  fi
  if [ ! -x "${hook_script_path}" ]; then
    echo "error: ${hook_script} is not executable in release priv/scripts" >&2
    exit 1
  fi
done

terminal_tools_json="$(
  curl -fsS --unix-socket "${NEW_SOCKET}" \
    -X POST http://localhost/api/terminals/mcp \
    -H "authorization: Bearer ${token}" \
    -H "content-type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
)"

printf '%s' "${terminal_tools_json}" | grep -q '"terminal_list_sessions"'
printf '%s' "${terminal_tools_json}" | grep -q '"terminal_capture"'

# ── Terminal usability smoke — open a real terminal and assert it lands in a
# live cwd and that session env actually reaches the pane's shell. The
# tools/list checks above pass even when a freshly-opened pane is unusable; this
# guards the 2026-07-09 `getcwd failed` class (host tmux server stranded in a
# reaped-worktree cwd) and the 2026-08-03 unpaired-pane class (session env set
# after the pane exists never reaching its shell, so every agent launcher
# refuses to start). Pre-swap, so a 503 aborts promotion via the rollback trap
# with the old instance still serving. ───────────────────────────────────────
log "smoke checking terminal usability on new instance"
curl -fsS --unix-socket "${NEW_SOCKET}" \
  -H "authorization: Bearer ${token}" \
  http://localhost/api/smoke/terminal >/dev/null

# ── Atomic symlink swap — new traffic goes to new instance ───────────────────
log "swapping ${CURRENT_SYMLINK} → ${NEW_SOCKET}"
if [ -L "${CURRENT_SYMLINK}" ]; then
  OLD_CURRENT_TARGET="$(readlink "${CURRENT_SYMLINK}" || true)"
fi
sudo ln -sfn "${NEW_SOCKET}" "${CURRENT_SYMLINK}.new"
sudo mv -f "${CURRENT_SYMLINK}.new" "${CURRENT_SYMLINK}"
CURRENT_SYMLINK_SWAPPED=1

# Reconcile the app route during activation. Even when the configured dial is
# already canonical, activation re-applies that exact value so Caddy drops any
# pooled Unix connection that still targets the pre-swap socket. The periodic
# deploy poller uses repair mode and remains a no-op for known-good routes.
CADDY_HOST="$(sudo awk -F= '/^PHX_HOST=/{print $2}' "${ENV_FILE}" | tail -n 1)"
CADDY_HOST="${CADDY_HOST:-${CANONICAL_DEVBOX_HOST}}"
caddy_reconcile_ok=0
if casein_reconcile_caddy_upstream "${CADDY_HOST}" migration; then
  caddy_reconcile_ok=1
fi

log "verifying deploy handoff health"
deploy_status_json="$(curl -sS --unix-socket "${CURRENT_SYMLINK}" \
  -H "authorization: Bearer ${token}" \
  http://localhost/api/deploy_status || true)"

if [ "${caddy_reconcile_ok}" = "1" ] &&
    printf '%s' "${deploy_status_json}" | grep -q '"ok":true'; then
  :
elif [ "${CADDY_RECONCILE_OUTCOME}" = "admin_unavailable" ] &&
    casein_canonical_route_attests_caddy_unavailable \
    "${CADDY_HOST}" "${REVISION}" "${NEW_SOCKET}" "${token}"; then
  log "warning: accepting exact canonical attestation after Caddy admin unavailability"
elif [[ "${CASEIN_ALLOW_DEPLOY_DRIFT:-0}" == "1" ]]; then
  if printf '%s' "${deploy_status_json}" | grep -q '"deploy_revision_current":false'; then
    log "warning: deploy_revision_current=false — revision ${REVISION} is not on origin/master"
  else
    log "warning: deploy handoff health not fully green"
  fi
  log "warning: continuing because CASEIN_ALLOW_DEPLOY_DRIFT=1 (commit and push to master for a durable deploy)"
  printf '%s\n' "${deploy_status_json}" >&2
else
  if printf '%s' "${deploy_status_json}" | grep -q '"deploy_revision_current":false'; then
    log "error: deploy handoff failed — revision ${REVISION} is not on origin/master"
    log "error: commit and push to master, then redeploy; or pass --allow-drift to deploy-local.sh for dogfooding"
  else
    log "error: deploy handoff health check failed"
  fi
  printf '%s\n' "${deploy_status_json}" >&2
  exit 1
fi

# The historical enabled casein.service is no longer the process that should
# serve traffic. Leaving it enabled with CASEIN_HTTP_SOCKET set lets boot or a
# manual restart race the active canary and fail with Bandit :eaddrinuse.
# sudo policy on the devbox intentionally forbids stop/disable/mask, so make
# future legacy starts a successful no-op instead.
neutralize_legacy_service

# ── Clean up stale instance records ─────────────────────────────────────────
# JSON files from killed/rolled-back instances persist because terminate/2 only
# runs on graceful shutdown. Drop records whose PID is gone or no longer Casein.
log "cleaning stale instance records under ${INST_DIR}"
cleanup_stale_instance_records

# ── Signal all old instances to drain ───────────────────────────────────────
# Candidates come from running casein-<uuid> units (authoritative) UNIONed with
# instance records (covers non-unit instances, e.g. the legacy casein.service).
# Records alone were not enough: a poisoned heartbeat pid made the live old
# instance look stale, cleanup deleted its record, and this loop never saw it —
# the zombie then ran for days, its SessionOwners fighting the new instance
# over tmux window sizes.
log "signalling old instances to drain (if any)"
drain_count=0

# drain_instance() lives in scripts/lib/canary-drain.sh (sourced above).

# Never touch the instance we just started or whichever instance currently
# serves traffic (they can differ under a concurrent deploy — see
# current_sock_uuid). Space-padded so a substring match can't misfire.
LIVE_UUID="$(current_sock_uuid)"
protected_uuids=" ${NEW_UUID} ${LIVE_UUID} "

drained_uuids=" "
for inst_file in "${INST_DIR}"/*.json; do
  [ -f "${inst_file}" ] || continue
  inst_uuid="$(grep -o '"id":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  if [ -n "${inst_uuid}" ]; then
    case "${protected_uuids}" in
      *" ${inst_uuid} "*) continue ;;  # the new or the live-serving instance
    esac
  fi

  old_socket="$(grep -o '"socket_path":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  old_port="$(grep -o '"http_port":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"
  old_revision="$(grep -o '"version":"[^"]*"' "${inst_file}" 2>/dev/null | cut -d'"' -f4 || true)"

  drain_instance "${inst_uuid}" "${old_socket}" "${old_port}" "${old_revision}"
  [ -n "${inst_uuid}" ] && drained_uuids="${drained_uuids}${inst_uuid} "
done

# Running canary units without a (surviving) instance record.
for unit_uuid in $(running_canary_uuids); do
  case "${protected_uuids}" in
    *" ${unit_uuid} "*) continue ;;
  esac
  case "${drained_uuids}" in
    *" ${unit_uuid} "*) continue ;;
  esac
  drain_instance "${unit_uuid}" "${INST_DIR}/${unit_uuid}.sock" "" ""
done

if [ "${drain_count}" = "0" ]; then
  log "no old instances found to drain"
fi

# Reap leaked non-canary dev servers (mix phx.server from removed agent
# worktrees) — they are invisible to the drain loop above but share the host
# tmux server and fight the live instance over window sizes. Safe: only beams
# with a DELETED cwd, which never matches the live release or a canary.
# Word-splitting is intended — each pid becomes a separate positional arg.
# shellcheck disable=SC2046
reap_orphaned_dev_servers $(pgrep -x beam.smp 2>/dev/null || true)

# Old instances call System.stop(0) when their connection count hits zero;
# the systemd unit (casein.service) will then show as inactive until next boot.

log "recent ${SERVICE} and canary unit warnings/errors, if any"
{ sudo journalctl -u "${SERVICE}" --since "2 minutes ago" --no-pager 2>/dev/null; \
  sudo journalctl -u "casein-${NEW_UUID}" --since "2 minutes ago" --no-pager 2>/dev/null; } |
  grep -Ei 'error|failed|warning' || true

log "ensuring loopback API on 127.0.0.1:4000 for on-box agents"
DEPLOY_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASEIN_CHECKOUT="${CASEIN_CHECKOUT:-/data/workspaces/dalexandre/casein}"
ensure_ran=0
for ensure_script in \
  "${DEPLOY_SCRIPT_DIR}/ensure-casein-loopback-proxy.sh" \
  "${CASEIN_CHECKOUT}/scripts/ensure-casein-loopback-proxy.sh"; do
  if [ -x "${ensure_script}" ]; then
    bash "${ensure_script}"
    ensure_ran=1
    break
  fi
done
if [ "${ensure_ran}" != "1" ]; then
  log "warning: ensure-casein-loopback-proxy.sh not found — on-box :4000 may be down"
fi

SUCCESS=1
sudo rm -f "${ENV_BACKUP}" || true
cleanup_release_backups || log "warning: release backup cleanup failed"
log "deployed ${REVISION} to ${ACTIVE_RELEASE}"
