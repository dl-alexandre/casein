#!/usr/bin/env bash
#
# Register (or refresh) the GitHub push webhook that triggers the on-box deploy
# poller via POST /api/deploy_webhook.
#
# Prerequisites:
#   - DEVIDE_DEPLOY_WEBHOOK_SECRET in /etc/casein/devide.env (or exported)
#   - Caddy serves /api/deploy_webhook WITHOUT forward_auth (GitHub has no session)
#   - bash scripts/ensure-devide-deploy-poller.sh (sudoers for systemctl start)
#
# Usage:
#   DEVIDE_URL=https://devide.devbox.milcgroup.com bash scripts/setup-github-deploy-webhook.sh
#   DEVIDE_URL=... GITHUB_REPO=dl-alexandre/dev_ide bash scripts/setup-github-deploy-webhook.sh --dry-run
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CASEIN_ENV_FILE:-/etc/casein/devide.env}"
DEVIDE_URL="${DEVIDE_URL:-https://devide.devbox.milcgroup.com}"
GITHUB_REPO="${GITHUB_REPO:-dl-alexandre/dev_ide}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { printf '>>> %s\n' "$*"; }

read_secret() {
  if [[ -n "${DEVIDE_DEPLOY_WEBHOOK_SECRET:-}" ]]; then
    printf '%s' "${DEVIDE_DEPLOY_WEBHOOK_SECRET}"
    return 0
  fi

  if [[ -r "${ENV_FILE}" ]]; then
    val="$(sed -n 's/^DEVIDE_DEPLOY_WEBHOOK_SECRET=//p' "${ENV_FILE}" | tail -1)"
    if [[ -n "${val}" ]]; then
      printf '%s' "${val}"
      return 0
    fi
  fi

  return 1
}

SECRET="$(read_secret || true)"
if [[ -z "${SECRET}" ]]; then
  echo "error: DEVIDE_DEPLOY_WEBHOOK_SECRET is not set (env or ${ENV_FILE})" >&2
  echo "Generate one with: mise exec -- mix phx.gen.secret" >&2
  exit 1
fi

WEBHOOK_URL="${DEVIDE_URL%/}/api/deploy_webhook"

log "target webhook URL: ${WEBHOOK_URL}"
log "repository: ${GITHUB_REPO}"

cat <<EOF

Caddy must expose ${WEBHOOK_URL} without oauth2-proxy forward_auth.
Add a handle block on the DevIDE site BEFORE the forward_auth import, e.g.:

  @devide_deploy_webhook path /api/deploy_webhook
  handle @devide_deploy_webhook {
    reverse_proxy 127.0.0.1:4000
  }

EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: skipping gh api webhook registration"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required to register the webhook" >&2
  exit 1
fi

existing_id=""
existing_url=""
while IFS=$'\t' read -r id url; do
  if [[ "${url}" == "${WEBHOOK_URL}" ]]; then
    existing_id="${id}"
    existing_url="${url}"
    break
  fi
done < <(env -u GH_TOKEN -u GITHUB_TOKEN gh api "repos/${GITHUB_REPO}/hooks" --paginate \
  -q '.[] | [.id, .config.url] | @tsv' 2>/dev/null || true)

if [[ -n "${existing_id}" ]]; then
  log "updating existing webhook ${existing_id} (${existing_url})"
  env -u GH_TOKEN -u GITHUB_TOKEN gh api -X PATCH "repos/${GITHUB_REPO}/hooks/${existing_id}" \
    -f active=true \
    -f 'events[]=push' \
    -F "config[url]=${WEBHOOK_URL}" \
    -f 'config[content_type]=json' \
    -F "config[secret]=${SECRET}" \
    -f 'config[insecure_ssl]=0' >/dev/null
else
  log "creating new push webhook"
  env -u GH_TOKEN -u GITHUB_TOKEN gh api "repos/${GITHUB_REPO}/hooks" \
    -f name=web \
    -f active=true \
    -f 'events[]=push' \
    -F "config[url]=${WEBHOOK_URL}" \
    -f 'config[content_type]=json' \
    -F "config[secret]=${SECRET}" \
    -f 'config[insecure_ssl]=0' >/dev/null
fi

log "webhook registered — push to master should trigger devide-deploy.service within seconds"
log "timer fallback remains active via devide-deploy.timer"