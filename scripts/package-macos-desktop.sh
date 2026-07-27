#!/usr/bin/env bash
# Build a self-contained, signed macOS Casein application archive.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS packaging requires Darwin" >&2; exit 1; }

architecture="$(uname -m)"
revision="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  if [[ "${CASEIN_ALLOW_DIRTY_PACKAGE:-0}" != "1" ]]; then
    echo "Refusing to package a dirty source tree. Commit the release or set CASEIN_ALLOW_DIRTY_PACKAGE=1 for a local-only build." >&2
    exit 1
  fi
  revision="${revision}-dirty"
fi
if command -v mise >/dev/null 2>&1; then
  MIX=(mise exec node@22 -- mix)
else
  MIX=(mix)
fi
version_output="$("${MIX[@]}" run --no-start -e \
  'IO.puts("CASEIN_PROJECT_VERSION=" <> Mix.Project.config()[:version])')"
printf '%s\n' "$version_output" >&2
version="$(printf '%s\n' "$version_output" |
  sed -n 's/^CASEIN_PROJECT_VERSION=//p')"
if [[ -z "$version" || "$version" == *$'\n'* ]]; then
  echo "could not determine one Casein project version" >&2
  exit 1
fi
build_number="${CASEIN_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
release_root="$(pwd)/_build/prod/rel/casein"
tmux_runtime="$(pwd)/native/casein_menubar/build/tmux-runtime"
artifact_dir="$(pwd)/native/casein_menubar/build/artifacts"
case "$architecture" in
  arm64) release_target="darwin-aarch64" ;;
  x86_64) release_target="darwin-x86_64" ;;
  *) echo "unsupported macOS architecture: $architecture" >&2; exit 1 ;;
esac

bash native/casein_menubar/scripts/build-tmux-runtime.sh "$tmux_runtime"
MIX_ENV=prod CASEIN_REPO_ADAPTER=sqlite CASEIN_RELEASE_PROFILE=desktop \
  CASEIN_RELEASE_TARGET="$release_target" "${MIX[@]}" casein.release.lan

app_priv="$(find "$release_root/lib" -maxdepth 2 -type d -path '*/casein-*/priv' -print -quit)"
[[ -n "$app_priv" ]] || { echo "assembled release has no Casein priv directory" >&2; exit 1; }
mkdir -p "$app_priv/bin" "$app_priv/lib" "$app_priv/licenses"
ditto "$tmux_runtime/bin" "$app_priv/bin"
ditto "$tmux_runtime/lib" "$app_priv/lib"
ditto "$tmux_runtime/licenses" "$app_priv/licenses"

(
  cd native/casein_menubar
  CASEIN_RELEASE_ROOT="$release_root" \
  CASEIN_BUNDLE_VERSION="$version" \
  CASEIN_BUILD_NUMBER="$build_number" \
  CASEIN_CODESIGN_IDENTITY="${CASEIN_CODESIGN_IDENTITY:--}" \
    ./scripts/bundle.sh release
)

mkdir -p "$artifact_dir"
artifact_base="Casein-${version}-macos-${architecture}"
archive="$artifact_dir/$artifact_base.zip"
rm -f "$archive" "$archive.sha256" "$artifact_dir/$artifact_base.manifest.plist"
ditto -c -k --sequesterRsrc --keepParent \
  "native/casein_menubar/build/Casein MenuBar.app" "$archive"
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
