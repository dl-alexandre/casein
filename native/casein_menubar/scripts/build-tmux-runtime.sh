#!/usr/bin/env bash
# Build and stage the pinned tmux runtime embedded in the macOS desktop app.
set -euo pipefail

cd "$(dirname "$0")/../../.."

TMUX_VERSION="3.7b"
TMUX_SHA256="87f2e99e3b685973f2ca002ffd6ed7e51a5744f7009daae5a15670b6d532db96"
TMUX_URL="https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
LIBEVENT_VERSION="2.1.13-stable"
LIBEVENT_SHA256="f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"
UTF8PROC_VERSION="2.11.3"
UTF8PROC_SHA256="415189fd2c85cd6ee5ff26af500fa387de9ada1e3e316e93f7338551481d557d"
UTF8PROC_URL="https://github.com/JuliaStrings/utf8proc/releases/download/v${UTF8PROC_VERSION}/utf8proc-${UTF8PROC_VERSION}.tar.gz"
OUTPUT_DIR="${1:-native/casein_menubar/build/tmux-runtime}"
mkdir -p native/casein_menubar/build
build_root="$(cd native/casein_menubar/build && pwd -P)"
case "/$OUTPUT_DIR/" in
  */../*|*/./*) echo "tmux output may not contain dot traversal" >&2; exit 1 ;;
esac
case "$OUTPUT_DIR" in
  "$build_root"/*) ;;
  native/casein_menubar/build/*) OUTPUT_DIR="$(pwd)/$OUTPUT_DIR" ;;
  *) echo "tmux output must be a direct child of $build_root" >&2; exit 1 ;;
esac
output_parent="$(cd "$(dirname "$OUTPUT_DIR")" && pwd -P)"
[[ "$output_parent" == "$build_root" ]] || {
  echo "tmux output must be a direct child of $build_root" >&2
  exit 1
}
OUTPUT_DIR="$output_parent/$(basename "$OUTPUT_DIR")"
[[ "$OUTPUT_DIR" != "$build_root" ]] || { echo "tmux output may not replace the build root" >&2; exit 1; }
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/casein-tmux.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ "$(uname -s)" == "Darwin" ]] || { echo "tmux runtime builds require macOS" >&2; exit 1; }

download_verified() {
  local url="$1" expected="$2" destination="$3"
  curl --fail --location --silent --show-error "$url" --output "$destination"
  local actual
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "source checksum mismatch for $url: expected $expected, got $actual" >&2
    exit 1
  }
}

archive="$WORK_DIR/tmux.tar.gz"
libevent_archive="$WORK_DIR/libevent.tar.gz"
utf8proc_archive="$WORK_DIR/utf8proc.tar.gz"
download_verified "$TMUX_URL" "$TMUX_SHA256" "$archive"
download_verified "$LIBEVENT_URL" "$LIBEVENT_SHA256" "$libevent_archive"
download_verified "$UTF8PROC_URL" "$UTF8PROC_SHA256" "$utf8proc_archive"

tar -xzf "$archive" -C "$WORK_DIR"
tar -xzf "$libevent_archive" -C "$WORK_DIR"
tar -xzf "$utf8proc_archive" -C "$WORK_DIR"
source_dir="$WORK_DIR/tmux-${TMUX_VERSION}"
libevent_source="$WORK_DIR/libevent-${LIBEVENT_VERSION}"
utf8proc_source="$WORK_DIR/utf8proc-${UTF8PROC_VERSION}"
dependency_prefix="$WORK_DIR/dependencies"

(
  cd "$libevent_source"
  ./configure --prefix="$dependency_prefix" --disable-shared --enable-static \
    --disable-openssl --disable-libevent-regress --disable-samples --disable-tests
  make -j"$(sysctl -n hw.logicalcpu)"
  make install
)

(
  cd "$utf8proc_source"
  make -j"$(sysctl -n hw.logicalcpu)" libutf8proc.a
  mkdir -p "$dependency_prefix/include" "$dependency_prefix/lib"
  cp utf8proc.h "$dependency_prefix/include/"
  cp libutf8proc.a "$dependency_prefix/lib/"
)

(
  cd "$source_dir"
  CPPFLAGS="-I$dependency_prefix/include" \
  LDFLAGS="-L$dependency_prefix/lib" \
  LIBEVENT_CFLAGS="-I$dependency_prefix/include" \
  LIBEVENT_LIBS="$dependency_prefix/lib/libevent_core.a" \
  LIBUTF8PROC_CFLAGS="-I$dependency_prefix/include" \
  LIBUTF8PROC_LIBS="$dependency_prefix/lib/libutf8proc.a" \
    ./configure --enable-utf8proc
  make -j"$(sysctl -n hw.logicalcpu)"
)

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/licenses"
cp "$source_dir/tmux" "$OUTPUT_DIR/bin/tmux"
chmod 0755 "$OUTPUT_DIR/bin/tmux"
cp "$source_dir/COPYING" "$OUTPUT_DIR/licenses/tmux-ISC.txt"
cp "$libevent_source/LICENSE" "$OUTPUT_DIR/licenses/libevent-BSD-3-Clause.txt"
cp "$utf8proc_source/LICENSE.md" "$OUTPUT_DIR/licenses/utf8proc-MIT.txt"

if otool -L "$OUTPUT_DIR/bin/tmux" | rg '/opt/homebrew|/usr/local'; then
  echo "bundled tmux still references a Homebrew path" >&2
  exit 1
fi

"$OUTPUT_DIR/bin/tmux" -V | rg -x "tmux ${TMUX_VERSION}"
echo "Built pinned tmux runtime at $OUTPUT_DIR"
