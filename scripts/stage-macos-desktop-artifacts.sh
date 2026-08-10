#!/usr/bin/env bash
# stage-macos-desktop-artifacts.sh — release-evidence path helper for #382.
#
# Thin wrapper around scripts/lib/skippable-artifact-upload.sh for the macOS
# desktop package tree. Stages zip/sha256/manifest/evidence.json so operators
# and CI are not blocked when actions/upload-artifact hits account quota.
#
# Does not sign, notarize, or claim #382 closed. Does not edit workflows.
#
# Usage:
#   scripts/stage-macos-desktop-artifacts.sh
#   scripts/stage-macos-desktop-artifacts.sh --label Casein-macos-arm64
#   CASEIN_ARTIFACT_UPLOAD_MODE=upload \
#     CASEIN_ARTIFACT_UPLOAD_CMD='echo would-upload {}' \
#     scripts/stage-macos-desktop-artifacts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

label="${CASEIN_ARTIFACT_LABEL:-}"
source_dir="${CASEIN_ARTIFACT_SOURCE:-native/casein_menubar/build/artifacts}"
# Prefer evidence-bearing package outputs; fall back to * inside the helper.
glob='Casein-*-macos-*'
mode="${CASEIN_ARTIFACT_UPLOAD_MODE:-skip}"
upload_cmd="${CASEIN_ARTIFACT_UPLOAD_CMD:-}"
dest=""
receipt=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --source) source_dir="$2"; shift 2 ;;
    --glob) glob="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --upload-cmd) upload_cmd="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --receipt) receipt="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$label" ]]; then
  arch="$(uname -m 2>/dev/null || echo unknown)"
  label="Casein-macos-${arch}"
fi

args=(
  --label "$label"
  --source "$source_dir"
  --glob "$glob"
  --mode "$mode"
)
[[ -n "$dest" ]] && args+=(--dest "$dest")
[[ -n "$receipt" ]] && args+=(--receipt "$receipt")
[[ -n "$upload_cmd" ]] && args+=(--upload-cmd "$upload_cmd")

exec bash "$ROOT/scripts/lib/skippable-artifact-upload.sh" "${args[@]}"
