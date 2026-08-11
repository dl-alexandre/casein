#!/usr/bin/env bash
#
# Loud, honest red for a failed actions/upload-artifact step (#889).
#
# Call this from a follow-up step gated on the upload step's failure. Always
# exits non-zero — never soft-passes, never continue-on-error. The red stays a
# red; this only names the usual cause so operators do not treat it as a
# build/sign/verify regression or waste cycles on reruns.
#
# Usage (GitHub Actions):
#   - name: Upload ...
#     id: upload_package
#     uses: actions/upload-artifact@...
#   - name: Diagnose artifact upload failure
#     if: failure() && steps.upload_package.conclusion == 'failure'
#     run: bash scripts/report-actions-artifact-quota-failure.sh
#
set -euo pipefail

WORKFLOW_NAME="${CASEIN_DESKTOP_WORKFLOW_NAME:-desktop package}"
PLATFORM="${CASEIN_DESKTOP_PLATFORM:-desktop}"

message="$(
  cat <<EOF
ACTIONS ARTIFACT QUOTA (or CreateArtifact failure) — NOT a ${PLATFORM} build/sign/verify failure.

What already happened
  - Build / package / smoke / verify steps before upload may be GREEN.
  - Only the actions/upload-artifact CreateArtifact call failed.
  - Typical Actions line: "Failed to CreateArtifact: Artifact storage quota has been hit."

What this is
  - An ACCOUNT/ORG GitHub Actions artifact storage limit — not this repo's code,
    not a packaging bug, not a flaky test.
  - Quota is org/account-wide. This repo has historically held only ~1–2 GB of
    live artifacts; purging *this* repo alone does not clear org quota when
    other repositories hold the bulk.

What will NOT help
  - Rerunning this workflow until GitHub recalculates quota (often 6–12h after
    deletions elsewhere, sometimes longer).
  - Demoting the macOS/desktop gate to advisory, continue-on-error, or skipping
    the upload to force green — forbidden (honest red; gate stays REQUIRED).
  - Hand-patching product code to "route around" CI red.

What will help
  - Org/account owner: free Actions artifact storage (other repos, old runs) or
    raise the billing plan limit.
  - After quota headroom returns, re-run once — do not thrash reruns before then.
  - Keep retention-days caps on desktop uploads (separate from this diagnose).

Gate policy
  - macOS desktop check stays REQUIRED when it runs (docs/decisions/macos-gate-policy.md).
  - This job remains red until upload succeeds; that is intentional.

Workflow: ${WORKFLOW_NAME}
EOF
)"

# Annotations show in the Actions UI job header / annotations panel.
while IFS= read -r line; do
  printf '::error title=Actions artifact quota (not a build failure)::%s\n' "$line"
done <<<"$message"

# Step summary for humans opening the job page.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Actions artifact quota — honest red"
    echo
    echo '```text'
    printf '%s\n' "$message"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi

# Plain log (also visible when annotations are collapsed).
printf '%s\n' "$message" >&2

exit 1
