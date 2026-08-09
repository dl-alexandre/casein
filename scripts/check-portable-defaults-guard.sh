#!/usr/bin/env bash
#
# Portable product-default guard (#248 first slice).
#
# Rejects MILC/devbox operator paths and domains that leak into the *portable*
# product surface as unconditional defaults. Overlay-gated references
# (CASEIN_ON_DEVBOX / on_devbox?) remain allowed in runtime.exs and legacy
# origin migration tables — those are opt-in deployment seams, not defaults a
# fresh clone inherits.
#
# Exit 0 = clean. Exit 1 = violation (printed).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

violations=0

fail() {
  printf '>>> check-portable-defaults-guard: %s\n' "$*" >&2
  violations=$((violations + 1))
}

# Product code and compile-time config must not hard-code the MILC operator home
# as a string-literal fallback. runtime.exs is included: the boot path must
# resolve HOME portably too. Doc comments that mention the path as a negative
# example are ignored by matching only quoted literals.
while IFS= read -r hit; do
  fail "host-specific home fallback: ${hit}"
done < <(
  grep -RIn --include='*.ex' --include='*.exs' -E '["'\'']/home/devbox["'\'']' lib config 2>/dev/null || true
)

# Compile-time / module defaults must not pin the MILC preview domain. The
# portable profile leaves domain unset; ON_DEVBOX may still supply it at runtime.
while IFS= read -r hit; do
  # runtime.exs may mention the domain only inside an on_devbox? branch — checked below.
  case "$hit" in
    config/runtime.exs:*) continue ;;
    *) fail "unconditional MILC preview-domain default: ${hit}" ;;
  esac
done < <(
  grep -RIn --include='*.ex' --include='*.exs' -E \
    '@default_domain[[:space:]]+"devbox\.milcgroup\.com"|domain:[[:space:]]*"devbox\.milcgroup\.com"|CASEIN_PREVIEW_DOMAIN",[[:space:]]*"devbox\.milcgroup\.com"' \
    lib config 2>/dev/null || true
)

# runtime.exs may default the preview domain only when CASEIN_ON_DEVBOX is set.
if grep -n 'devbox\.milcgroup\.com' config/runtime.exs >/dev/null 2>&1; then
  if ! grep -q 'on_devbox' config/runtime.exs; then
    fail "config/runtime.exs references devbox.milcgroup.com without an on_devbox gate"
  fi

  # The portable preview_own_origin assignment must not use a milcgroup default
  # string as System.get_env/2's second argument.
  if grep -nE 'System\.get_env\("CASEIN_PREVIEW_DOMAIN",[[:space:]]*"devbox\.milcgroup\.com"\)' \
    config/runtime.exs >/dev/null 2>&1; then
    fail 'CASEIN_PREVIEW_DOMAIN still defaults to devbox.milcgroup.com for every profile'
  fi
fi

if [ "$violations" -gt 0 ]; then
  printf '\n>>> check-portable-defaults-guard: %s violation(s). See issue #248.\n' "$violations" >&2
  exit 1
fi

echo ">>> check-portable-defaults-guard: portable product defaults are host-agnostic."
exit 0
