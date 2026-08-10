#!/usr/bin/env bash
# Executable external-prereq checklist for companion signing/install (#416).
#
# Linux-safe and secret-free. Does NOT codesign, notarize, talk to Apple/Google,
# or touch a device. Real signing material must stay off-repo.
#
# Modes:
#   --dry-run   Validate fixtures + in-repo contract; print structured NEED
#               checklist; exit 0 (lab path — no real material required).
#   (default)   Same checks, then require operator env markers for real material.
#               Missing markers → non-zero exit with NEED codes.
#
# Usage:
#   bash scripts/verify-companion-external-prereqs.sh --dry-run
#   bash scripts/verify-companion-external-prereqs.sh --dry-run --json /tmp/out.json
#   bash scripts/verify-companion-external-prereqs.sh
#   bash scripts/verify-companion-external-prereqs.sh --json /tmp/out.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOB="${ROOT}/native/casein_mob"
CONTRACT="${ROOT}/scripts/verify-companion-signing-contract.sh"
RUNBOOK="${ROOT}/docs/mobile/companion_signing_distribution.md"
DEV_FIX="${MOB}/test/fixtures/ios_development_profile.plist"
DIST_FIX="${MOB}/test/fixtures/ios_distribution_profile.plist"

DRY_RUN=0
JSON_OUT=""
SKIP_CONTRACT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON_OUT="${2:-}"
      shift 2
      ;;
    --skip-contract)
      SKIP_CONTRACT=1
      shift
      ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

failures=()
needs=()
satisfied=()
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

need() {
  local code="$1"
  shift
  needs+=("$code")
  printf 'NEED %s — %s\n' "$code" "$*"
}

# Ordered external prereqs (operator/Account Holder). Codes are stable for CI/docs.
NEED_CATALOG=(
  "APPLE_AGREEMENT|Account Holder accepts pending Apple Developer / App Store Connect Program License Agreement"
  "IOS_DEV_PROFILE|Dedicated iOS Development profile for com.alexandrefamilyfarm.casein-mob with Push + aps-environment=development; devices Coding iPad + DairyPhoneDeaux; no wildcard (0xe8008015)"
  "IOS_PHYSICAL_INSTALL|Install exact signed build; matrix portrait/landscape/keyboard, warm/cold/force-quit, origin/offline/stale, Evidence Handoff, intervention/replay"
  "ANDROID_STORAGE_INSTALL|SM-T390 free storage without wiping Casein data; adb install -r / mix mob.deploy preserve-data; launcher Casein; on-device matrix"
  "PLAY_PUBLIC_NAME|Google Play Console public product name is Casein"
  "ASC_PUBLIC_NAME|App Store Connect public product name is Casein"
  "NOTARYTOOL_KEYCHAIN|notarytool keychain profile + Gatekeeper on release Mac (desktop sibling #382/#796 — companion channel only documents the NEED)"
  "APNS_FCM_DELIVERY|Validate APNs/FCM with existing secure host credentials only — never paste tokens into tickets"
  "CROSS_ORIGIN_PAIR|Unlock Local Mac; SM-T390 scans real pairing QR; Devbox ↔ Local Mac switching; do not mutate Devbox operator panes"
)

# Env markers operators may set on a release Mac after real material is present.
# Values are never printed. Presence alone satisfies the non-dry-run gate.
need_env_for() {
  case "$1" in
    APPLE_AGREEMENT) echo CASEIN_COMPANION_APPLE_AGREEMENT_OK ;;
    IOS_DEV_PROFILE) echo CASEIN_COMPANION_IOS_DEV_PROFILE_PATH ;;
    IOS_PHYSICAL_INSTALL) echo CASEIN_COMPANION_IOS_PHYSICAL_OK ;;
    ANDROID_STORAGE_INSTALL) echo CASEIN_COMPANION_ANDROID_INSTALL_OK ;;
    PLAY_PUBLIC_NAME) echo CASEIN_COMPANION_PLAY_NAME_OK ;;
    ASC_PUBLIC_NAME) echo CASEIN_COMPANION_ASC_NAME_OK ;;
    NOTARYTOOL_KEYCHAIN) echo CASEIN_COMPANION_NOTARY_PROFILE ;;
    APNS_FCM_DELIVERY) echo CASEIN_COMPANION_PUSH_OK ;;
    CROSS_ORIGIN_PAIR) echo CASEIN_COMPANION_CROSS_ORIGIN_OK ;;
    *) echo "" ;;
  esac
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

# --- layout ---
require_file "$CONTRACT"
require_file "$RUNBOOK"
require_file "$DEV_FIX"
require_file "$DIST_FIX"

# --- in-repo signing contract must stay green ---
if [[ "$SKIP_CONTRACT" -eq 0 ]]; then
  if bash "$CONTRACT" >/tmp/casein-companion-contract-$$.log 2>&1; then
    pass "in-repo signing contract green"
  else
    fail "in-repo signing contract failed (see scripts/verify-companion-signing-contract.sh)"
    cat /tmp/casein-companion-contract-$$.log >&2 || true
  fi
  rm -f /tmp/casein-companion-contract-$$.log
else
  pass "skipped in-repo signing contract (--skip-contract)"
fi

# --- fixtures stay obviously fake (never real profiles) ---
require_grep "$DEV_FIX" 'Sanitized contract|Obviously fake|FAKE|Not a real' \
  "development fixture labeled non-secret"
require_grep "$DIST_FIX" 'Obviously fake|FAKE iOS|Not a real' \
  "distribution fixture labeled fake"
require_grep "$DEV_FIX" '<string>development</string>' \
  "development fixture aps-environment=development"
require_grep "$DIST_FIX" '<string>production</string>' \
  "distribution fixture aps-environment=production"
require_grep "$DEV_FIX" '<key>get-task-allow</key>' \
  "development fixture keeps get-task-allow"
forbid_grep "$DIST_FIX" '<key>get-task-allow</key>' \
  "distribution fixture omits get-task-allow"
forbid_grep "$DEV_FIX" 'BEGIN (CERTIFICATE|PRIVATE KEY)|-----BEGIN' \
  "development fixture has no PEM"
forbid_grep "$DIST_FIX" 'BEGIN (CERTIFICATE|PRIVATE KEY)|-----BEGIN' \
  "distribution fixture has no PEM"

printf 'fixture development=%s\n' "${DEV_FIX#"$ROOT"/}"
printf 'fixture distribution=%s\n' "${DIST_FIX#"$ROOT"/}"
printf 'runbook=%s\n' "${RUNBOOK#"$ROOT"/}"

# --- structured external checklist ---
printf '\n=== external prereq checklist (#416) ===\n'
printf 'mode=%s\n' "$([[ "$DRY_RUN" -eq 1 ]] && echo dry-run || echo enforce)"

for entry in "${NEED_CATALOG[@]}"; do
  code="${entry%%|*}"
  desc="${entry#*|}"
  env_name="$(need_env_for "$code")"
  # Indirect env presence check without printing values.
  if [[ -n "$env_name" && -n "${!env_name:-}" ]]; then
    satisfied+=("$code")
    pass "marker set: $code (via $env_name)"
  else
    need "$code" "$desc"
  fi
done

status=0
if ((${#failures[@]} > 0)); then
  status=1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\n%d fixture/contract checks; %d NEED codes listed (dry-run — exit 0 if contract/fixtures ok)\n' \
    "$checks" "${#needs[@]}"
  if ((${#failures[@]} > 0)); then
    printf '%d/%d checks failed:\n' "${#failures[@]}" "$checks" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    status=1
  else
    status=0
  fi
else
  if ((${#needs[@]} > 0)); then
    status=1
    printf '\n%d NEED code(s) unresolved (set CASEIN_COMPANION_* markers on operator Mac after real material exists; never commit secrets)\n' \
      "${#needs[@]}" >&2
  fi
  if ((${#failures[@]} > 0)); then
    printf '%d/%d checks failed:\n' "${#failures[@]}" "$checks" >&2
    printf '  - %s\n' "${failures[@]}" >&2
  fi
  if [[ "$status" -eq 0 ]]; then
    printf '\n%d checks + all external markers present (still does not prove physical install from this box alone)\n' \
      "$checks"
  fi
fi

if [[ -n "$JSON_OUT" ]]; then
  fail_tmp="$(mktemp)"
  need_tmp="$(mktemp)"
  sat_tmp="$(mktemp)"
  printf '%s\n' "${failures[@]+"${failures[@]}"}" >"$fail_tmp"
  printf '%s\n' "${needs[@]+"${needs[@]}"}" >"$need_tmp"
  printf '%s\n' "${satisfied[@]+"${satisfied[@]}"}" >"$sat_tmp"

  python3 - <<'PY' "$JSON_OUT" "$status" "$checks" "$DRY_RUN" "$fail_tmp" "$need_tmp" "$sat_tmp"
import json, sys
from pathlib import Path

out, status, checks, dry_flag = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
fail_path, need_path, sat_path = sys.argv[5], sys.argv[6], sys.argv[7]

def lines(path: str) -> list[str]:
    text = Path(path).read_text(encoding="utf-8")
    return [ln for ln in text.splitlines() if ln != ""]

payload = {
    "schema": 1,
    "kind": "companion_external_prereqs",
    "issue": 416,
    "mode": "dry-run" if dry_flag == "1" else "enforce",
    "passed": status == 0,
    "checks": checks,
    "failures": lines(fail_path),
    "need_codes": lines(need_path),
    "satisfied_codes": lines(sat_path),
    "catalog": [
        "APPLE_AGREEMENT",
        "IOS_DEV_PROFILE",
        "IOS_PHYSICAL_INSTALL",
        "ANDROID_STORAGE_INSTALL",
        "PLAY_PUBLIC_NAME",
        "ASC_PUBLIC_NAME",
        "NOTARYTOOL_KEYCHAIN",
        "APNS_FCM_DELIVERY",
        "CROSS_ORIGIN_PAIR",
    ],
    "fixtures": {
        "development": "native/casein_mob/test/fixtures/ios_development_profile.plist",
        "distribution": "native/casein_mob/test/fixtures/ios_distribution_profile.plist",
    },
    "claims": {
        "in_repo_contract": True,
        "fixtures_obviously_fake": True,
        "physical_device_install": False,
        "real_signing_material": False,
    },
    "note": (
        "Dry-run exits 0 when contract+fixtures are green and NEED codes are listed only. "
        "Enforce mode requires CASEIN_COMPANION_* env markers set on an operator machine. "
        "Markers never contain secret values in tickets; this script only checks presence."
    ),
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
  rm -f "$fail_tmp" "$need_tmp" "$sat_tmp"
  printf 'wrote %s\n' "$JSON_OUT"
fi

exit "$status"
