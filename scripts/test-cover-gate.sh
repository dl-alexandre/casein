#!/usr/bin/env bash
#
# Run the test suite with coverage and enforce the mix.exs threshold.
#
# CI partitions (--partitions N) are intentionally not used: this devbox runs a
# host-wide flock below to avoid concurrent Ghostty-NIF full suites (BEAM segfault).
# If GitHub-hosted CI revives, prefer a matrix with --export-coverage partition-N
# plus a mix test.coverage merge job rather than parallel BEAMs on one box.
#
# Full-suite runs on this devbox are occasionally truncated under load (ExUnit
# on_exit races), which drops both the executed test count and reported
# coverage. Retry a handful of fixed seeds until we see a complete run that
# meets the configured floor.
#
# Used by `mix precommit.ci` instead of bare `mix test --cover`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Serialize the gate across concurrent runners on this box. Two full Ghostty-NIF
# `mix test` suites running at once (e.g. two agents pushing to master from
# separate checkouts) segfault the BEAM (exit 139) and abort both pushes. Take a
# host-wide exclusive flock for the whole gate so only one runs at a time; others
# wait up to LOCK_WAIT, then give up with a clear message rather than hanging the
# push forever. The lock is held on fd 9 for the life of this process and releases
# automatically on exit. Set TEST_COVER_LOCK_WAIT=0 to fail fast instead of
# waiting (e.g. CI where runs are already serialized).
LOCK_FILE="${TEST_COVER_LOCK_FILE:-/tmp/devide-test-cover-gate.lock}"
LOCK_WAIT="${TEST_COVER_LOCK_WAIT:-2400}"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || true
  if ! flock -w "$LOCK_WAIT" 9; then
    echo "test-cover-gate: another gate held ${LOCK_FILE} for >${LOCK_WAIT}s; aborting" >&2
    exit 1
  fi
else
  echo "test-cover-gate: flock unavailable; running without cross-runner serialization" >&2
fi

# MIN_TESTS is a COMPLETENESS check (catch the ExUnit on_exit race that truncates
# a run), NOT a coverage target — coverage is enforced separately by THRESHOLD.
# Convention: keep it ~5-10% below the current green test count so real
# truncation is caught while normal suite growth/shrink doesn't trip it. Bump or
# lower it whenever the suite changes size by more than that margin (e.g. after a
# large feature or removal) rather than letting it drift. Last set 2026-06-18
# after the delegated-execution removal + raw-only collapse: green suite ~1192,
# floor 1100 (~8% margin).
MIN_TESTS="${TEST_COVER_MIN_TESTS:-1100}"
THRESHOLD="${TEST_COVER_THRESHOLD:-66}"
SEED_TIMEOUT="${TEST_COVER_SEED_TIMEOUT:-25m}"
SEEDS=(1 2 3 4 5 6 7 8 9 10)

check_deps_locked() {
  local deps_out
  deps_out="$(mktemp)"

  set +e
  mix deps.get --check-locked >"$deps_out" 2>&1
  local deps_exit=$?
  set -e

  if [ "$deps_exit" -ne 0 ]; then
    echo "test-cover-gate: deps check failed (mix deps.get --check-locked exit=${deps_exit})" >&2
    cat "$deps_out" >&2
    rm -f "$deps_out"
    exit 1
  fi

  rm -f "$deps_out"
}

check_deps_locked

run_seed() {
  local seed="$1"
  local outfile
  outfile="$(mktemp)"

  # Keep errexit disabled for the whole helper. The caller intentionally handles
  # return code 1 as retryable and 2 as fail-fast; re-enabling errexit here makes
  # `return 1` exit the whole script before the seed loop can retry.
  set +e
  timeout --foreground "$SEED_TIMEOUT" mix test --cover --seed "$seed" 2>&1 | tee "$outfile"
  local mix_exit=$?

  local passed failed coverage failures_list

  # Parse both the rtk-filtered local format ("Result:" / "Failed:" /
  # "| <pct>% | Total") and raw `mix test --cover` output, which is what CI
  # emits without rtk ("<n> tests, <m> failures" and "  <pct>% | Total" with
  # no leading pipe). The gate previously only matched the rtk format, so
  # every passing CI run was flagged "unreadable" and retried until timeout.
  passed="$(
    grep -E '^Result:' "$outfile" | head -1 | grep -oE '[0-9]+' | head -1 || true
  )"
  if [ -z "$passed" ]; then
    passed="$(grep -oE '[0-9]+ tests?,' "$outfile" | tail -1 | grep -oE '[0-9]+' || true)"
  fi

  failed="$(
    grep -E '^Failed:' "$outfile" | head -1 | grep -oE '[0-9]+' | head -1 || true
  )"
  if [ -z "$failed" ]; then
    failed="$(grep -oE '[0-9]+ failures?' "$outfile" | tail -1 | grep -oE '[0-9]+' || true)"
  fi

  coverage="$(
    grep -E '[[:space:]]*[0-9]+\.[0-9]+%[[:space:]]+\| Total' "$outfile" \
      | tail -1 \
      | grep -oE '[0-9]+\.[0-9]+' \
      | head -1 \
      || true
  )"

  # Capture the ExUnit failure headers ("  N) test <name> (<Module>)") before the
  # temp file is removed, so a genuinely-red run names WHICH tests failed instead
  # of just a count — turns triage from "rerun locally to find out" into a glance.
  failures_list="$(grep -E '^[[:space:]]+[0-9]+\) (test|doctest|property) ' "$outfile" | head -20 || true)"

  rm -f "$outfile"

  if [ -z "$passed" ] || [ -z "$coverage" ]; then
    echo "test-cover-gate: seed=${seed} produced unreadable mix output (exit=${mix_exit})" >&2
    return 1
  fi

  if [ "$mix_exit" -eq 124 ]; then
    echo "test-cover-gate: seed=${seed} timed out after ${SEED_TIMEOUT}; evaluating captured output" >&2
  fi

  # Completeness gate FIRST. An under-count means the run was truncated by the
  # ExUnit on_exit race, so the failure/coverage numbers from this seed are
  # unreliable garbage — retry on a fresh seed (return 1).
  if [ "$passed" -lt "$MIN_TESTS" ]; then
    echo "test-cover-gate: seed=${seed} only ran ${passed} tests (<${MIN_TESTS}); likely truncated, retrying" >&2
    return 1
  fi

  # The run is COMPLETE, so failures and coverage are now trustworthy and
  # DETERMINISTIC. A red suite or coverage miss repeats on every seed — retrying
  # just burns ~10 more full-suite runs (and the loop can't be interrupted from
  # a background terminal). Fail fast (return 2) instead of seed-shopping for a
  # green run, which would also paper over genuine flakiness.
  if [ -n "$failed" ] && [ "$failed" -gt 0 ]; then
    echo "test-cover-gate: seed=${seed} had ${failed} failing test(s) in a complete run; failing fast (no retry)" >&2
    if [ -n "$failures_list" ]; then
      echo "test-cover-gate: failing tests (first 20):" >&2
      printf '%s\n' "$failures_list" >&2
    fi
    return 2
  fi

  if ! awk -v c="$coverage" -v t="$THRESHOLD" 'BEGIN { exit !(c >= t) }'; then
    echo "test-cover-gate: seed=${seed} coverage ${coverage}% < ${THRESHOLD}% in a complete run; failing fast (no retry)" >&2
    return 2
  fi

  echo "test-cover-gate: seed=${seed} passed=${passed} coverage=${coverage}%"
  return 0
}

for seed in "${SEEDS[@]}"; do
  set +e
  run_seed "$seed"
  rc=$?
  set -e
  case "$rc" in
    0) exit 0 ;;
    2)
      echo "test-cover-gate: complete run is genuinely red/under-covered; not retrying other seeds" >&2
      exit 1
      ;;
    *) : ;;  # 1 = truncated/unreadable, try the next seed
  esac
done

echo "test-cover-gate: exhausted seeds without a complete run (>=${MIN_TESTS} tests, >=${THRESHOLD}% coverage)" >&2
exit 1
