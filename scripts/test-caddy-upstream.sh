#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/caddy-upstream.sh
source "${ROOT}/scripts/lib/caddy-upstream.sh"

log() { :; }
sudo() { "$@"; }

upstream_path="/apps/http/servers/srv0/routes/0/handle/0/upstreams/0/dial"
current_dial="unix//run/devide/current.sock"
patch_count=0

curl() {
  local method="GET"
  local url=""
  local data=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -d) data="$2"; shift 2 ;;
      -H | -o | -w | --max-time | --unix-socket) shift 2 ;;
      -s | -fsS | -sS) shift ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done

  if [ "$url" = "http://localhost:2019/config/" ]; then
    printf '%s\n' \
      '{"apps":{"http":{"servers":{"srv0":{"routes":[{"match":[{"host":["devide.devbox.milcgroup.com"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"unix//run/devide/current.sock"}]}]}]}}}}}'
  elif [ "$method" = "PATCH" ]; then
    current_dial="${data%\"}"
    current_dial="${current_dial#\"}"
    patch_count=$((patch_count + 1))
  elif [ "$url" = "http://localhost:2019/config${upstream_path}" ]; then
    printf '"%s"\n' "$current_dial"
  else
    return 22
  fi
}

casein_reconcile_caddy_upstream "devide.devbox.milcgroup.com" repair
[ "$current_dial" = "unix//run/casein/current.sock" ]
[ "$patch_count" -eq 1 ]

casein_reconcile_caddy_upstream "devide.devbox.milcgroup.com" repair
[ "$patch_count" -eq 1 ]

current_dial="unix//unexpected/current.sock"
if casein_reconcile_caddy_upstream "devide.devbox.milcgroup.com" repair; then
  echo "repair unexpectedly rewrote an unknown upstream" >&2
  exit 1
fi
[ "$current_dial" = "unix//unexpected/current.sock" ]
[ "$patch_count" -eq 1 ]

echo "caddy upstream repair tests passed"
