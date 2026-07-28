#!/usr/bin/env bash
#
# Provision the runtime dependencies the preview-ui-walk collector needs.
#
# Why this exists: both deps were previously present only as ad-hoc global npm
# state on one box. A fresh devbox (or CI runner) therefore failed every walk at
# "cannot resolve playwright-core", and --preflight-only reported BLOCKED for a
# reason that looked like a code defect rather than a missing dependency.
#
#   playwright-core  drives the cached Chromium (the walk browser)
#   ws               the scratch Phoenix-protocol server used to PROVE the
#                    WebSocket/LiveView collector during --preflight-only
#   pixelmatch       the proven PNG pixel-diff engine for the visual-baseline
#   pngjs            collector (batch 3b) — pinned EXACTLY so identical inputs
#                    yield identical diffs across boxes and reruns
#
# Chromium itself is NOT downloaded here: the devbox already ships a cached
# build under ~/.cache/ms-playwright, and the pinned playwright-core version
# must match that build's revision. The script verifies the match instead of
# silently installing a mismatched pair.
#
# Usage:
#   bash scripts/ensure-preview-walk-deps.sh          # install + verify
#   bash scripts/ensure-preview-walk-deps.sh --check  # verify only, exit 1 if missing
#
set -euo pipefail

# Pinned to the Chromium revision cached on the devbox image. Bump both together:
# playwright-core's browsers.json chromium revision MUST match a directory under
# ~/.cache/ms-playwright/chromium-<revision>, or the walk launches nothing.
PLAYWRIGHT_VERSION="${PREVIEW_WALK_PLAYWRIGHT_VERSION:-1.62.0}"
WS_VERSION="${PREVIEW_WALK_WS_VERSION:-8}"
# Exact pins (no ranges): a floating diff engine could change what "0.1% changed"
# means between runs, which would silently move the visual-baseline gate.
PIXELMATCH_VERSION="${PREVIEW_WALK_PIXELMATCH_VERSION:-5.3.0}"
PNGJS_VERSION="${PREVIEW_WALK_PNGJS_VERSION:-7.0.0}"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

npm_root="$(npm root -g 2>/dev/null || true)"
if [[ -z "$npm_root" ]]; then
  echo "✗ npm not available; cannot provision preview-ui-walk deps" >&2
  exit 1
fi

have() { [[ -d "$npm_root/$1" ]]; }

missing=()
have playwright-core || missing+=("playwright-core@${PLAYWRIGHT_VERSION}")
have ws || missing+=("ws@${WS_VERSION}")
have pixelmatch || missing+=("pixelmatch@${PIXELMATCH_VERSION}")
have pngjs || missing+=("pngjs@${PNGJS_VERSION}")

if [[ ${#missing[@]} -gt 0 ]]; then
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo "✗ missing preview-ui-walk deps: ${missing[*]}" >&2
    echo "  run: bash scripts/ensure-preview-walk-deps.sh" >&2
    exit 1
  fi
  echo ">>> installing ${missing[*]}"
  npm install -g "${missing[@]}"
fi

# Verify the pinned playwright-core actually matches a cached Chromium build.
# A mismatch is worse than a missing dep: the walk launches, then fails deep in
# a page with an error that reads like a product defect.
pw_json="$npm_root/playwright-core/browsers.json"
if [[ -f "$pw_json" ]]; then
  want_rev="$(node -e "
    const b=require('$pw_json').browsers.find(b=>b.name==='chromium');
    process.stdout.write(String(b && b.revision || ''));
  " 2>/dev/null || true)"
  if [[ -n "$want_rev" ]]; then
    if [[ -d "$HOME/.cache/ms-playwright/chromium-$want_rev" ]]; then
      echo "✓ playwright-core expects chromium-$want_rev and it is cached"
    else
      echo "✗ playwright-core expects chromium-$want_rev but no cached build matches:" >&2
      ls -d "$HOME/.cache/ms-playwright/"chromium-* 2>/dev/null >&2 || echo "  (no cached chromium at all)" >&2
      echo "  install it with: npx playwright install chromium" >&2
      exit 1
    fi
  fi
fi

# ESM import() ignores NODE_PATH, so the collector resolves these with
# createRequire. Prove resolution the same way rather than trusting the dir.
node -e "
  const { createRequire } = require('node:module');
  const req = createRequire('$npm_root/x.js');
  req('playwright-core');
  req('ws');
  req('pixelmatch');
  req('pngjs');
  console.log('✓ playwright-core, ws, pixelmatch and pngjs resolve from the global root');
" || {
  echo "✗ deps present on disk but not resolvable from $npm_root" >&2
  exit 1
}

echo ">>> preview-ui-walk deps ready (NODE_PATH=$npm_root)"
