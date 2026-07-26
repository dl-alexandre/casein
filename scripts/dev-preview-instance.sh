#!/usr/bin/env bash
#
# dev-preview-instance.sh — boot an isolated Casein dev server from the working
# tree, for previewing UI changes with ZERO impact on the live release/session.
#
# Thin wrapper around scripts/preview-env.sh dirty --foreground.
#
# Usage:
#   bash scripts/dev-preview-instance.sh
#   PORT=4123 bash scripts/dev-preview-instance.sh
#   PORT=4123 bash scripts/dev-preview-instance.sh --background
#
# Then open:  http://127.0.0.1:$PORT/workspaces/preview-sandbox?host=local
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW="$ROOT/scripts/preview-env.sh"

args=()
foreground=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --background)
      foreground=0
      shift
      ;;
    --foreground)
      foreground=1
      shift
      ;;
    *)
      echo "usage: $0 [--foreground|--background]" >&2
      exit 2
      ;;
  esac
done

if [[ -n "${PORT:-}" ]]; then
  args+=(--port "$PORT")
fi

if [[ "$foreground" = 1 ]]; then
  args+=(--foreground)
fi

exec bash "$PREVIEW" dirty "${args[@]}"
