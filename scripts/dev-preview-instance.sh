#!/usr/bin/env bash
#
# dev-preview-instance.sh — boot an isolated DevIDE dev server from the working
# tree, for previewing UI changes with ZERO impact on the live release/session.
#
# Why this exists: the deployed release (/opt/devide) serves old compiled code,
# and previews/MCP render *that*. To see working-tree UI edits you need a server
# running your checkout. This boots one safely:
#
#   * Serves YOUR code        — mix phx.server (dev, code reloader + asset watchers)
#   * Isolated DB             — dev_ide_preview on :15432 (never touches prod data)
#   * Local workspace source  — a seeded sandbox dir, so NO manager dependency and
#                               NO tmux collision with the operator's live terminal
#   * Default dev user        — forward-auth OFF, so any browser opens it directly
#
# Usage:
#   bash scripts/dev-preview-instance.sh                 # seed + boot on :4117
#   PORT=4123 bash scripts/dev-preview-instance.sh
#   DEVIDE_PREVIEW_WORKSPACE=my-ws bash scripts/dev-preview-instance.sh
#
# Then open:  http://127.0.0.1:$PORT/workspaces/$SANDBOX?host=local
# Or shoot it: node scripts/dev-preview-shot.mjs <url> out.png 390x844
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4117}"
PREVIEW_DB="${DEVIDE_PREVIEW_DB:-dev_ide_preview}"
# dev.exs reads DEV_IDE_WORKSPACES_ROOT at phx.server startup (we export it below).
WS_ROOT="${DEV_IDE_WORKSPACES_ROOT:-${HOME}/.devide-preview/workspaces}"
SANDBOX="${DEVIDE_PREVIEW_WORKSPACE:-preview-sandbox}"
MISE=(mise exec elixir@1.20.0-otp-28 erlang@28.5 --)

# --- DB URL: reuse the release's creds/host, swap the db name to the isolated one
PROD_URL="$(grep -E '^DATABASE_URL=' /etc/devide/devide.env | cut -d= -f2- | tr -d '"')"
if [[ -z "${PROD_URL}" ]]; then
  echo "error: no DATABASE_URL in /etc/devide/devide.env" >&2
  exit 1
fi
export DATABASE_URL="${PROD_URL%/*}/${PREVIEW_DB}"

# --- Seed a reusable sandbox workspace (a directory IS a workspace via Local src)
WS_DIR="${WS_ROOT}/${SANDBOX}"
if [[ ! -d "${WS_DIR}/.git" ]]; then
  echo ">>> seeding sandbox workspace at ${WS_DIR}"
  mkdir -p "${WS_DIR}/lib"
  printf '# Preview Sandbox\n\nThrowaway workspace for DevIDE UI previews. Recreated by\n`scripts/dev-preview-instance.sh`; safe to delete.\n' > "${WS_DIR}/README.md"
  printf 'defmodule Sandbox do\n  @moduledoc "Filler so the workspace looks real."\n  def hello, do: :world\nend\n' > "${WS_DIR}/lib/sandbox.ex"
  ( cd "${WS_DIR}" && git init -q \
      && git -c user.email=dev@local -c user.name=dev add -A \
      && git -c user.email=dev@local -c user.name=dev commit -qm "seed preview sandbox" )
fi

# --- Isolated DB: create + migrate (idempotent)
echo ">>> ensuring isolated DB ${PREVIEW_DB}"
"${MISE[@]}" mix ecto.create --quiet 2>/dev/null || true
"${MISE[@]}" mix ecto.migrate

# --- Build assets once so first paint has compiled CSS (watchers keep it fresh)
echo ">>> building assets"
"${MISE[@]}" mix assets.build

# --- Boot
export MIX_ENV=dev PHX_SERVER=true PORT="${PORT}"
export DEV_IDE_WORKSPACE_SOURCE=local
export DEV_IDE_WORKSPACES_ROOT="${WS_ROOT}"
echo ">>> DevIDE preview instance up:"
echo ">>>   http://127.0.0.1:${PORT}/workspaces/${SANDBOX}?host=local"
exec "${MISE[@]}" mix phx.server
