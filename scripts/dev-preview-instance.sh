#!/usr/bin/env bash
#
# dev-preview-instance.sh — boot an isolated DevIDE dev server from the working
# tree, for previewing UI changes with ZERO impact on the live release/session.
#
# Thin wrapper around scripts/preview-env.sh dirty --foreground.
#
# Usage:
#   bash scripts/dev-preview-instance.sh
#   PORT=4123 bash scripts/dev-preview-instance.sh
#
# Then open:  http://127.0.0.1:$PORT/workspaces/preview-sandbox?host=local
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW="$ROOT/scripts/preview-env.sh"

args=()
if [[ -n "${PORT:-}" ]]; then
  args+=(--port "$PORT")
fi

exec bash "$PREVIEW" dirty --foreground "${args[@]}"