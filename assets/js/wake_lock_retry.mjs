// Pure wake-lock acquire / release / visibility decisions.
//
// wake_lock.js owns the Screen Wake Lock sentinel, timers, and document
// listeners. This module answers "should we ping / acquire / release?" from
// plain inputs so the retry policy can be unit-tested without navigator APIs.

/** How long after the last terminal-frame ping the lock is held. */
export const HOLD_MS = 45_000

/**
 * Whether the Screen Wake Lock API is present.
 * @param {object|null|undefined} navigatorObj
 */
export function isWakeLockSupported(navigatorObj) {
  return typeof navigatorObj !== "undefined" && navigatorObj != null && "wakeLock" in navigatorObj
}

/**
 * Mobile/standalone surfaces where holding the screen awake is useful.
 * Desktop browsers are a no-op even when the API exists.
 */
export function isPreferredWakeLockSurface({coarsePointer = false, standalone = false} = {}) {
  return !!coarsePointer || !!standalone
}

/**
 * Gate for pingWakeLock: skip entirely when unsupported or not a preferred surface.
 */
export function shouldHandleWakeLockPing({supported = false, preferredSurface = false} = {}) {
  return !!supported && !!preferredSurface
}

/**
 * Gate for navigator.wakeLock.request: never request while a sentinel is held
 * or the document is hidden (the OS would deny / auto-release).
 */
export function shouldAcquireWakeLock({hasSentinel = false, visibilityState = "visible"} = {}) {
  return !hasSentinel && visibilityState === "visible"
}

/**
 * What to do on document visibilitychange while a wake-lock listener is bound.
 *
 * - visible + still within the active hold window after the last ping → re-acquire
 *   (the OS releases on hide; we restore if the agent was still "active")
 * - not visible → release our handle
 * - visible but the hold window expired → none (leave released)
 *
 * @returns {"acquire" | "release" | "none"}
 */
export function wakeLockVisibilityDecision({
  visibilityState = "visible",
  lastPingAt = 0,
  now = 0,
  holdMs = HOLD_MS,
} = {}) {
  if (visibilityState === "visible") {
    if (Number.isFinite(lastPingAt) && now - lastPingAt < holdMs) {
      return "acquire"
    }
    return "none"
  }
  return "release"
}

/**
 * Plan for a single activity ping: whether to arm listeners / timers and
 * whether an acquire attempt should run now.
 */
export function wakeLockPingPlan({
  supported = false,
  preferredSurface = false,
  hasSentinel = false,
  visibilityState = "visible",
  holdMs = HOLD_MS,
} = {}) {
  if (!shouldHandleWakeLockPing({supported, preferredSurface})) {
    return {act: false, acquire: false, scheduleReleaseMs: null}
  }

  return {
    act: true,
    acquire: shouldAcquireWakeLock({hasSentinel, visibilityState}),
    scheduleReleaseMs: holdMs,
  }
}
