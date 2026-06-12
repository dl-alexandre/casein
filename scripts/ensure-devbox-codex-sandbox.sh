#!/usr/bin/env bash
#
# Ensure Codex's Linux sandbox (bubblewrap) can create user namespaces.
# Ubuntu 24.04+ enables AppArmor unprivileged userns restriction by default;
# without a bwrap AppArmor profile, Codex falls back to a bundled helper that
# also needs userns and tool runs can hang or fail.
#
# Usage:
#   bash scripts/ensure-devbox-codex-sandbox.sh
#
set -euo pipefail

bwrap_canary() {
  command -v bwrap >/dev/null 2>&1 &&
    bwrap --dev-bind / / --unshare-net echo ok >/dev/null 2>&1
}

if bwrap_canary; then
  echo "Codex sandbox prerequisites OK (bubblewrap user namespaces work)"
  exit 0
fi

if ! command -v bwrap >/dev/null 2>&1; then
  echo "error: bubblewrap not installed — run: sudo apt install bubblewrap" >&2
  exit 1
fi

restrict="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [[ "$restrict" != "1" ]]; then
  echo "error: bubblewrap canary failed but kernel.apparmor_restrict_unprivileged_userns is not 1" >&2
  echo "hint: run 'bwrap --dev-bind / / --unshare-net echo ok' and inspect the error" >&2
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  echo "error: bubblewrap cannot create user namespaces (AppArmor userns restriction)" >&2
  echo "hint: re-run with sudo available, or ask the host admin to load a bwrap AppArmor profile" >&2
  exit 1
fi

sudo apt-get install -y bubblewrap apparmor-utils apparmor-profiles >/dev/null

EXTRA="/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"
if [[ -f "$EXTRA" ]]; then
  sudo install -m 0644 "$EXTRA" /etc/apparmor.d/bwrap-userns-restrict
  sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
else
  sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
  sudo apparmor_parser -r /etc/apparmor.d/bwrap
fi

if bwrap_canary; then
  echo "Codex sandbox prerequisites fixed (bubblewrap user namespaces now work)"
  exit 0
fi

echo "error: bubblewrap still failing after AppArmor profile install" >&2
echo "hint: see AGENTS.md friction table (Codex sandbox / bubblewrap)" >&2
exit 1