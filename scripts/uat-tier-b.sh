#!/usr/bin/env bash
#
# uat-tier-b.sh — post-deploy Tier B UAT smoke hook.
#
# Intended to be invoked AFTER a release is activated and the handoff is verified
# (scripts/deploy-poller.sh -> scripts/verify_deploy_handoff.sh), after the
# handoff confirms the revision actually serving (avoiding a draining instance,
# per the canary-liveview-trace lesson).
#
# Tier B drives the LIVE release node over its real MCP surface
# (POST /api/preview/mcp on /run/devide/current.sock) as the workspace owner's
# forward-auth identity, runs a small read-mostly acceptance set, and persists
# each run as a tier_b DevIDE.UAT.Run. See DevIDE.UAT.TierB.
#
# NOTE: This is a scaffold. A real run needs the live MCP agent driver and a
# disposable UAT workspace; both are live-only and not exercised in CI-of-this-
# repo. Until those are wired, --dry-run is the supported mode.
#
# Usage:
#   bash scripts/uat-tier-b.sh --dry-run
#   bash scripts/uat-tier-b.sh            # live run (requires the wiring above)
set -euo pipefail

SOCKET="${DEVIDE_SOCKET:-/run/devide/current.sock}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

echo "[uat tier-b] target socket: ${SOCKET}"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "[uat tier-b] dry-run: would POST JSON-RPC to ${SOCKET} /api/preview/mcp"
  echo "[uat tier-b] dry-run: would run read-mostly criteria as the workspace owner"
  exit 0
fi

echo "[uat tier-b] live runs require the MCP agent driver + a disposable UAT" >&2
echo "[uat tier-b] workspace (live-only wiring). Use --dry-run until wired." >&2
exit 3
