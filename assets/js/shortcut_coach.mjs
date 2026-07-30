// Mastery decay for the keyboard-shortcut coach.
//
// Clicking a header button pops "New window: Press Ctrl + B, then c" at the
// bottom of the screen. That is useful the first few times and pure noise
// forever after — the old listener fired on every click for the lifetime of the
// install. This tracks per-action usage in localStorage and retires each hint
// once the operator has clearly seen it, the same versioned-flag shape
// gesture_coach.js already uses for its first-run card.
//
// Pure: no DOM, no storage. `loadState`/`saveState` in shortcut_coach_storage
// (see app.js wiring) supply the persistence.

export const COACH_VERSION = "1"
export const STORAGE_KEY = `casein:shortcut-coach:v${COACH_VERSION}`

// Three sightings is enough to learn one chord. Past that the hint is telling
// you something you just did on purpose.
export const MASTERY_THRESHOLD = 3

export function createState() {
  return {v: COACH_VERSION, uses: {}}
}

/**
 * Parse persisted JSON, discarding anything from a previous coach version so a
 * changed shortcut set re-teaches itself.
 */
export function parseState(raw) {
  if (!raw) return createState()

  try {
    const parsed = JSON.parse(raw)
    if (!parsed || parsed.v !== COACH_VERSION || typeof parsed.uses !== "object") {
      return createState()
    }
    return {v: COACH_VERSION, uses: {...parsed.uses}}
  } catch (_) {
    return createState()
  }
}

export function serializeState(state) {
  return JSON.stringify({v: COACH_VERSION, uses: state.uses || {}})
}

/**
 * Stable key for an action. The visible label can shift with state ("Zoom pane"
 * vs "Unzoom pane") while the chord stays the same, so the shortcut is the
 * identity — otherwise a toggling button would never reach mastery.
 */
export function actionKey(shortcut) {
  if (!shortcut) return null
  return `${shortcut}`.trim().toLowerCase().replace(/\s+/g, " ") || null
}

export function usesOf(state, shortcut) {
  const key = actionKey(shortcut)
  if (!key) return 0
  return state?.uses?.[key] || 0
}

/**
 * Should this click show its hint?
 *
 * `enabled` is the server-side preference (Notifications drawer → Interface →
 * shortcut hints); when the operator turns it off, nothing shows regardless of
 * how much decay is left.
 */
export function shouldShowHint(state, shortcut, {enabled = true} = {}) {
  if (!enabled) return false
  if (!actionKey(shortcut)) return false
  return usesOf(state, shortcut) < MASTERY_THRESHOLD
}

/**
 * Count one use. Saturates at the threshold so the stored numbers stay small
 * and a long-lived install does not grow an unbounded integer per chord.
 */
export function recordUse(state, shortcut) {
  const key = actionKey(shortcut)
  if (!key) return state

  const current = state?.uses?.[key] || 0
  if (current >= MASTERY_THRESHOLD) return state

  return {v: COACH_VERSION, uses: {...(state?.uses || {}), [key]: current + 1}}
}

/**
 * Remaining sightings for an action — drives the "2 more times" affordance and
 * makes the decay observable in tests.
 */
export function remainingHints(state, shortcut) {
  return Math.max(0, MASTERY_THRESHOLD - usesOf(state, shortcut))
}
