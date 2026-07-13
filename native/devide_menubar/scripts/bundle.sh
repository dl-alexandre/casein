#!/usr/bin/env bash
# Assemble "DevIDE MenuBar.app" from the SPM build. SPM executables have no
# bundle of their own, and LSUIElement + ATS keys only apply from a real
# .app's Info.plist.
#
# The ad-hoc codesign at the end matters: unsigned or stale-signed binaries
# get SIGKILLed on Apple silicon (the tailwind/Bun lesson — see
# docs/desktop/platform_architecture.md "Packaging rule").
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP="build/DevIDE MenuBar.app"

# /usr/bin/swift dispatches through xcrun to the xcode-select'd toolchain,
# sidestepping broken package-manager Swift shims earlier on PATH.
SWIFT="${SWIFT:-/usr/bin/swift}"

"$SWIFT" build -c "$CONFIGURATION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIGURATION/DevIDEMenuBar" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\""
