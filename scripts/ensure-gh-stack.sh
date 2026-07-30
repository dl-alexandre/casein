#!/usr/bin/env bash
#
# Install / refresh the `gh stack` CLI extension (GitHub stacked pull requests,
# public preview since 2026-07-30) for this box.
#
# Extensions live in the gh *data* dir (~/.local/share/gh/extensions), which is
# independent of GH_CONFIG_DIR — so one install covers every Casein agent-auth
# profile and every workspace on the host. Per-account *authentication* is still
# per-profile: `gh stack submit/merge` uses whichever GH_CONFIG_DIR is active.
#
# Usage:
#   bash scripts/ensure-gh-stack.sh            # install or upgrade + repo-local git config
#   bash scripts/ensure-gh-stack.sh --check    # report only, change nothing
#
set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

if ! command -v gh >/dev/null 2>&1; then
  echo "gh not found on PATH — install the GitHub CLI (v2.0+) first" >&2
  exit 1
fi

# `gh extension list` rows are tab-separated but the name column itself contains
# a space ("gh stack"), so index off the repo column rather than a fixed field.
installed_version() {
  gh extension list 2>/dev/null |
    awk -F'\t' '$2 == "github/gh-stack" { print $3 }'
}

have="$(installed_version)"

if [[ -n "$have" ]]; then
  echo "gh-stack present (${have})"
  if (( CHECK_ONLY == 0 )); then
    # `upgrade` is a no-op when already current; never fail the whole run on a
    # transient network error.
    gh extension upgrade gh-stack 2>&1 | sed 's/^/  /' || echo "  (upgrade check skipped)"
  fi
elif (( CHECK_ONLY == 1 )); then
  echo "gh-stack NOT installed (run without --check to install)"
else
  gh extension install github/gh-stack
  echo "gh-stack installed ($(installed_version))"
fi

# Preview availability probe. The stacked-PR schema ships per account/repo as the
# public preview rolls out; without it `gh stack submit` fails server-side.
if gh api graphql -f query='{ __type(name: "PullRequestStack") { name } }' \
     --jq '.data.__type.name' 2>/dev/null | grep -q PullRequestStack; then
  echo "stacked-PR API available for $(gh api user --jq .login 2>/dev/null || echo 'this account')"
else
  echo "WARNING: stacked-PR GraphQL types not visible for this account — preview may not have rolled out yet" >&2
fi

# gh-stack hangs on interactive prompts; these two settings remove the two
# prompts an agent cannot answer. Scoped to the current repo on purpose — a
# global rerere/pushDefault flip would change behaviour for every user and repo
# on a shared devbox.
if (( CHECK_ONLY == 0 )) && git rev-parse --git-dir >/dev/null 2>&1; then
  git config --local rerere.enabled true
  git config --local remote.pushDefault origin
  echo "repo-local git config set: rerere.enabled=true remote.pushDefault=origin"
fi
