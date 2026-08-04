// Pure presentation for the undoable window-close toast.
//
// app.js owns the listener, the toast surface, and the pushEvent back to the
// server. This module just turns a `window:trashed` payload into the strings
// shown to the operator, so the wording and the deadline arithmetic can be
// unit-tested without a DOM.

const DEFAULT_GRACE_MS = 30_000

/**
 * Build the toast for a deferred window close.
 *
 * The toast's own lifetime IS the countdown: it is shown for exactly the grace
 * period, so it vanishing and the undo expiring are the same moment. The
 * remaining seconds go in the text too, because a toast that merely fades gives
 * no sense of how long is left.
 *
 * @param {{label?: string, grace_ms?: number}} detail push_event payload
 * @returns {{message: string, actionLabel: string, durationMs: number}}
 */
export function windowTrashToast(detail = {}) {
  const durationMs = graceMs(detail.grace_ms)
  const label = typeof detail.label === "string" && detail.label ? detail.label : "window"

  return {
    message: `Closed ${label} · ${formatSeconds(durationMs)} to undo`,
    actionLabel: "Undo",
    durationMs,
  }
}

/**
 * Clamp a server-supplied grace period to something sane.
 *
 * A missing or nonsense value must not produce a toast that never leaves or
 * one that is gone before it can be read.
 */
export function graceMs(value) {
  const n = Number(value)
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_GRACE_MS
  return Math.min(Math.max(Math.round(n), 1000), 300_000)
}

/** Whole seconds, rounded up — "0s to undo" would be a lie. */
export function formatSeconds(ms) {
  return `${Math.max(1, Math.ceil(ms / 1000))}s`
}
