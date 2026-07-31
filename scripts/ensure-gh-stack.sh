#!/usr/bin/env bash
#
# Install / refresh the `gh stack` CLI extension (GitHub stacked pull requests,
# public preview since 2026-07-30) for this box.
#
# Extensions live in the gh *data* dir — "$XDG_DATA_HOME/gh/extensions", falling
# back to ~/.local/share/gh/extensions. That is keyed to HOME/XDG_DATA_HOME and
# is independent of GH_CONFIG_DIR, so one install covers every Casein agent-auth
# profile *that shares this HOME* — but NOT a runtime with a different HOME, a
# different XDG_DATA_HOME, or a sandbox that does not bind the data dir. Run this
# again under any such environment. Per-account *authentication* is separate
# again: `gh stack submit/merge` uses whichever GH_CONFIG_DIR is active.
#
# Usage:
#   bash scripts/ensure-gh-stack.sh                  # install or upgrade + git config
#   bash scripts/ensure-gh-stack.sh --check          # report only, change nothing
#   bash scripts/ensure-gh-stack.sh --repo <path>    # configure that repo, not $PWD
#
set -euo pipefail

CHECK_ONLY=0
REPO="${CASEIN_GH_STACK_REPO:-$PWD}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --repo) REPO="${2:?--repo needs a path}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

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
# prompts an agent cannot answer. Scoped to one repo on purpose — a global
# rerere/pushDefault flip would change behaviour for every user and repo on a
# shared devbox. Never clobber a value someone already chose: pushDefault=origin
# is wrong for a fork workflow, where pushes belong on a different remote.
set_if_unset() {
  local key="$1" value="$2" current
  current="$(git -C "$REPO" config --local --get "$key" 2>/dev/null || true)"
  if [[ -n "$current" ]]; then
    echo "  ${key} already ${current} — left alone"
  else
    git -C "$REPO" config --local "$key" "$value" && echo "  ${key}=${value}"
  fi
}

if (( CHECK_ONLY == 0 )) && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "git config for ${REPO}:"
  set_if_unset rerere.enabled true
  set_if_unset remote.pushDefault origin
fi
