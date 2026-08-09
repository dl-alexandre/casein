#!/usr/bin/env bash
#
# Hermetic unit tests for bare-repo primary resolve in
# scripts/lib/agent-worktree.sh (casein#744 item 1 / Mira-class CASEIN_CHECKOUT).
# Builds a throwaway bare fixture with `git init --bare`; no tmux, no real spawn.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/agent-worktree.sh
source "${ROOT}/scripts/lib/agent-worktree.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/casein-agent-worktree-bare.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

BARE="${SCRATCH}/product.git"
WT_ROOT="${SCRATCH}/worktrees"
SEED="${SCRATCH}/seed"

mkdir -p "$SEED"
git -C "$SEED" init -q
git -C "$SEED" config user.email "test@example.com"
git -C "$SEED" config user.name "test"
printf 'seed\n' >"${SEED}/README"
git -C "$SEED" add README
git -C "$SEED" commit -q -m "seed"
git -C "$SEED" branch -M master
git clone --bare -q "$SEED" "$BARE"
# origin/* refs so agent_worktree_default_base_ref can pick origin/master
git -C "$BARE" update-ref refs/remotes/origin/master refs/heads/master
git -C "$BARE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master

# ── bare detection ──────────────────────────────────────────────────────────
agent_worktree_is_bare "$BARE" || fail "expected bare fixture to be bare"
ok
agent_worktree_is_bare "$SEED" && fail "seed work tree must not be bare" || ok
agent_worktree_is_bare "" && fail "empty path must not be bare" || ok

# ── primary_repo: bare path resolves (show-toplevel alone would fail) ───────
export CASEIN_CHECKOUT="$BARE"
got="$(agent_worktree_primary_repo)" || fail "primary_repo must succeed on bare checkout"
# porcelain first worktree entry is the bare path itself
[[ "$got" == "$BARE" ]] || fail "primary_repo got '${got}', want '${BARE}'"
ok

# Prove the old probe fails so the regression stays meaningful.
if git -C "$BARE" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "show-toplevel unexpectedly succeeded on bare — fixture is not bare enough"
fi
ok

# ── primary_repo: normal work tree still works ──────────────────────────────
export CASEIN_CHECKOUT="$SEED"
got="$(agent_worktree_primary_repo)" || fail "primary_repo must succeed on normal checkout"
[[ "$got" == "$(git -C "$SEED" rev-parse --show-toplevel)" ]] || fail "normal primary mismatch: '${got}'"
ok

# ── primary_repo: missing / non-git fails ───────────────────────────────────
export CASEIN_CHECKOUT="${SCRATCH}/no-such-dir"
agent_worktree_primary_repo >/dev/null 2>&1 && fail "missing path must fail" || ok
export CASEIN_CHECKOUT="$SCRATCH"
agent_worktree_primary_repo >/dev/null 2>&1 && fail "non-git dir must fail" || ok
unset CASEIN_CHECKOUT
agent_worktree_primary_repo >/dev/null 2>&1 && fail "unset CASEIN_CHECKOUT must fail" || ok

# ── inside_primary: standing on the bare root counts ────────────────────────
export CASEIN_CHECKOUT="$BARE"
agent_worktree_inside_primary "$BARE" || fail "bare path should count as inside primary"
ok
agent_worktree_inside_primary "$SCRATCH" && fail "unrelated dir must not be inside primary" || ok

# ── create: branch a linked worktree from the bare primary ──────────────────
export CASEIN_CHECKOUT="$BARE"
export CASEIN_AGENT_WORKTREE_ROOT="$WT_ROOT"
export CASEIN_AGENT_WORKTREE_BASE="origin/master"

path="$(agent_worktree_create "opencode" "bare-fixture")" || fail "worktree create from bare failed"
[[ -d "$path" ]] || fail "created path missing: ${path}"
[[ -f "${path}/.git" ]] || fail "created path is not a linked worktree: ${path}"
[[ -f "${path}/README" ]] || fail "created worktree missing seeded README"
branch="$(git -C "$path" rev-parse --abbrev-ref HEAD)"
[[ "$branch" == agent/opencode/bare-fixture-* ]] || fail "unexpected branch '${branch}'"
ok

# Second create must not collide (unique stamp path).
path2="$(agent_worktree_create "opencode" "bare-fixture")" || fail "second worktree create failed"
[[ "$path2" != "$path" ]] || fail "second create reused path"
[[ -d "$path2" ]] || fail "second path missing"
ok

# Cleanup worktrees so the bare fixture can be removed by trap.
git -C "$BARE" worktree remove --force "$path" >/dev/null 2>&1 || true
git -C "$BARE" worktree remove --force "$path2" >/dev/null 2>&1 || true

echo "ok: ${pass} assertions (bare agent-worktree primary resolve)"
