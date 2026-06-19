#!/usr/bin/env bash
#
# devide-preview-agent.sh — one-shot preview env + agent pairing exports.
#
# Boots (or reuses) a preview environment, prints agent-env exports, and hints
# at materialize/launch commands.
#
# Usage:
#   bash scripts/devide-preview-agent.sh up [ref]     # committed ref (preview-env up)
#   bash scripts/devide-preview-agent.sh dirty        # working tree (preview-env dirty)
#   bash scripts/devide-preview-agent.sh env <id>     # print agent-env only
#   bash scripts/devide-preview-agent.sh ls
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW="$ROOT/scripts/preview-env.sh"

log() { printf '>>> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cmd="${1:-up}"
shift || true

case "$cmd" in
  up)
    log "starting preview environment"
    "$PREVIEW" up "$@" | tee /dev/stderr
    id="$(ls -t "$(dirname "$ROOT")/.devide-preview/instances"/*.json 2>/dev/null | head -1)"
    id="${id##*/}"; id="${id%.json}"
    ;;
  dirty)
    log "starting dirty preview environment"
    if [[ "${1:-}" == "--background" ]]; then
      shift
      "$PREVIEW" dirty "$@"
      id="$(ls -t "$(dirname "$ROOT")/.devide-preview/instances"/dirty-*.json 2>/dev/null | head -1)"
      id="${id##*/}"; id="${id%.json}"
    else
      log "foreground mode — run agent-env in another shell after boot"
      exec "$PREVIEW" dirty --foreground "$@"
    fi
    ;;
  env)
    id="${1:?usage: devide-preview-agent.sh env <id>}"
    ;;
  ls)
    exec "$PREVIEW" ls "$@"
    ;;
  *)
    echo "usage: $0 {up [ref]|dirty [--background]|env <id>|ls}" >&2
    exit 2
    ;;
esac

[ -n "${id:-}" ] || die "could not resolve preview env id"

log "agent pairing for ${id}"
echo
"$PREVIEW" agent-env "$id"
echo
log "next: eval \"\$($PREVIEW agent-env $id)\" && bash scripts/materialize-agent-mcp.sh && bash scripts/launch-devide-agent.sh grok"