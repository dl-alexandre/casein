#!/usr/bin/env bash
# Enable core dumps for the host-built tmux binary so future segfaults leave
# a useful artifact under /var/crash or cwd. Safe to re-run.
set -euo pipefail

echo "Current core pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo unknown)"
echo "ulimit -c (this shell): $(ulimit -c)"

# Prefer apport pattern if present; otherwise pipe to a fixed dir.
if [[ -d /var/crash ]]; then
  echo "Apport crash dir present: /var/crash"
  ls -lt /var/crash/*tmux* 2>/dev/null | head -5 || echo "(no prior tmux crash reports)"
fi

# Ensure systemd services (including devide-tmux) can dump cores.
if [[ -f /etc/systemd/system/devide-tmux.service ]]; then
  if ! grep -q 'LimitCORE=infinity' /etc/systemd/system/devide-tmux.service; then
    echo "warn: devide-tmux.service missing LimitCORE=infinity; re-run ensure-devide-tmux.sh"
  fi
fi

# Soft note: unpackaged /usr/local/bin/tmux is ignored by apport by default.
# For a one-shot capture under a shell:
cat <<'EOF'

To capture a live core from a manual repro:
  ulimit -c unlimited
  TMUX=/usr/local/bin/tmux
  $TMUX -L coretest kill-server 2>/dev/null || true
  # then run the failing attach/resize sequence under gdb:
  #   gdb --args $TMUX -L coretest …
  #   run
  #   bt full

EOF
