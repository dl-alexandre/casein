# Shared host lock for any self-hosted *devbox* job that mutates
# _build/deps under the Actions workdir (PR gate, preview-e2e, etc.).
#
# Why: clean:false persists native/casein_mob/_build. Concurrent mix/zigler
# compiles on the same tree can drop zigler priv/beam (sema.zig FileNotFound)
# mid-gate. One flock per host serializes heavy Mix work without GitHub
# canceling other PRs' queued runs (see pr-gate concurrency note).
#
# Usage (from a workflow step, after PATH has util-linux flock):
#   # shellcheck source=scripts/lib/casein-devbox-mix-lock.sh
#   source scripts/lib/casein-devbox-mix-lock.sh
#   casein_devbox_mix_lock_acquire   # holds fd 9 until the step ends
#   casein_devbox_heal_zigler_priv   # optional, after lock
#
# Multi-runner note: flock is *per host*. N runners on N Linux boxes with
# label `devbox` run in parallel. N runner processes on one box still serialize
# here (correct). macOS runners (milcmini/testserver) do not match
# runs-on: [self-hosted, devbox] and are not PR-gate capacity.

CASEIN_DEVBOX_MIX_LOCK="${CASEIN_DEVBOX_MIX_LOCK:-/tmp/casein-pr-gate.lock}"
CASEIN_DEVBOX_MIX_LOCK_WAIT_SEC="${CASEIN_DEVBOX_MIX_LOCK_WAIT_SEC:-2700}"

casein_devbox_mix_lock_acquire() {
  command -v flock >/dev/null || {
    echo "::error::flock (util-linux) required on runner"
    return 1
  }
  echo "Acquiring host Mix lock ${CASEIN_DEVBOX_MIX_LOCK} (wait up to ${CASEIN_DEVBOX_MIX_LOCK_WAIT_SEC}s)…"
  exec 9>"${CASEIN_DEVBOX_MIX_LOCK}"
  if ! flock -w "${CASEIN_DEVBOX_MIX_LOCK_WAIT_SEC}" 9; then
    echo "::error::Timed out waiting for ${CASEIN_DEVBOX_MIX_LOCK}. Another Mix/gate job holds the box."
    return 1
  fi
  echo "Host Mix lock acquired."
}

# If a prior cancelled/raced job left zigler's priv tree incomplete, wipe the
# package build dirs so the next compile reinstalls beam/sema.zig cleanly.
# Only removes *incomplete* trees (sema.zig missing while zigler lib dir exists).
casein_devbox_heal_zigler_priv() {
  local root="${1:-.}"
  local healed=0
  local d base
  for base in \
    "${root}/native/casein_mob/_build" \
    "${root}/_build"; do
    [ -d "${base}" ] || continue
    while IFS= read -r -d '' d; do
      if [ ! -f "${d}/beam/sema.zig" ]; then
        echo "Healing incomplete zigler priv: ${d}"
        rm -rf "${d}"
        healed=1
      fi
    done < <(find "${base}" -type d -path '*/lib/zigler/priv' -print0 2>/dev/null || true)
  done
  if [ "${healed}" = "1" ]; then
    echo "Zigler priv heal done (incomplete trees removed)."
  else
    echo "Zigler priv OK (or no _build yet)."
  fi
}
