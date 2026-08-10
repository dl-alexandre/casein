#!/usr/bin/env bash
# skippable-artifact-upload.sh — stage release-evidence artifacts without
# depending on GitHub Actions upload-artifact quota (#382 sub-slice).
#
# Account-level Actions artifact storage has failed desktop jobs *after*
# build/sign/verify already passed. This helper never weakens verification.
# It only decides how (or whether) to *publish* already-produced files:
#
#   1. Always stage a durable local copy (default under
#      native/casein_menubar/build/artifacts/staged/<label>/).
#   2. Optionally attempt a remote upload command when explicitly enabled.
#   3. Default remote mode is **skip** so CI evidence collection stays green
#      when upload-artifact would hit quota — the staged tree + receipt JSON
#      are the durable proof path (same design as collect-macos-desktop-evidence).
#
# Usage:
#   scripts/lib/skippable-artifact-upload.sh \
#     --label Casein-macos-arm64 \
#     --source native/casein_menubar/build/artifacts \
#     [--dest DIR] \
#     [--receipt PATH] \
#     [--glob 'Casein-*-macos-*.{zip,sha256,evidence.json,manifest.plist}'] \
#     [--mode skip|stage-only|upload] \
#     [--upload-cmd 'command with {} path placeholder']
#
# Environment (override flags):
#   CASEIN_ARTIFACT_UPLOAD_MODE=skip|stage-only|upload
#     skip / stage-only  — stage locally, do not run remote upload (default: skip)
#     upload             — stage, then run --upload-cmd (or CASEIN_ARTIFACT_UPLOAD_CMD)
#   CASEIN_ARTIFACT_UPLOAD_CMD
#     Shell command; `{}` is replaced with the staged directory path.
#   CASEIN_ARTIFACT_STAGE_ROOT
#     Override default stage root.
#
# Exit codes:
#   0  staged (and uploaded when mode=upload and upload cmd succeeded)
#   1  usage / missing source
#   2  nothing matched the glob
#   3  stage copy failed
#   4  upload command failed (only when mode=upload)
#
# Does NOT edit workflows. Callers that still use actions/upload-artifact keep
# that step; a red upload there remains infra/quota, not a packaging failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

label=""
source_dir=""
dest=""
receipt=""
glob='*'
mode="${CASEIN_ARTIFACT_UPLOAD_MODE:-skip}"
upload_cmd="${CASEIN_ARTIFACT_UPLOAD_CMD:-}"
stage_root="${CASEIN_ARTIFACT_STAGE_ROOT:-native/casein_menubar/build/artifacts/staged}"

usage() {
  sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --source) source_dir="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --receipt) receipt="$2"; shift 2 ;;
    --glob) glob="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --upload-cmd) upload_cmd="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$label" || -z "$source_dir" ]]; then
  echo "error: --label and --source are required" >&2
  usage >&2
  exit 1
fi

case "$mode" in
  skip|stage-only|upload) ;;
  *)
    echo "error: --mode must be skip|stage-only|upload (got: $mode)" >&2
    exit 1
    ;;
esac

if [[ ! -d "$source_dir" ]]; then
  echo "error: source directory missing: $source_dir" >&2
  exit 1
fi

# Resolve source to absolute for stable receipt paths.
source_dir="$(cd "$source_dir" && pwd)"

if [[ -z "$dest" ]]; then
  dest="${stage_root%/}/${label}"
fi
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

if [[ -z "$receipt" ]]; then
  receipt="${dest}/upload-receipt.json"
fi
mkdir -p "$(dirname "$receipt")"

# Collect matches (nullglob; fail if empty).
shopt -s nullglob
# shellcheck disable=SC2206
matches=("${source_dir}/"${glob})
shopt -u nullglob

# Also allow recursive single-level common evidence names when glob is default *
if [[ ${#matches[@]} -eq 0 && "$glob" == "*" ]]; then
  shopt -s nullglob
  matches=("${source_dir}"/*)
  shopt -u nullglob
fi

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "error: no files matched under ${source_dir} (glob=${glob})" >&2
  exit 2
fi

staged_names=()
staged_bytes=0
for path in "${matches[@]}"; do
  [[ -e "$path" ]] || continue
  base="$(basename "$path")"
  if [[ -d "$path" ]]; then
    rm -rf "${dest}/${base}"
    cp -a "$path" "${dest}/${base}"
    bytes="$(find "${dest}/${base}" -type f -print0 | xargs -0 wc -c 2>/dev/null | tail -1 | awk '{print $1}')"
    bytes="${bytes:-0}"
  else
    cp -a "$path" "${dest}/${base}"
    bytes="$(wc -c <"${dest}/${base}" | tr -d ' ')"
  fi
  staged_names+=("$base")
  staged_bytes=$((staged_bytes + bytes))
done

if [[ ${#staged_names[@]} -eq 0 ]]; then
  echo "error: matched paths existed but nothing was staged" >&2
  exit 3
fi

upload_attempted=0
upload_skipped=1
upload_ok=0
upload_exit=0
upload_note="remote upload skipped (mode=${mode}); staged tree is durable proof"

case "$mode" in
  skip|stage-only)
    upload_skipped=1
    upload_attempted=0
    ;;
  upload)
    upload_skipped=0
    upload_attempted=1
    if [[ -z "$upload_cmd" ]]; then
      echo "error: mode=upload requires --upload-cmd or CASEIN_ARTIFACT_UPLOAD_CMD" >&2
      exit 1
    fi
    # Replace {} with staged dest. Without a placeholder, export
    # CASEIN_ARTIFACT_STAGED_DIR and run the command unchanged (so bare
    # commands like `exit 9` or custom uploaders are not mangled).
    export CASEIN_ARTIFACT_STAGED_DIR="$dest"
    if [[ "$upload_cmd" == *"{}"* ]]; then
      # shellcheck disable=SC2001
      rendered="$(printf '%s' "$upload_cmd" | sed "s|{}|${dest}|g")"
    else
      rendered="$upload_cmd"
    fi
    set +e
    bash -c "$rendered"
    upload_exit=$?
    set -e
    if [[ "$upload_exit" -eq 0 ]]; then
      upload_ok=1
      upload_note="remote upload command succeeded"
    else
      upload_ok=0
      upload_note="remote upload command failed with exit ${upload_exit}"
    fi
    ;;
esac

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
git_revision="$(git rev-parse HEAD 2>/dev/null || true)"
host="$(hostname 2>/dev/null || true)"
runner_name="${RUNNER_NAME:-}"
github_run_id="${GITHUB_RUN_ID:-}"

# Write receipt without embedding secrets. File names + sizes only.
STAGED_JSON="$(printf '%s\n' "${staged_names[@]}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))')"
export RECEIPT_PATH="$receipt"
export R_LABEL="$label"
export R_SOURCE="$source_dir"
export R_DEST="$dest"
export R_MODE="$mode"
export R_GLOB="$glob"
export R_BYTES="$staged_bytes"
export R_NAMES_JSON="$STAGED_JSON"
export R_UPLOAD_ATTEMPTED="$upload_attempted"
export R_UPLOAD_SKIPPED="$upload_skipped"
export R_UPLOAD_OK="$upload_ok"
export R_UPLOAD_EXIT="$upload_exit"
export R_UPLOAD_NOTE="$upload_note"
export R_GIT="$git_revision"
export R_HOST="$host"
export R_RUNNER="$runner_name"
export R_RUN_ID="$github_run_id"
export R_AT="$started_at"

python3 - <<'PY'
import json, os

def b01(name):
    return os.environ.get(name) == "1"

receipt = {
    "schema": "casein.skippable_artifact_upload/v1",
    "issue": "#382",
    "purpose": (
        "Stage release-evidence artifacts so CI/operators are not blocked when "
        "GitHub Actions upload-artifact hits account storage quota. "
        "Never skips build/sign/verify — only the publish step."
    ),
    "label": os.environ["R_LABEL"],
    "source_dir": os.environ["R_SOURCE"],
    "staged_dir": os.environ["R_DEST"],
    "glob": os.environ["R_GLOB"],
    "mode": os.environ["R_MODE"],
    "staged_file_names": json.loads(os.environ["R_NAMES_JSON"]),
    "staged_bytes": int(os.environ["R_BYTES"] or "0"),
    "upload": {
        "attempted": b01("R_UPLOAD_ATTEMPTED"),
        "skipped": b01("R_UPLOAD_SKIPPED"),
        "ok": b01("R_UPLOAD_OK"),
        "exit_code": int(os.environ.get("R_UPLOAD_EXIT") or "0"),
        "note": os.environ.get("R_UPLOAD_NOTE") or "",
    },
    "git_revision": os.environ.get("R_GIT") or "",
    "host": os.environ.get("R_HOST") or "",
    "runner_name": os.environ.get("R_RUNNER") or "",
    "github_run_id": os.environ.get("R_RUN_ID") or "",
    "recorded_at": os.environ.get("R_AT") or "",
    "quota_note": (
        "A red actions/upload-artifact step after green build/sign/verify is "
        "account artifact storage quota, not a packaging regression. Do not "
        "hack workflows to skip verification. Prefer this staged tree + "
        "evidence JSON as the durable proof path."
    ),
    "proven_here": [
        "local stage copy of release artifacts",
        "receipt JSON with names/sizes/mode",
        "explicit skip of remote upload by default",
    ],
    "needs_human": [
        "Apple Developer ID sign + notarize on a macOS runner/release Mac",
        "account-level Actions artifact quota clearance (optional; not required if staged evidence is attached)",
        "attach staged evidence + hashes on issue #382 / GitHub Release",
    ],
}

path = os.environ["RECEIPT_PATH"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(receipt, f, indent=2, sort_keys=True)
    f.write("\n")
print(path)
PY

echo ">>> skippable-artifact-upload: mode=${mode} staged=${#staged_names[@]} files (${staged_bytes} bytes) -> ${dest}"
echo ">>> receipt: ${receipt}"
echo ">>> upload: attempted=${upload_attempted} skipped=${upload_skipped} ok=${upload_ok} note=${upload_note}"

if [[ "$mode" == "upload" && "$upload_ok" -ne 1 ]]; then
  exit 4
fi

exit 0
