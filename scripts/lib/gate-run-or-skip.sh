#!/usr/bin/env bash
# Run a gate command unless CASEIN_GATE_SKIP_<TOKEN>=1 (already verified earlier).
# Usage: gate-run-or-skip.sh FORMAT mix format --check-formatted
#        gate-run-or-skip.sh DOC_CITATIONS ./scripts/check-doc-citations.sh
#
# Skipping is only for duplicate identical checks after a prior green fail-fast
# phase (#818). Unset/empty TOKEN never skips — check set stays identical.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 TOKEN command [args...]" >&2
  exit 2
fi

token="$1"
shift
var="CASEIN_GATE_SKIP_${token}"

if [[ "${!var:-}" == "1" ]]; then
  printf '>>> %s already verified (CASEIN_GATE_SKIP_%s=1) — skip\n' "$token" "$token"
  exit 0
fi

exec "$@"
