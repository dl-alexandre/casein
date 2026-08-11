#!/usr/bin/env bash
#
# Static guard for #866 macOS gate policy.
#
# Asserts:
#   - docs/decisions/macos-gate-policy.md exists and restates REQUIRED +
#     quarantine + AM + #865
#   - .github/workflows/macos-desktop.yml keeps package-smoke and the canonical
#     self-hosted matrix name fragment (check-name freeze)
#   - the workflow does NOT use continue-on-error (would hide reds)
#
# Does NOT rename or restructure jobs. Exit 0 = policy surface intact.
#
# Override workflow path: MACOS_DESKTOP_WORKFLOW=/path/to.yml
# Override policy doc:    MACOS_GATE_POLICY_DOC=/path/to.md

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${MACOS_DESKTOP_WORKFLOW:-$ROOT/.github/workflows/macos-desktop.yml}"
POLICY_DOC="${MACOS_GATE_POLICY_DOC:-$ROOT/docs/decisions/macos-gate-policy.md}"

# Must match matrix name in macos-desktop.yml self-hosted include entry.
# Renaming this string changes the GitHub check title and detaches board/AM
# discipline — fail closed.
CANONICAL_MATRIX_NAME='macOS 26 arm64 (self-hosted)'

violations=0

fail() {
  printf '>>> check-macos-gate-policy: %s\n' "$*" >&2
  violations=$((violations + 1))
}

if [[ ! -f "$WORKFLOW" ]]; then
  fail "missing workflow: $WORKFLOW"
  exit 1
fi

if [[ ! -f "$POLICY_DOC" ]]; then
  fail "missing policy doc: $POLICY_DOC"
fi

# --- package-smoke + name freeze --------------------------------------------
if ! grep -qE '^[[:space:]]*package-smoke:' "$WORKFLOW"; then
  fail "workflow missing package-smoke job (real build/verify truth)"
fi

if ! grep -q 'Build and verify' "$WORKFLOW"; then
  fail "workflow missing 'Build and verify' job name template (check-name freeze)"
fi

if ! grep -qF "$CANONICAL_MATRIX_NAME" "$WORKFLOW"; then
  fail "workflow missing canonical matrix name '${CANONICAL_MATRIX_NAME}' (renaming detaches required-check matching)"
fi

# --- red must remain reported -----------------------------------------------
if grep -n 'continue-on-error:' "$WORKFLOW" | grep -vE '^\s*#'; then
  fail "workflow must not use continue-on-error (would hide macOS reds)"
fi

# --- policy doc -------------------------------------------------------------
if [[ -f "$POLICY_DOC" ]]; then
  if ! grep -qE 'STAYS REQUIRED|stays required|\*\*Yes — required\*\*' "$POLICY_DOC"; then
    fail "policy doc must restate that macOS gate stays REQUIRED"
  fi
  if ! grep -q 'ci/macos-quarantine' "$POLICY_DOC"; then
    fail "policy doc must document ci/macos-quarantine"
  fi
  if ! grep -qiE 'auto-merge|automerge' "$POLICY_DOC"; then
    fail "policy doc must document AM interaction"
  fi
  if ! grep -q '#865' "$POLICY_DOC"; then
    fail "policy doc must point infra fix at #865"
  fi
  if ! grep -qF "$CANONICAL_MATRIX_NAME" "$POLICY_DOC"; then
    fail "policy doc must freeze check name '${CANONICAL_MATRIX_NAME}'"
  fi
fi

if [[ "$violations" -gt 0 ]]; then
  printf '>>> check-macos-gate-policy: %d violation(s)\n' "$violations" >&2
  exit 1
fi

printf 'check-macos-gate-policy: ok (%s)\n' "$WORKFLOW"
exit 0
