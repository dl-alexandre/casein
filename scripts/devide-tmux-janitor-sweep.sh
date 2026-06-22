#!/usr/bin/env bash
#
# Run the DevIDE tmux blank window/session janitor against the active canary.
# The janitor policy lives in DevIDE.Terminals.TmuxWindowJanitor; this script
# only finds the active release node and invokes that policy by RPC.
#
# Usage:
#   scripts/devide-tmux-janitor-sweep.sh
#   scripts/devide-tmux-janitor-sweep.sh --dry-run
#
set -euo pipefail

ENV_FILE="${DEV_IDE_ENV_FILE:-/etc/devide/devide.env}"
RELEASE_BIN="${DEVIDE_RELEASE_BIN:-/opt/devide/release/bin/dev_ide}"
MODE="sweep"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    -h|--help)
      sed -n '2,11p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

unit="$(
  { systemctl list-units 'devide-*.service' --state=active --no-legend --plain 2>/dev/null || true; } |
    awk '$1 ~ /^devide-[0-9a-f]+\.service$/ {print $1; exit}'
)"

if [[ -z "$unit" ]]; then
  echo "devide tmux janitor: no active devide canary unit found" >&2
  exit 1
fi

node="$(
  systemctl show "$unit" -p Environment --value |
    tr ' ' '\n' |
    awk -F= '/^RELEASE_NODE=/{print $2; exit}'
)"

if [[ -z "$node" ]]; then
  echo "devide tmux janitor: RELEASE_NODE missing from $unit" >&2
  exit 1
fi

cookie="$(awk -F= '/^RELEASE_COOKIE=/{print $2}' "$ENV_FILE" | tail -1)"

if [[ -z "$cookie" ]]; then
  echo "devide tmux janitor: RELEASE_COOKIE missing from $ENV_FILE" >&2
  exit 1
fi

case "$MODE" in
  dry-run)
    expr='case Code.ensure_loaded(DevIDE.Terminals.TmuxWindowJanitor) do
  {:module, DevIDE.Terminals.TmuxWindowJanitor} ->
    if function_exported?(DevIDE.Terminals.TmuxWindowJanitor, :dry_run_now, 0) do
      IO.inspect(DevIDE.Terminals.TmuxWindowJanitor.dry_run_now(), limit: :infinity)
    else
      IO.puts("dry_run_not_available: deploy the checkout with TmuxWindowJanitor.dry_run_now/0 first")
    end

  _ ->
    IO.puts("dry_run_not_available: TmuxWindowJanitor is not loaded in this release")
end'
    ;;
  sweep)
    expr='IO.puts(DevIDE.Terminals.TmuxWindowJanitor.sweep_now())'
    ;;
esac

rpc_env=(
  RELEASE_NODE="$node"
  RELEASE_COOKIE="$cookie"
  RELEASE_DISTRIBUTION=sname
)

if [[ "$(id -un)" == "devbox" ]]; then
  env "${rpc_env[@]}" "$RELEASE_BIN" rpc "$expr"
else
  runuser -u devbox -- env "${rpc_env[@]}" "$RELEASE_BIN" rpc "$expr"
fi
