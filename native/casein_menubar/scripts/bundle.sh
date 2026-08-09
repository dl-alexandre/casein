#!/usr/bin/env bash
# Assemble "Casein MenuBar.app" from the SPM build. SPM executables have no
# bundle of their own, and LSUIElement + ATS keys only apply from a real
# .app's Info.plist.
#
# The ad-hoc codesign at the end matters: unsigned or stale-signed binaries
# get SIGKILLed on Apple silicon (the tailwind/Bun lesson — see
# docs/desktop/platform_architecture.md "Packaging rule").
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP="build/Casein MenuBar.app"

# /usr/bin/swift dispatches through xcrun to the xcode-select'd toolchain,
# sidestepping broken package-manager Swift shims earlier on PATH.
SWIFT="${SWIFT:-/usr/bin/swift}"

"$SWIFT" build -c "$CONFIGURATION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIGURATION/casein-menubar" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

if [[ -n "${CASEIN_RELEASE_ROOT:-}" ]]; then
  [[ -x "$CASEIN_RELEASE_ROOT/bin/casein" ]] || {
    echo "CASEIN_RELEASE_ROOT is not an assembled Casein release" >&2
    exit 1
  }
  mkdir -p "$APP/Contents/Resources"
  # A previously-run release can leave FIFOs and sockets under tmp/. Copying a
  # FIFO with ditto blocks forever and runtime artifacts must never ship in the
  # app bundle. rsync the durable release tree and recreate an empty tmp dir.
  mkdir -p "$APP/Contents/Resources/release"
  /usr/bin/rsync -a --exclude '/tmp/***' \
    "$CASEIN_RELEASE_ROOT/" "$APP/Contents/Resources/release/"
  mkdir -p "$APP/Contents/Resources/release/tmp"
fi

if [[ -n "${CASEIN_BUNDLE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CASEIN_BUNDLE_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${CASEIN_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CASEIN_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Sign every nested Mach-O before sealing the outer app. OTP releases include
# ERTS executables, port programs, NIFs, and the bundled tmux runtime.
#
# Ad-hoc identity "-" is the local/CI smoke default. A real Developer ID
# Application identity enables hardened runtime + entitlements required for
# notarization (issue #382). Never commit a certificate or Team credential.
identity="${CASEIN_CODESIGN_IDENTITY:--}"
entitlements="${CASEIN_CODESIGN_ENTITLEMENTS:-Resources/Casein.entitlements}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  if [[ ! -f "$entitlements" ]]; then
    echo "Developer ID signing requires entitlements at $entitlements" >&2
    exit 1
  fi
  sign_args+=(--options runtime --timestamp --entitlements "$entitlements")
fi

while IFS= read -r -d '' candidate; do
  if file "$candidate" | rg -q 'Mach-O'; then
    codesign "${sign_args[@]}" "$candidate"
  fi
done < <(find "$APP/Contents" -type f -print0)

codesign "${sign_args[@]}" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$identity" != "-" ]]; then
  detail="$(codesign -dvvv "$APP" 2>&1 || true)"
  if ! printf '%s\n' "$detail" | grep -q 'Authority=Developer ID Application:'; then
    echo "CASEIN_CODESIGN_IDENTITY did not produce a Developer ID Application signature" >&2
    exit 1
  fi
  if ! printf '%s\n' "$detail" | grep -q '(runtime)'; then
    echo "Developer ID signature is missing the hardened-runtime flag" >&2
    exit 1
  fi
fi

echo "Built $APP (identity=${identity})"
echo "Run with: open \"$APP\""
