#!/usr/bin/env bash
# Collect immutable macOS desktop release evidence as JSON next to the package.
#
# Designed to work *without* GitHub Actions artifact upload. Account-level
# artifact storage quota has been failing desktop jobs at upload-artifact only;
# this script writes a small evidence document the operator can attach to the
# release issue, a GitHub Release, or local release storage.
#
# Usage:
#   scripts/collect-macos-desktop-evidence.sh \
#     [--app path/to/Casein\ MenuBar.app] \
#     [--archive path/to/Casein-*-macos-*.zip] \
#     [--out path/to/evidence.json]
#
# Never embeds certificates, passwords, API keys, or provisioning profiles.
set -euo pipefail

cd "$(dirname "$0")/.."

app=""
archive=""
out=""
result="running"
error=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

app="${app:-native/casein_menubar/build/Casein MenuBar.app}"
if [[ -z "$archive" ]]; then
  shopt -s nullglob
  archives=(native/casein_menubar/build/artifacts/Casein-*-macos-*.zip)
  shopt -u nullglob
  if [[ ${#archives[@]} -eq 1 ]]; then
    archive="${archives[0]}"
  fi
fi

if [[ -z "$out" ]]; then
  if [[ -n "${archive:-}" ]]; then
    out="${archive%.zip}.evidence.json"
  else
    out="native/casein_menubar/build/artifacts/casein-macos-evidence.json"
  fi
fi

mkdir -p "$(dirname "$out")"

json_escape() {
  # Minimal JSON string escape for controlled operator fields.
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

host_os="$(uname -s)"
host_arch="$(uname -m)"
host_release="$(uname -r)"
runner_name="${RUNNER_NAME:-}"
runner_os="${RUNNER_OS:-}"
runner_arch="${RUNNER_ARCH:-}"
github_run_id="${GITHUB_RUN_ID:-}"
github_sha="${GITHUB_SHA:-}"
git_revision="$(git rev-parse HEAD 2>/dev/null || true)"
git_describe="$(git describe --always --dirty 2>/dev/null || true)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

app_exists=0
[[ -d "$app" ]] && app_exists=1
archive_exists=0
[[ -n "${archive:-}" && -f "$archive" ]] && archive_exists=1

archive_sha256=""
archive_bytes=0
if [[ "$archive_exists" -eq 1 ]]; then
  archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
  if command -v shasum >/dev/null 2>&1; then
    archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  fi
  archive_bytes="$(wc -c <"$archive" | tr -d ' ')"
fi

codesign_authority=""
codesign_team=""
codesign_flags=""
codesign_identifier=""
signature_kind="missing"
hardened_runtime=0
spctl_status="skipped"
stapler_status="skipped"
verify_status="skipped"
phases=()

record_phase() {
  phases+=("$1")
}

if [[ "$host_os" != "Darwin" ]]; then
  result="blocked"
  error="collect-macos-desktop-evidence requires Darwin for signature/notarization probes; wrote host-only stub"
  record_phase "host_stub"
elif [[ "$app_exists" -ne 1 ]]; then
  result="failed"
  error="app bundle not found: $app"
  record_phase "app_missing"
else
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  record_phase "app_present"

  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    verify_status="passed"
    record_phase "codesign_verify"
  else
    verify_status="failed"
    result="failed"
    error="codesign --verify --deep --strict failed"
    record_phase "codesign_verify_failed"
  fi

  detail="$(codesign -dvvv "$app" 2>&1 || true)"
  codesign_authority="$(printf '%s\n' "$detail" | sed -n 's/^Authority=//p' | head -n 1)"
  codesign_team="$(printf '%s\n' "$detail" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  codesign_flags="$(printf '%s\n' "$detail" | sed -n 's/^Flags=//p; s/^CodeDirectory.*flags=//p' | head -n 1)"
  codesign_identifier="$(printf '%s\n' "$detail" | sed -n 's/^Identifier=//p' | head -n 1)"
  if printf '%s\n' "$detail" | grep -q 'Signature=adhoc'; then
    signature_kind="adhoc"
  elif printf '%s\n' "$detail" | grep -q 'Authority=Developer ID Application:'; then
    signature_kind="developer_id"
  elif [[ -n "$codesign_authority" ]]; then
    signature_kind="other"
  fi
  if printf '%s\n' "$detail" | grep -q '(runtime)'; then
    hardened_runtime=1
    record_phase "hardened_runtime"
  fi
  record_phase "codesign_identity"

  if spctl_output="$(spctl --assess --type execute --verbose=4 "$app" 2>&1)"; then
    spctl_status="accepted"
    record_phase "spctl_accepted"
  else
    # Keep the first line only — enough to distinguish Unnotarized vs rejected.
    spctl_status="$(printf '%s\n' "$spctl_output" | head -n 1 | tr -d '\r')"
    record_phase "spctl_assessed"
  fi

  if command -v xcrun >/dev/null 2>&1; then
    if xcrun stapler validate "$app" >/dev/null 2>&1; then
      stapler_status="valid"
      record_phase "stapler_valid"
    else
      stapler_status="missing_or_invalid"
      record_phase "stapler_checked"
    fi
  fi

  if [[ "$result" == "running" ]]; then
    if [[ "$signature_kind" == "developer_id" && "$stapler_status" == "valid" && "$spctl_status" == "accepted" ]]; then
      result="passed_release"
    elif [[ "$signature_kind" == "developer_id" ]]; then
      result="signed_unnotarized"
    elif [[ "$signature_kind" == "adhoc" ]]; then
      result="adhoc_smoke_only"
    else
      result="incomplete"
    fi
  fi
fi

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
phases_json="$(printf '%s\n' "${phases[@]+"${phases[@]}"}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

cat >"$out" <<EOF
{
  "schema": 1,
  "kind": "macos_desktop_release_evidence",
  "issue": 382,
  "started_at_utc": $(json_escape "$started_at"),
  "completed_at_utc": $(json_escape "$completed_at"),
  "result": $(json_escape "$result"),
  "error": $(json_escape "$error"),
  "git": {
    "revision": $(json_escape "$git_revision"),
    "describe": $(json_escape "$git_describe"),
    "github_sha": $(json_escape "$github_sha")
  },
  "host": {
    "os": $(json_escape "$host_os"),
    "arch": $(json_escape "$host_arch"),
    "release": $(json_escape "$host_release"),
    "runner_name": $(json_escape "$runner_name"),
    "runner_os": $(json_escape "$runner_os"),
    "runner_arch": $(json_escape "$runner_arch"),
    "github_run_id": $(json_escape "$github_run_id")
  },
  "app": {
    "path": $(json_escape "$app"),
    "exists": $([[ "$app_exists" -eq 1 ]] && echo true || echo false),
    "bundle_identifier": $(json_escape "$codesign_identifier"),
    "signature_kind": $(json_escape "$signature_kind"),
    "signer_authority": $(json_escape "$codesign_authority"),
    "team_identifier": $(json_escape "$codesign_team"),
    "codesign_flags": $(json_escape "$codesign_flags"),
    "hardened_runtime": $([[ "$hardened_runtime" -eq 1 ]] && echo true || echo false),
    "codesign_verify": $(json_escape "$verify_status"),
    "spctl": $(json_escape "$spctl_status"),
    "stapler": $(json_escape "$stapler_status")
  },
  "archive": {
    "path": $(json_escape "${archive:-}"),
    "exists": $([[ "$archive_exists" -eq 1 ]] && echo true || echo false),
    "sha256": $(json_escape "$archive_sha256"),
    "bytes": $archive_bytes
  },
  "phases": $phases_json,
  "notes": [
    "Ad-hoc CI smoke is not release evidence (issue #382).",
    "GitHub Actions artifact upload may fail on account storage quota even when build/sign/verify passed; this JSON is the durable evidence document.",
    "Never store Apple credentials, certificates, or notarization tokens in this file."
  ]
}
EOF

echo "Wrote macOS desktop evidence: $out"
echo "result=$result"

# Always exit 0 after writing evidence so callers can attach a blocked/failed
# document. Release gates that require a green result must inspect `result`.
exit 0
