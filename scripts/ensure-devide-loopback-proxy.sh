#!/usr/bin/env bash
#
# Ensure http://127.0.0.1:4000 reaches the active DevIDE instance.
#
# Canary deploys listen on a Unix socket; legacy deploys bind :4000 directly.
# This script starts devide-loopback (socat) only when the socket exists and
# nothing is already serving loopback.
#
set -euo pipefail

CURRENT_SOCK="/run/devide/current.sock"
LOOPBACK_PORT="${DEVIDE_LOOPBACK_PORT:-4000}"
LOOPBACK_URL="http://127.0.0.1:${LOOPBACK_PORT}"
SERVICE="devide-loopback"
DEPLOY_DST="${DEV_IDE_DEPLOY_ROOT:-/opt/devide}/deploy"

log() { printf '>>> %s\n' "$*"; }

loopback_reachable() {
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "${LOOPBACK_URL}/" 2>/dev/null || echo 000)"
  [[ "${code}" != "000" && -n "${code}" ]]
}

if loopback_reachable; then
  log "loopback ${LOOPBACK_URL} already reachable — proxy not needed"
  exit 0
fi

if ! { [ -S "${CURRENT_SOCK}" ] || [ -L "${CURRENT_SOCK}" ]; }; then
  echo "error: ${CURRENT_SOCK} missing and ${LOOPBACK_URL} is down" >&2
  exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
  echo "error: socat is required to bridge loopback to ${CURRENT_SOCK}" >&2
  exit 1
fi

unit_src="${DEPLOY_DST}/devide-loopback.service"
if sudo test -f "${unit_src}"; then
  log "installing ${SERVICE}.service from ${unit_src}"
  sudo cp "${unit_src}" "/etc/systemd/system/${SERVICE}.service"
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE}" >/dev/null
else
  log "warning: ${unit_src} missing — using inline socat unit definition"
  sudo tee "/etc/systemd/system/${SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=DevIDE loopback HTTP proxy (127.0.0.1:${LOOPBACK_PORT})
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${LOOPBACK_PORT},bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:${CURRENT_SOCK}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE}" >/dev/null
fi

log "starting ${SERVICE}"
sudo systemctl restart "${SERVICE}"

for _ in $(seq 1 15); do
  if loopback_reachable; then
    log "loopback proxy ready at ${LOOPBACK_URL} → ${CURRENT_SOCK}"
    exit 0
  fi
  sleep 1
done

echo "error: ${SERVICE} started but ${LOOPBACK_URL} is still unreachable" >&2
sudo systemctl status "${SERVICE}" --no-pager 2>&1 | tail -20 >&2 || true
exit 1