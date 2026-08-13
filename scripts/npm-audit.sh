#!/usr/bin/env bash
#
# npm audit for the product trees (#929).
#
# Install paths keep --no-audit for speed/determinism. This script is the
# scan. Every install site must invoke it (or an equivalent
# `npm audit --package-lock-only --audit-level=high`).
# scripts/check-npm-audit-guard.sh fails the gate if a new install site
# skips the scan.
#
# Threshold is --audit-level=high. Never lower it without an explicit issue.
# moderate/low is backlog, not a red gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}" || exit 1

LEVEL="${NPM_AUDIT_LEVEL:-high}"
if [[ $# -gt 0 ]]; then
  trees=("$@")
else
  trees=(assets priv/scripts)
fi

for dir in "${trees[@]}"; do
  if [[ ! -f "${dir}/package-lock.json" ]]; then
    echo ">>> npm-audit: missing ${dir}/package-lock.json" >&2
    exit 1
  fi
  echo ">>> npm-audit: ${dir} (--audit-level=${LEVEL})"
  (
    cd "${dir}"
    npm audit --package-lock-only --audit-level="${LEVEL}"
  )
done
