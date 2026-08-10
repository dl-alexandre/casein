#!/usr/bin/env bash
# Secret-free companion signing **fixture** validator (#416 slice2).
#
# Validates the obviously-fake iOS profile plists under
# native/casein_mob/test/fixtures/. Does NOT codesign, load real
# .mobileprovision blobs, talk to Apple/Google, or claim physical install.
#
# Sibling scripts (do not duplicate their jobs here):
#   scripts/verify-companion-signing-contract.sh  — Debug/Release project lock
#   scripts/verify-companion-external-prereqs.sh — NEED-code operator checklist
#
# Usage:
#   bash scripts/verify-companion-fixtures.sh
#   bash scripts/verify-companion-fixtures.sh --json /tmp/out.json
#   bash scripts/verify-companion-fixtures.sh --fixture-dir PATH
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${ROOT}/native/casein_mob/test/fixtures"
JSON_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    --fixture-dir)
      FIXTURE_DIR="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

DEV_FIX="${FIXTURE_DIR}/ios_development_profile.plist"
DIST_FIX="${FIXTURE_DIR}/ios_distribution_profile.plist"

failures=()
checks=0

pass() {
  checks=$((checks + 1))
  printf 'ok  %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  failures+=("$1")
  printf 'FAIL %s\n' "$1" >&2
}

require_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    pass "present: ${path}"
  else
    fail "missing: ${path}"
  fi
}

require_grep() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ -f "$path" ]] && grep -qE -- "$pattern" "$path"; then
    pass "$label"
  else
    fail "$label"
  fi
}

forbid_grep() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "$path" ]]; then
    fail "$label (file missing)"
    return
  fi
  if grep -qE -- "$pattern" "$path"; then
    fail "$label"
  else
    pass "$label"
  fi
}

# --- layout ---
require_file "$DEV_FIX"
require_file "$DIST_FIX"

# --- must stay text plists (never binary mobileprovision / CMS) ---
for path in "$DEV_FIX" "$DIST_FIX"; do
  base="$(basename "$path")"
  if [[ -f "$path" ]] && head -c 5 "$path" | grep -q '<?xml\|<!DOC\|<plist'; then
    pass "$base starts as XML/plist text"
  else
    fail "$base must be text plist (not binary .mobileprovision)"
  fi
  # Real Apple profiles are often CMS/DER; reject common binary markers.
  if [[ -f "$path" ]] && grep -aIq . "$path" 2>/dev/null; then
    pass "$base is text-detectable"
  else
    # grep -I treats binary as non-text
    if [[ -f "$path" ]] && ! grep -aIq . "$path" 2>/dev/null; then
      fail "$base looks binary"
    fi
  fi
done

# --- obviously fake labels (never real portal extracts) ---
require_grep "$DEV_FIX" 'Sanitized contract|Obviously fake|FAKE|Not a real' \
  "development fixture labeled non-secret/fake"
require_grep "$DIST_FIX" 'Obviously fake|FAKE iOS|Not a real|Synthesi[sz]ed fixture' \
  "distribution fixture labeled fake"
require_grep "$DIST_FIX" 'FAKE iOS Team Store Provisioning Profile' \
  "distribution Name is FAKE store profile string"

# --- push environment split ---
require_grep "$DEV_FIX" '<string>development</string>' \
  "development fixture aps-environment=development"
require_grep "$DIST_FIX" '<string>production</string>' \
  "distribution fixture aps-environment=production"
require_grep "$DEV_FIX" '<key>get-task-allow</key>' \
  "development fixture keeps get-task-allow"
forbid_grep "$DIST_FIX" '<key>get-task-allow</key>' \
  "distribution fixture omits get-task-allow"
require_grep "$DIST_FIX" 'beta-reports-active' \
  "distribution fixture keeps beta-reports-active"

# --- bundle identity (public App ID shape; team id is already on the checked-in project) ---
require_grep "$DEV_FIX" 'com\.alexandrefamilyfarm\.casein-mob' \
  "development fixture application-identifier bundle"
require_grep "$DIST_FIX" 'com\.alexandrefamilyfarm\.casein-mob' \
  "distribution fixture application-identifier bundle"

# --- no PEM / private key / notary / push key material ---
for path in "$DEV_FIX" "$DIST_FIX"; do
  base="$(basename "$path")"
  forbid_grep "$path" 'BEGIN (CERTIFICATE|PRIVATE KEY|RSA PRIVATE)|-----BEGIN' \
    "$base has no PEM blocks"
  forbid_grep "$path" 'AuthKey_|notarytool|APPLE_ID_PASSWORD|CASEIN_NOTARY' \
    "$base has no credential-shaped tokens"
  # Device UDIDs are 25 hex / 40 hex; fixtures must not carry real device lists.
  forbid_grep "$path" '<key>ProvisionedDevices</key>' \
    "$base omits ProvisionedDevices (no UDID list)"
  forbid_grep "$path" '<key>DeveloperCertificates</key>' \
    "$base omits DeveloperCertificates (no cert bytes)"
  forbid_grep "$path" '<key>UUID</key>' \
    "$base omits portal UUID"
done

# --- structural parse via python (plist-ish XML) ---
if python3 - <<'PY' "$DEV_FIX" "$DIST_FIX"
import re, sys
from pathlib import Path

def load(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")

errors = []
for path, want_aps, want_task in (
    (sys.argv[1], "development", True),
    (sys.argv[2], "production", False),
):
    text = load(path)
    if "<plist" not in text or "</plist>" not in text:
        errors.append(f"{path}: not a plist shell")
    if not re.search(rf"<key>aps-environment</key>\s*<string>{want_aps}</string>", text):
        errors.append(f"{path}: aps-environment!={want_aps}")
    has_task = "<key>get-task-allow</key>" in text
    if has_task != want_task:
        errors.append(f"{path}: get-task-allow present={has_task} want={want_task}")
    # Reject long base64-looking blobs (cert payloads).
    for m in re.finditer(r">([A-Za-z0-9+/=]{200,})<", text):
        errors.append(f"{path}: long base64-like payload ({len(m.group(1))} chars)")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("structural ok")
PY
then
  pass "python structural parse of both fixtures"
else
  fail "python structural parse of both fixtures"
fi

printf 'fixture development=%s\n' "${DEV_FIX#"$ROOT"/}"
printf 'fixture distribution=%s\n' "${DIST_FIX#"$ROOT"/}"

status=0
if ((${#failures[@]} > 0)); then
  status=1
  printf '\n%d/%d fixture checks failed:\n' "${#failures[@]}" "$checks" >&2
  printf '  - %s\n' "${failures[@]}" >&2
else
  printf '\n%d/%d fixture checks passed (synthetic only — no real profiles)\n' "$checks" "$checks"
fi

if [[ -n "$JSON_OUT" ]]; then
  fail_tmp="$(mktemp)"
  printf '%s\n' "${failures[@]+"${failures[@]}"}" >"$fail_tmp"
  python3 - <<'PY' "$JSON_OUT" "$status" "$checks" "$fail_tmp" "${DEV_FIX#"$ROOT"/}" "${DIST_FIX#"$ROOT"/}"
import json, sys
from pathlib import Path

out, status, checks = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fail_path, dev_rel, dist_rel = sys.argv[4], sys.argv[5], sys.argv[6]
failures = [ln for ln in Path(fail_path).read_text(encoding="utf-8").splitlines() if ln]
payload = {
    "schema": 1,
    "kind": "companion_fixtures",
    "issue": 416,
    "passed": status == 0,
    "checks": checks,
    "failures": failures,
    "fixtures": {"development": dev_rel, "distribution": dist_rel},
    "claims": {
        "fixtures_obviously_fake": True,
        "physical_device_install": False,
        "real_signing_material": False,
        "real_mobileprovision_present": False,
    },
    "note": (
        "Synthetic fixture validation only. Fixtures are obviously fake text plists. "
        "Real .mobileprovision / certs / device UDIDs remain operator work (NEED human)."
    ),
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  rm -f "$fail_tmp"
  printf 'wrote %s\n' "$JSON_OUT"
fi

exit "$status"
