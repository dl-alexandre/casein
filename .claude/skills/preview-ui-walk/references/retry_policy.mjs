#!/usr/bin/env node
// Batch 4: bounded retry policy with flakiness recording.
//
// Retries exist to separate infrastructure flake (slow LiveView mount, a
// transient server hiccup) from real defects — NOT to grind a red page green.
// Hence the hard rules, none of which a manifest can override:
//
//   * Only READ-ONLY pages retry. A page with mutating steps (click/fill/…)
//     is pinned to max_attempts 1 and is NEVER replayed: replaying a mutation
//     that half-succeeded creates duplicate fixtures and corrupts the very
//     evidence the walk exists to collect.
//   * Only TIMEOUT and RUNTIME_ERROR are retryable. A manifest may list other
//     statuses in retries.retry_on; anything outside the safe set is dropped
//     and reported as dropped, never honored. Retrying ASSERT_FAILED hides
//     defects; retrying BOUNCED hides access regressions; retrying BLOCKED
//     hides missing evidence.
//   * Attempts are bounded (schema: 1..5).
//
// Flakiness is evidence: every attempt's status and duration is recorded, and
// a page whose attempts disagree is marked flaky even when it ends green — a
// walk that quietly absorbed two timeouts has still observed two timeouts.

import { isMutatingStep } from "./page_steps.mjs";

export const SAFE_RETRY_STATUSES = new Set(["TIMEOUT", "RUNTIME_ERROR"]);

export function pageHasMutatingSteps(pageSpec) {
  const all = [...(pageSpec?.steps || []), ...(pageSpec?.cleanup_steps || [])];
  return all.some((s) => isMutatingStep(s));
}

/**
 * Effective policy for one page. `manifest.retries` is the only knob; the
 * safe-set and mutation rules are structural.
 */
export function retryPolicy(manifest, pageSpec) {
  const cfg = manifest?.retries || {};
  const requested = Math.min(Math.max(Number(cfg.max_attempts) || 1, 1), 5);
  if (pageHasMutatingSteps(pageSpec)) {
    return {
      maxAttempts: 1,
      retryOn: new Set(),
      droppedStatuses: [],
      reason: requested > 1 ? "mutating page: never replayed (max_attempts forced to 1)" : null,
      recordFlakiness: cfg.record_flakiness !== false,
    };
  }
  const wanted = Array.isArray(cfg.retry_on) && cfg.retry_on.length
    ? cfg.retry_on.map(String)
    : [...SAFE_RETRY_STATUSES];
  const retryOn = new Set(wanted.filter((s) => SAFE_RETRY_STATUSES.has(s)));
  const droppedStatuses = wanted.filter((s) => !SAFE_RETRY_STATUSES.has(s));
  return {
    maxAttempts: requested,
    retryOn,
    droppedStatuses,
    reason: null,
    recordFlakiness: cfg.record_flakiness !== false,
  };
}

/** May attempt N+1 happen after `status` on attempt N (1-based)? */
export function shouldRetry(status, attempt, policy) {
  if (!policy || policy.maxAttempts <= 1) return false;
  if (attempt >= policy.maxAttempts) return false;
  return policy.retryOn.has(status);
}

/**
 * Fold per-attempt records into the flakiness evidence attached to a result
 * row. `attempts` is [{status, ms, reason}] in order; the LAST attempt is the
 * page's reported outcome.
 */
export function flakinessEvidence(attempts, policy) {
  if (!Array.isArray(attempts) || attempts.length === 0) return null;
  if (attempts.length === 1 && !(policy && policy.reason)) return null;
  const statuses = attempts.map((a) => a.status);
  const disagree = new Set(statuses).size > 1;
  return {
    attempts: attempts.map((a) => ({ status: a.status, ms: a.ms, reason: a.reason || null })),
    attemptCount: attempts.length,
    flaky: disagree,
    finalStatus: statuses[statuses.length - 1],
    note: policy?.reason || null,
    droppedStatuses: policy?.droppedStatuses?.length ? policy.droppedStatuses : undefined,
  };
}
