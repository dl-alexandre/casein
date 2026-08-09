#!/usr/bin/env bash
# Submit a packaged macOS desktop archive for Apple notarization and staple it.
#
# Credentials (one of):
#   CASEIN_NOTARY_KEYCHAIN_PROFILE   notarytool keychain profile name
#   CASEIN_NOTARY_APPLE_ID + CASEIN_NOTARY_TEAM_ID + CASEIN_NOTARY_APP_PASSWORD
#   CASEIN_NOTARY_API_KEY + CASEIN_NOTARY_API_KEY_ID + CASEIN_NOTARY_API_ISSUER
#
# Never pass real credentials on the command line in shared logs. Prefer a
# keychain profile created once on the release Mac:
#   xcrun notarytool store-credentials casein-notary --apple-id ... --team-id ...
#
# Dry-run (no network, no credentials):
#   CASEIN_NOTARY_DRY_RUN=1 scripts/notarize-macos-desktop.sh path/to.zip
#
# SECRETS RULE: this repository must never contain a real certificate, Team ID
# credential, app-specific password, or App Store Connect API key. Tests use
# obviously fake fixtures only.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

archive=""
wait_for_result=1
staple=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait) wait_for_result=0; shift ;;
    --no-staple) staple=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$archive" ]]; then
        echo "unexpected argument: $1" >&2
        exit 1
      fi
      archive="$1"
      shift
      ;;
  esac
done

if [[ -z "$archive" ]]; then
  shopt -s nullglob
  candidates=(native/casein_menubar/build/artifacts/Casein-*-macos-*.zip)
  shopt -u nullglob
  if [[ ${#candidates[@]} -eq 1 ]]; then
    archive="${candidates[0]}"
  elif [[ "${CASEIN_NOTARY_DRY_RUN:-0}" == "1" ]]; then
    archive="native/casein_menubar/build/artifacts/Casein-DRYRUN-macos-arm64.zip"
  else
    echo "usage: $0 <Casein-*-macos-*.zip>" >&2
    exit 1
  fi
fi

if [[ "${CASEIN_NOTARY_DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN: would notarize $archive"
  echo "DRY RUN: credentials source would be resolved from CASEIN_NOTARY_* env"
  echo "DRY RUN: wait=$wait_for_result staple=$staple"
  echo "DRY RUN: notarytool submit … --wait; stapler staple <app-or-archive>"
  exit 0
fi

[[ -f "$archive" ]] || { echo "archive not found: $archive" >&2; exit 1; }
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "notarization requires Darwin + Xcode CLT (notarytool/stapler)" >&2
  exit 2
}

command -v xcrun >/dev/null 2>&1 || {
  echo "xcrun is required for notarytool/stapler" >&2
  exit 2
}

auth_args=()
if [[ -n "${CASEIN_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  auth_args=(--keychain-profile "$CASEIN_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${CASEIN_NOTARY_API_KEY:-}" && -n "${CASEIN_NOTARY_API_KEY_ID:-}" && -n "${CASEIN_NOTARY_API_ISSUER:-}" ]]; then
  auth_args=(
    --key "$CASEIN_NOTARY_API_KEY"
    --key-id "$CASEIN_NOTARY_API_KEY_ID"
    --issuer "$CASEIN_NOTARY_API_ISSUER"
  )
elif [[ -n "${CASEIN_NOTARY_APPLE_ID:-}" && -n "${CASEIN_NOTARY_TEAM_ID:-}" && -n "${CASEIN_NOTARY_APP_PASSWORD:-}" ]]; then
  auth_args=(
    --apple-id "$CASEIN_NOTARY_APPLE_ID"
    --team-id "$CASEIN_NOTARY_TEAM_ID"
    --password "$CASEIN_NOTARY_APP_PASSWORD"
  )
else
  cat >&2 <<'EOF'
No notarization credentials configured.

Set one of:
  CASEIN_NOTARY_KEYCHAIN_PROFILE
  CASEIN_NOTARY_API_KEY + CASEIN_NOTARY_API_KEY_ID + CASEIN_NOTARY_API_ISSUER
  CASEIN_NOTARY_APPLE_ID + CASEIN_NOTARY_TEAM_ID + CASEIN_NOTARY_APP_PASSWORD

Or dry-run the contract with CASEIN_NOTARY_DRY_RUN=1.
EOF
  exit 1
fi

submit_args=(notarytool submit "$archive")
submit_args+=("${auth_args[@]}")
if [[ "$wait_for_result" -eq 1 ]]; then
  submit_args+=(--wait)
fi

echo ">>> xcrun notarytool submit $(basename "$archive")"
# Do not echo auth_args — they may carry secret material via env expansion paths.
xcrun "${submit_args[@]}"

if [[ "$staple" -eq 1 ]]; then
  echo ">>> xcrun stapler staple $(basename "$archive")"
  xcrun stapler staple "$archive"
  xcrun stapler validate "$archive"
fi

echo "Notarization complete for $archive"
