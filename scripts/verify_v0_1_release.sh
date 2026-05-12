#!/usr/bin/env bash
set -euo pipefail

# v0.1 release-candidate packaging check.
#
# This intentionally verifies the supported release path. DevIDE v0.1 does not
# ship an escript because the controller is a Phoenix/OTP release and the
# runner is a Mix task used from the repo checkout for dogfood.

RELEASE_DIR="_build/prod/rel/dev_ide"
APP_PRIV_DIR="$RELEASE_DIR/lib/dev_ide-0.1.0/priv"

if grep -q 'escript:' mix.exs; then
  echo "unexpected escript config found; v0.1 supports the OTP release path only" >&2
  exit 1
fi

MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release dev_ide --overwrite

test -x "$RELEASE_DIR/bin/dev_ide"
test -x "$RELEASE_DIR/bin/migrate"
test -f "$RELEASE_DIR/README.md"
test -f "$RELEASE_DIR/docs/v0_1_release_candidate.md"
test -f "$APP_PRIV_DIR/static/cache_manifest.json"
test -f "$APP_PRIV_DIR/repo/migrations/20260511214902_create_assignment_events.exs"
test -f "$APP_PRIV_DIR/repo/migrations/20260512001532_create_fleet_artifact_chunks.exs"

echo "v0.1 release check passed: $RELEASE_DIR"
