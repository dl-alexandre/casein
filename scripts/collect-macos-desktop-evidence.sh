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
#     [--out path/to/evidence.json] \
#     [--dry-run] \
#     [--staging-receipt path/to/upload-receipt.json]
#
# --dry-run writes an incomplete evidence document with explicit
# missing: ["developer_id","notary_profile","signed_lifecycle"] and never
# claims signed/notarized success. Safe on Linux; no silent pass.
#
# --staging-receipt optionally embeds a skippable-artifact-upload receipt
# summary under staging{} (mode/upload flags only — never secrets). Upload
# success is not release evidence.
#
# Never embeds certificates, passwords, API keys, or provisioning profiles.
set -euo pipefail

cd "$(dirname "$0")/.."

app=""
archive=""
out=""
result="running"
error=""
dry_run=0
staging_receipt=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --staging-receipt) staging_receipt="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
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
# Canonical incomplete codes for pre-operator / dry-run evidence. Never silent-pass.
missing_codes=("developer_id" "notary_profile" "signed_lifecycle")
claim_developer_id=false
claim_notarized=false
claim_stapled=false
claim_signed_lifecycle=false
claim_passed_release=false

record_phase() {
  phases+=("$1")
}

set_missing() {
  missing_codes=("$@")
}

if [[ "$dry_run" -eq 1 ]]; then
  result="incomplete"
  error="dry-run: no Developer ID, notary profile, or signed lifecycle material claimed"
  record_phase "dry_run"
  if [[ "$host_os" != "Darwin" ]]; then
    record_phase "host_stub"
  fi
  set_missing "developer_id" "notary_profile" "signed_lifecycle"
elif [[ "$host_os" != "Darwin" ]]; then
  result="blocked"
  error="collect-macos-desktop-evidence requires Darwin for signature/notarization probes; wrote host-only stub"
  record_phase "host_stub"
  set_missing "developer_id" "notary_profile" "signed_lifecycle" "darwin_host"
elif [[ "$app_exists" -ne 1 ]]; then
  result="failed"
  error="app bundle not found: $app"
  record_phase "app_missing"
  set_missing "developer_id" "notary_profile" "signed_lifecycle" "app_bundle"
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
      # Material present for sign+notary+staple. Lifecycle stays operator-attested;
      # never auto-claim signed_lifecycle without CASEIN_LIFECYCLE_ATTESTED=1.
      claim_developer_id=true
      claim_notarized=true
      claim_stapled=true
      if [[ "${CASEIN_LIFECYCLE_ATTESTED:-0}" == "1" ]]; then
        result="passed_release"
        claim_signed_lifecycle=true
        claim_passed_release=true
        set_missing
      else
        result="incomplete"
        error="Developer ID + staple green; signed_lifecycle still requires operator attestation (CASEIN_LIFECYCLE_ATTESTED=1 after clean-Mac checklist)"
        set_missing "signed_lifecycle"
      fi
    elif [[ "$signature_kind" == "developer_id" ]]; then
      result="signed_unnotarized"
      claim_developer_id=true
      set_missing "notary_profile" "signed_lifecycle"
    elif [[ "$signature_kind" == "adhoc" ]]; then
      result="adhoc_smoke_only"
      set_missing "developer_id" "notary_profile" "signed_lifecycle"
    else
      result="incomplete"
      set_missing "developer_id" "notary_profile" "signed_lifecycle"
    fi
  elif [[ "$result" == "failed" ]]; then
    set_missing "developer_id" "notary_profile" "signed_lifecycle"
  fi
fi

# Non-release results must always carry explicit missing[] (no silent pass).
if [[ "$result" != "passed_release" && ${#missing_codes[@]} -eq 0 ]]; then
  set_missing "developer_id" "notary_profile" "signed_lifecycle"
fi

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
phases_json="$(printf '%s\n' "${phases[@]+"${phases[@]}"}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
missing_json="$(printf '%s\n' "${missing_codes[@]+"${missing_codes[@]}"}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

# Optional staging receipt from skippable-artifact-upload (#834) — summary only.
staging_receipt_path=""
staging_mode="skip"
staging_upload_attempted=false
staging_upload_succeeded=false
if [[ -n "$staging_receipt" ]]; then
  if [[ -f "$staging_receipt" ]]; then
    staging_receipt_path="$(cd "$(dirname "$staging_receipt")" && pwd)/$(basename "$staging_receipt")"
    # shellcheck disable=SC2016
    eval "$(
      python3 - "$staging_receipt_path" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    print('staging_mode="unknown"')
    print("staging_upload_attempted=false")
    print("staging_upload_succeeded=false")
    raise SystemExit(0)
mode = data.get("mode") or data.get("upload_mode") or "unknown"
attempted = data.get("upload_attempted")
if attempted is None:
    attempted = data.get("upload_ran")
succeeded = data.get("upload_succeeded")
if succeeded is None:
    succeeded = data.get("upload_ok")
def b(v):
    return "true" if v is True else "false"
# Sanitize mode to a short token for JSON embedding.
mode_s = "".join(c if c.isalnum() or c in "-_" else "-" for c in str(mode))[:32] or "unknown"
print(f'staging_mode="{mode_s}"')
print(f"staging_upload_attempted={b(bool(attempted))}")
print(f"staging_upload_succeeded={b(bool(succeeded))}")
PY
    )"
    record_phase "staging_receipt"
  else
    error="${error:+$error; }staging receipt not found: $staging_receipt"
    staging_receipt_path="$staging_receipt"
    staging_mode="unknown"
    record_phase "staging_receipt_missing"
  fi
fi

# Optional operator fixture ref names (basenames only — never path secrets).
fixture_ref_developer_id="${CASEIN_FIXTURE_REF_DEVELOPER_ID:-}"
fixture_ref_notary_profile="${CASEIN_FIXTURE_REF_NOTARY_PROFILE:-}"
fixture_ref_signed_lifecycle="${CASEIN_FIXTURE_REF_SIGNED_LIFECYCLE:-}"

cat >"$out" <<EOF
{
  "schema": 1,
  "kind": "macos_desktop_release_evidence",
  "issue": 382,
  "started_at_utc": $(json_escape "$started_at"),
  "completed_at_utc": $(json_escape "$completed_at"),
  "result": $(json_escape "$result"),
  "error": $(json_escape "$error"),
  "missing": $missing_json,
  "claims": {
    "developer_id": $claim_developer_id,
    "notarized": $claim_notarized,
    "stapled": $claim_stapled,
    "signed_lifecycle": $claim_signed_lifecycle,
    "passed_release": $claim_passed_release
  },
  "fixture_refs": {
    "developer_id": $(json_escape "$fixture_ref_developer_id"),
    "notary_profile": $(json_escape "$fixture_ref_notary_profile"),
    "signed_lifecycle": $(json_escape "$fixture_ref_signed_lifecycle")
  },
  "staging": {
    "receipt_path": $(json_escape "$staging_receipt_path"),
    "receipt_mode": $(json_escape "$staging_mode"),
    "upload_attempted": $staging_upload_attempted,
    "upload_succeeded": $staging_upload_succeeded
  },
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
    "Never store Apple credentials, certificates, or notarization tokens in this file.",
    "Dry-run and incomplete results must list missing[] explicitly; validate-macos-desktop-evidence.sh rejects silent passes.",
    "staging.upload_succeeded is not release evidence; attach local evidence JSON to issue #382."
  ]
}
EOF

echo "Wrote macOS desktop evidence: $out"
echo "result=$result"
echo "missing=$missing_json"

if [[ "$dry_run" -eq 1 || "$result" != "passed_release" ]]; then
  echo "---- operator checklist ----"
  for code in "${missing_codes[@]+"${missing_codes[@]}"}"; do
    case "$code" in
      developer_id)
        echo "NEED (human): developer_id"
        echo "Operator steps: Install Developer ID Application (and Installer if shipping a pkg) on the release Mac keychain."
        echo "Unblocks when: security find-identity -v -p codesigning shows Developer ID Application: …"
        ;;
      notary_profile)
        echo "NEED (human): notary_profile"
        echo "Operator steps: Store notarytool credentials (xcrun notarytool store-credentials casein-notary …)."
        echo "Unblocks when: CASEIN_NOTARY_KEYCHAIN_PROFILE is set and notarize-macos-desktop.sh staples green"
        ;;
      signed_lifecycle)
        echo "NEED (human): signed_lifecycle"
        echo "Operator steps: On a clean supported macOS run first launch, login-item, update/rollback if applicable, uninstall; attach notes."
        echo "Unblocks when: lifecycle checklist completed and CASEIN_LIFECYCLE_ATTESTED=1 on collect after material sign+staple"
        ;;
      *)
        echo "NEED (human): $code"
        echo "Operator steps: Resolve missing evidence code \`$code\` on the release Mac."
        echo "Unblocks when: \`$code\` no longer appears in missing[]"
        ;;
    esac
    echo ""
  done
fi

# Always exit 0 after writing evidence so callers can attach a blocked/failed
# document. Release gates that require a green result must inspect `result`
# (and run validate-macos-desktop-evidence.sh).
exit 0
