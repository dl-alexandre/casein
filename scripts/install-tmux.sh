#!/usr/bin/env bash
#
# Build and install a pinned tmux from source. Idempotent: if the target
# prefix already has the requested version, it does nothing.
#
# Used in two places:
#   * CI runners (deploy-devbox.yml / pty-tests.yml) so the :pty suite runs
#     against the same tmux the devbox will run — set TMUX_PREFIX to a
#     cacheable, user-writable dir and TMUX_INSTALL_SUDO="".
#   * The devbox host during the 3.6b cutover window — default prefix
#     /usr/local so the binary precedes the apt tmux in /usr/bin.
#
# Env:
#   TMUX_VERSION       tmux release tag to build (default 3.6b)
#   TMUX_PREFIX        install prefix (default /usr/local)
#   TMUX_INSTALL_SUDO  sudo command for the privileged `make install` step
#                      (default "sudo"; set to "" when PREFIX is user-writable).
#                      Package installation with apt-get always needs root and
#                      escalates on its own (sudo unless already root),
#                      independent of this setting.
set -euo pipefail

TMUX_VERSION="${TMUX_VERSION:-3.6b}"
PREFIX="${TMUX_PREFIX:-/usr/local}"
SUDO="${TMUX_INSTALL_SUDO-sudo}"

# tmux reports "3.6b" from `tmux -V`; the version-detection code parses the
# leading MAJOR.MINOR, so "3.6b" and "3.6" are equivalent for capability gating.
existing=""
if [[ -x "${PREFIX}/bin/tmux" ]]; then
  existing="$("${PREFIX}/bin/tmux" -V 2>/dev/null || true)"
fi

if [[ "${existing}" == "tmux ${TMUX_VERSION}" ]]; then
  echo "tmux ${TMUX_VERSION} already installed at ${PREFIX}/bin/tmux"
  exit 0
fi

echo "Building tmux ${TMUX_VERSION} -> ${PREFIX} (found: ${existing:-none})"

# apt-get needs root regardless of where tmux ends up, so it does not follow
# TMUX_INSTALL_SUDO (which may be "" for a user-writable PREFIX, e.g. on CI
# runners). Escalate with sudo unless we are already running as root.
apt_sudo=""
if [[ "$(id -u)" -ne 0 ]]; then
  apt_sudo="sudo"
fi
${apt_sudo} apt-get update -q
${apt_sudo} apt-get install -y -q build-essential libevent-dev libncurses-dev bison pkg-config curl

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

tarball="tmux-${TMUX_VERSION}.tar.gz"
url="https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/${tarball}"
curl -fsSL "${url}" -o "${work}/${tarball}"
tar -xzf "${work}/${tarball}" -C "${work}"

pushd "${work}/tmux-${TMUX_VERSION}" >/dev/null
./configure --prefix="${PREFIX}"
make -j"$(nproc)"
${SUDO} make install
popd >/dev/null

hash -r 2>/dev/null || true
"${PREFIX}/bin/tmux" -V
