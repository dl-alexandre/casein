#!/usr/bin/env bash
# Build a self-contained, signed macOS DevIDE application archive.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS packaging requires Darwin" >&2; exit 1; }

architecture="$(uname -m)"
revision="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  if [[ "${DEVIDE_ALLOW_DIRTY_PACKAGE:-0}" != "1" ]]; then
    echo "Refusing to package a dirty source tree. Commit the release or set DEVIDE_ALLOW_DIRTY_PACKAGE=1 for a local-only build." >&2
    exit 1
  fi
  revision="${revision}-dirty"
fi
if command -v mise >/dev/null 2>&1; then
  MIX=(mise exec node@22 -- mix)
else
  MIX=(mix)
fi
version="$("${MIX[@]}" run --no-start -e 'IO.write(Mix.Project.config()[:version])')"
build_number="${DEVIDE_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
release_root="$(pwd)/_build/prod/rel/dev_ide"
tmux_runtime="$(pwd)/native/devide_menubar/build/tmux-runtime"
artifact_dir="$(pwd)/native/devide_menubar/build/artifacts"
case "$architecture" in
  arm64) release_target="darwin-aarch64" ;;
  x86_64) release_target="darwin-x86_64" ;;
  *) echo "unsupported macOS architecture: $architecture" >&2; exit 1 ;;
esac

bash native/devide_menubar/scripts/build-tmux-runtime.sh "$tmux_runtime"
MIX_ENV=prod CASEIN_REPO_ADAPTER=sqlite DEVIDE_RELEASE_PROFILE=desktop \
  DEVIDE_RELEASE_TARGET="$release_target" "${MIX[@]}" dev_ide.release.lan

app_priv="$(find "$release_root/lib" -maxdepth 2 -type d -path '*/dev_ide-*/priv' -print -quit)"
[[ -n "$app_priv" ]] || { echo "assembled release has no DevIDE priv directory" >&2; exit 1; }
mkdir -p "$app_priv/bin" "$app_priv/lib" "$app_priv/licenses"
ditto "$tmux_runtime/bin" "$app_priv/bin"
ditto "$tmux_runtime/lib" "$app_priv/lib"
ditto "$tmux_runtime/licenses" "$app_priv/licenses"

(
  cd native/devide_menubar
  DEVIDE_RELEASE_ROOT="$release_root" \
  DEVIDE_BUNDLE_VERSION="$version" \
  DEVIDE_BUILD_NUMBER="$build_number" \
  DEVIDE_CODESIGN_IDENTITY="${DEVIDE_CODESIGN_IDENTITY:--}" \
    ./scripts/bundle.sh release
)

mkdir -p "$artifact_dir"
artifact_base="DevIDE-${version}-macos-${architecture}"
archive="$artifact_dir/$artifact_base.zip"
rm -f "$archive" "$archive.sha256" "$artifact_dir/$artifact_base.manifest.plist"
ditto -c -k --sequesterRsrc --keepParent \
  "native/devide_menubar/build/DevIDE MenuBar.app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

manifest="$artifact_dir/$artifact_base.manifest.plist"
plutil -create xml1 "$manifest"
plutil -insert version -string "$version" "$manifest"
plutil -insert build -string "$build_number" "$manifest"
plutil -insert revision -string "$revision" "$manifest"
plutil -insert architecture -string "$architecture" "$manifest"
plutil -insert tmux -string "3.7b" "$manifest"
plutil -insert sha256 -string "$(awk '{print $1}' "$archive.sha256")" "$manifest"

echo "Packaged $archive"
