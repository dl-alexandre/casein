#!/usr/bin/env bash
# Verify a packaged macOS desktop app's signatures and (when present) notarization.
#
# Usage:
#   scripts/verify-macos-desktop-release.sh [path/to/Casein MenuBar.app]
#   scripts/verify-macos-desktop-release.sh --require-developer-id [app]
#   scripts/verify-macos-desktop-release.sh --require-notarized [app]
#
# Exit codes:
#   0  all requested checks passed
#   1  verification failed
#   2  wrong host OS / missing tooling
set -euo pipefail

cd "$(dirname "$0")/.."

require_developer_id=0
require_notarized=0
require_hardened_runtime=0
app=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-developer-id) require_developer_id=1; shift ;;
    --require-notarized) require_notarized=1; shift ;;
    --require-hardened-runtime) require_hardened_runtime=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$app" ]]; then
        echo "unexpected argument: $1" >&2
        exit 1
      fi
      app="$1"
      shift
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "macOS release verification requires Darwin" >&2
  exit 2
}

for tool in codesign spctl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 2
  }
done

APP="${app:-native/casein_menubar/build/Casein MenuBar.app}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[[ -d "$APP" ]] || { echo "app bundle not found: $APP" >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/casein-menubar" ]] || {
  echo "app is missing its executable: $APP/Contents/MacOS/casein-menubar" >&2
  exit 1
}

echo ">>> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ">>> codesign every nested Mach-O"
find "$APP/Contents" -type f -print0 | while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    codesign --verify --strict "$candidate"
  fi
done

authority_lines="$(codesign -dvvv "$APP" 2>&1 || true)"
printf '%s\n' "$authority_lines" | sed -n '1,40p'

if [[ "$require_developer_id" -eq 1 ]]; then
  if ! printf '%s\n' "$authority_lines" | grep -q 'Authority=Developer ID Application:'; then
    echo "expected Developer ID Application signer; ad-hoc or other identity is not release evidence" >&2
    exit 1
  fi
  if printf '%s\n' "$authority_lines" | grep -q 'Signature=adhoc'; then
    echo "ad-hoc signature is not release evidence" >&2
    exit 1
  fi
fi

if [[ "$require_hardened_runtime" -eq 1 || "$require_developer_id" -eq 1 ]]; then
  if ! printf '%s\n' "$authority_lines" | grep -Eq 'flags=0x[0-9a-fA-F]*\([^\)]*runtime'; then
    # codesign prints either "flags=0x10000(runtime)" or "CodeDirectory ... flags=0x10000(runtime)"
    if ! printf '%s\n' "$authority_lines" | grep -q '(runtime)'; then
      echo "hardened runtime flag is missing from the sealed app" >&2
      exit 1
    fi
  fi
fi

team_id="$(printf '%s\n' "$authority_lines" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ "$require_developer_id" -eq 1 ]]; then
  if [[ -z "$team_id" || "$team_id" == "not set" ]]; then
    echo "Developer ID signature is missing TeamIdentifier" >&2
    exit 1
  fi
fi

echo ">>> spctl --assess --type execute"
spctl_status=0
spctl_output="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" || spctl_status=$?
printf '%s\n' "$spctl_output"
if [[ "$require_notarized" -eq 1 && "$spctl_status" -ne 0 ]]; then
  echo "Gatekeeper assessment failed while notarization was required" >&2
  exit 1
fi

if command -v xcrun >/dev/null 2>&1; then
  echo ">>> stapler validate (best-effort unless --require-notarized)"
  staple_status=0
  xcrun stapler validate "$APP" 2>&1 || staple_status=$?
  if [[ "$require_notarized" -eq 1 && "$staple_status" -ne 0 ]]; then
    echo "stapler validate failed while notarization was required" >&2
    exit 1
  fi
elif [[ "$require_notarized" -eq 1 ]]; then
  echo "xcrun/stapler is required for --require-notarized" >&2
  exit 2
fi

echo "macOS desktop release verification passed for $APP"
