#!/usr/bin/env bash
# Verify the *in-repo* companion signing/distribution contract for #416.
#
# This is deliberately Linux-safe and secret-free. It proves the checked-in
# Debug/Release split (#424/#793), public product names, and secret-path
# hygiene. It does NOT codesign, notarize, talk to Apple/Google, or touch a
# device — those remain operator steps on real hardware (see
# docs/mobile/companion_signing_distribution.md).
#
# Usage:
#   bash scripts/verify-companion-signing-contract.sh
#   bash scripts/verify-companion-signing-contract.sh --json /tmp/out.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOB="${ROOT}/native/casein_mob"
JSON_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

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
    pass "present: ${path#"$ROOT"/}"
  else
    fail "missing: ${path#"$ROOT"/}"
  fi
}

require_grep() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if grep -qE -- "$pattern" "$path"; then
    pass "$label"
  else
    fail "$label (pattern not found in ${path#"$ROOT"/})"
  fi
}

forbid_grep() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if grep -qE -- "$pattern" "$path"; then
    fail "$label (forbidden pattern in ${path#"$ROOT"/})"
  else
    pass "$label"
  fi
}

# --- required layout (post #793 Debug/Release split) ---
require_file "$MOB/ios/CaseinMob.entitlements"
require_file "$MOB/ios/CaseinMob.Release.entitlements"
require_file "$MOB/ios/Provision.xcodeproj/project.pbxproj"
require_file "$MOB/ios/Info.plist"
require_file "$MOB/test/fixtures/ios_development_profile.plist"
require_file "$MOB/test/fixtures/ios_distribution_profile.plist"
require_file "$MOB/android/app/src/main/res/values/strings.xml"
require_file "$MOB/android/app/build.gradle"
require_file "$MOB/.gitignore"

DEV_ENT="$MOB/ios/CaseinMob.entitlements"
REL_ENT="$MOB/ios/CaseinMob.Release.entitlements"
PBX="$MOB/ios/Provision.xcodeproj/project.pbxproj"
PLIST="$MOB/ios/Info.plist"
DEV_FIX="$MOB/test/fixtures/ios_development_profile.plist"
DIST_FIX="$MOB/test/fixtures/ios_distribution_profile.plist"
STRINGS="$MOB/android/app/src/main/res/values/strings.xml"
GRADLE="$MOB/android/app/build.gradle"
GITIGNORE="$MOB/.gitignore"

# --- iOS Debug contract ---
require_grep "$DEV_ENT" 'aps-environment' "ios debug declares aps-environment"
require_grep "$DEV_ENT" '<string>development</string>' "ios debug aps-environment=development"
require_grep "$DEV_ENT" '<key>get-task-allow</key>' "ios debug allows get-task-allow"
require_grep "$DEV_ENT" 'com\.alexandrefamilyfarm\.casein-mob' "ios debug application-identifier bundle"

# --- iOS Release / distribution contract ---
require_grep "$REL_ENT" 'aps-environment' "ios release declares aps-environment"
require_grep "$REL_ENT" '<string>production</string>' "ios release aps-environment=production"
# Match the entitlement key only — comments may mention get-task-allow by name.
forbid_grep "$REL_ENT" '<key>get-task-allow</key>' "ios release omits get-task-allow"
require_grep "$REL_ENT" 'beta-reports-active' "ios release keeps beta-reports-active"

# Xcode project must wire distinct entitlements per configuration.
require_grep "$PBX" 'CODE_SIGN_ENTITLEMENTS = CaseinMob\.entitlements;' \
  "xcode Debug uses CaseinMob.entitlements"
require_grep "$PBX" 'CODE_SIGN_ENTITLEMENTS = CaseinMob\.Release\.entitlements;' \
  "xcode Release uses CaseinMob.Release.entitlements"
require_grep "$PBX" 'CODE_SIGN_IDENTITY = "Apple Distribution"' \
  "xcode Release uses Apple Distribution identity"
require_grep "$PBX" 'PROVISIONING_PROFILE_SPECIFIER = "iOS Team Store Provisioning Profile: com\.alexandrefamilyfarm\.casein-mob"' \
  "xcode Release pins App Store profile specifier name"
require_grep "$PBX" 'PRODUCT_BUNDLE_IDENTIFIER = com\.alexandrefamilyfarm\.casein-mob;' \
  "xcode product bundle id is casein-mob"
require_grep "$PBX" 'DEVELOPMENT_TEAM = 2MP8QWK7R6;' \
  "xcode development team placeholder present (public App ID team)"

# Debug must not accidentally inherit distribution signing.
debug_block="$(
  python3 - <<'PY' "$PBX"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"AA00000B /\* Debug \*/ = \{(.*?)\t\t\};", text, re.S)
if not m:
    sys.exit("missing Debug configuration block")
print(m.group(1))
PY
)"
if printf '%s' "$debug_block" | grep -q 'CaseinMob.Release.entitlements'; then
  fail "xcode Debug must not reference Release entitlements"
else
  pass "xcode Debug does not reference Release entitlements"
fi
if printf '%s' "$debug_block" | grep -q 'Apple Distribution'; then
  fail "xcode Debug must not use Apple Distribution"
else
  pass "xcode Debug does not use Apple Distribution"
fi
if printf '%s' "$debug_block" | grep -q 'PROVISIONING_PROFILE_SPECIFIER'; then
  fail "xcode Debug must not pin a store profile specifier"
else
  pass "xcode Debug leaves profile specifier unset (Automatic)"
fi

# --- public product name Casein (store-facing display, not routing id) ---
if grep -Pzoq '<key>CFBundleDisplayName</key>\s*<string>Casein</string>' "$PLIST" 2>/dev/null ||
  python3 - <<'PY' "$PLIST"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sys.exit(0 if re.search(r"<key>CFBundleDisplayName</key>\s*<string>Casein</string>", text) else 1)
PY
then
  pass "ios CFBundleDisplayName is Casein"
else
  fail "ios CFBundleDisplayName is Casein"
fi
require_grep "$STRINGS" '<string name="app_name">Casein</string>' \
  "android app_name is Casein"

# --- synthetic fixtures stay obviously fake ---
require_grep "$DIST_FIX" 'Obviously fake|FAKE iOS|Synthesi[sz]ed fixture|Not a real provisioning' \
  "distribution fixture declares itself fake"
require_grep "$DEV_FIX" 'Sanitized contract|Obviously fake|FAKE|Not a real' \
  "development fixture is non-secret contract extract"
require_grep "$DEV_FIX" '<string>development</string>' \
  "development fixture aps-environment=development"
require_grep "$DIST_FIX" '<string>production</string>' \
  "distribution fixture aps-environment=production"
# development fixture MUST keep get-task-allow; distribution must not.
require_grep "$DEV_FIX" '<key>get-task-allow</key>' "development fixture keeps get-task-allow"
forbid_grep "$DIST_FIX" '<key>get-task-allow</key>' "distribution fixture omits get-task-allow"

# --- Android release signing is optional and gitignored ---
require_grep "$GRADLE" 'keystore\.properties' \
  "android release signing loads gitignored keystore.properties"
require_grep "$GRADLE" 'signingConfigs' \
  "android declares signingConfigs.release"
require_grep "$GITIGNORE" 'android/keystore\.properties' \
  "gitignore blocks android/keystore.properties"
require_grep "$GITIGNORE" 'android/\*\.keystore' \
  "gitignore blocks android/*.keystore"

# Provisioning profiles / Apple private material must never be tracked.
for pattern in \
  '\.mobileprovision' \
  '\.p12$' \
  'AuthKey_.*\.p8' \
  'google-services\.json' \
  'notarytool' \
  'APPLE_ID_PASSWORD' \
  'CASEIN_NOTARY'
do
  if git -C "$ROOT" ls-files | grep -Eiq -- "$pattern"; then
    fail "tracked secret-shaped path matches /$pattern/"
  else
    pass "no tracked path matches /$pattern/"
  fi
done

# gitignore should refuse common Apple/Android secret droppings under the mob tree.
for needle in \
  '*.mobileprovision' \
  '*.p12' \
  'AuthKey_*.p8' \
  'google-services.json'
do
  if grep -Fq -- "$needle" "$GITIGNORE"; then
    pass "gitignore includes $needle"
  else
    fail "gitignore missing $needle"
  fi
done

# Never claim physical install / notarization from this contract alone.
claim_doc="$ROOT/docs/mobile/companion_signing_distribution.md"
require_file "$claim_doc"
require_grep "$claim_doc" 'cannot be completed from this box|physical device|operator' \
  "runbook states physical reach limits"
require_grep "$claim_doc" 'notarytool' \
  "runbook documents notarytool operator path"
require_grep "$claim_doc" 'aps-environment=development' \
  "runbook requires dedicated push-capable development profile"
require_grep "$claim_doc" 'INSTALL_FAILED_INSUFFICIENT_STORAGE|free sufficient storage' \
  "runbook covers Android storage gate"
forbid_grep "$claim_doc" 'BEGIN (CERTIFICATE|PRIVATE KEY)|-----BEGIN' \
  "runbook contains no PEM material"

status=0
if ((${#failures[@]} > 0)); then
  status=1
  printf '\n%d/%d checks failed:\n' "${#failures[@]}" "$checks" >&2
  printf '  - %s\n' "${failures[@]}" >&2
else
  printf '\n%d/%d checks passed (contract only — no device/signing performed)\n' "$checks" "$checks"
fi

if [[ -n "$JSON_OUT" ]]; then
  python3 - <<'PY' "$JSON_OUT" "$status" "$checks" "${#failures[@]}" "${failures[@]+"${failures[@]}"}"
import json, sys
out, status, checks, nfail = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
failures = sys.argv[5:] if nfail else []
payload = {
    "schema": 1,
    "kind": "companion_signing_contract",
    "issue": 416,
    "passed": status == 0,
    "checks": checks,
    "failures": failures,
    "claims": {
        "in_repo_debug_release_split": True,
        "public_product_name_casein": True,
        "physical_device_install": False,
        "apple_agreement_accepted": False,
        "dedicated_ios_development_profile": False,
        "gatekeeper_notarization": False,
        "play_console_upload": False,
        "apns_fcm_delivery": False,
        "cross_origin_physical_pairing": False,
    },
    "note": (
        "Synthetic contract only. Fixtures are obviously fake. "
        "Physical distribution and real credentials remain operator work."
    ),
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
  printf 'wrote %s\n' "$JSON_OUT"
fi

exit "$status"
