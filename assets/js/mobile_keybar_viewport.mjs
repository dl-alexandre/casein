// Pure helpers for the MobileKeyBar visual-viewport tracker.
//
// The bar pins itself to the bottom of the *visual* viewport (riding above the
// soft keyboard) and publishes --casein-mobile-terminal-inset so the terminal
// shell shortens by keyboard + bar. Failure modes that shaped this module:
//
// - Load flicker: committing a new inset triggers a terminal refit + tmux
//   resize round-trip, so every spurious commit is a visible repaint. Commits
//   must be hysteresis-gated against keyboard-animation jitter.
// - Pinch-zoom: while zoomed, visualViewport geometry reflects the zoom, not a
//   keyboard. Treating that gap as keyboard height crushed the terminal grid
//   and auto-hid the header mid-zoom.
// - Soft-keyboard animation: the gap ramps continuously over ~200–300ms. A 2px
//   hysteresis still fires a resize storm (one refit per animation frame). The
//   settle policy keeps the bar pinned live while debouncing the expensive
//   terminal-inset commit until the keyboard stops moving.
// - Android URL-bar collapse: mid-size gaps (above the open threshold but well
//   below a real keyboard) without a focused terminal input are browser chrome,
//   not a soft keyboard — must not auto-hide the header or flip keyboard-open.

export const KEYBOARD_OPEN_MIN_GAP_PX = 40
export const GAP_JITTER_PX = 2
// URL-bar / browser-chrome wobble can produce gaps in this band. Real soft
// keyboards are typically 250–350px; stay conservative so short landscape
// keyboards still count when the terminal input is focused.
export const CHROME_WOBBLE_MAX_GAP_PX = 100
// While the soft keyboard is animating, only commit terminal insets that moved
// by at least this much — plus a settle pass once motion stops. Covers a full
// keyboard open (~300px) in a handful of steps instead of dozens of refits.
export const INSET_ANIMATION_STEP_PX = 28
// Quiet window after the last visualViewport event before writing the exact
// final inset. Long enough to span one keyboard animation frame burst, short
// enough that the terminal snaps to the settled keyboard within a beat.
export const INSET_SETTLE_MS = 120

// Gap between the layout-viewport bottom and the visual-viewport bottom —
// approximately the soft-keyboard height when fixed elements lay out against
// the layout viewport. Returns null when the geometry is unusable: missing
// numbers, or a pinch-zoomed viewport whose gap has nothing to do with any
// keyboard (callers keep the last committed state until zoom returns to 1).
export function keyboardGap({innerHeight, height, offsetTop = 0, scale = 1} = {}) {
  if (!Number.isFinite(innerHeight) || !Number.isFinite(height)) return null
  if (Number.isFinite(scale) && Math.abs(scale - 1) > 0.02) return null
  return Math.max(0, Math.round(innerHeight - (height + (Number.isFinite(offsetTop) ? offsetTop : 0))))
}

export function keyboardOpenForGap(gap) {
  return Number.isFinite(gap) && gap > KEYBOARD_OPEN_MIN_GAP_PX
}

/**
 * Soft-keyboard open decision that ignores Android URL-bar / browser-chrome
 * wobble. A mid-band gap only counts as a keyboard when the terminal input is
 * focused (or we were already open and the gap is still above the open floor).
 */
export function effectiveKeyboardOpen(
  gap,
  {terminalFocused = false, wasOpen = false, wobbleMax = CHROME_WOBBLE_MAX_GAP_PX} = {}
) {
  if (!keyboardOpenForGap(gap)) return false
  if (wasOpen) return true
  if (gap <= wobbleMax && !terminalFocused) return false
  return true
}

// Whether a freshly measured (gap, inset) pair moved far enough from the last
// committed pair to justify a re-commit. The inset term catches bar-height
// changes the gap can't see: rotation shifting the safe-area padding, the
// app-mode class collapsing the bar, chrome-narrow revealing it, font settle.
export function shouldCommitViewportInset({
  gap,
  inset,
  lastGap = null,
  lastInset = null,
  jitter = GAP_JITTER_PX
} = {}) {
  if (!Number.isFinite(gap) || !Number.isFinite(inset)) return false
  if (lastGap == null || lastInset == null) return true
  return Math.abs(gap - lastGap) >= jitter || Math.abs(inset - lastInset) >= jitter
}

/**
 * Decide how to apply a freshly measured (gap, inset) pair.
 *
 * The key bar always tracks the visual viewport live (pin to keyboard). The
 * terminal inset is expensive (refit + possible tmux resize), so during a
 * continuous soft-keyboard animation we either:
 *   - commit immediately on keyboard open/close edges and large jumps
 *     (rotation, URL-bar snap, first paint), or
 *   - commit mid-animation only when the gap crossed another
 *     INSET_ANIMATION_STEP_PX quanta, or
 *   - schedule a settle commit once motion stops (exact final size).
 *
 * Returns:
 *   { pinBar: true,
 *     commitInset: boolean,   // write --casein-mobile-terminal-inset now
 *     settle: boolean,        // schedule a settle pass for the exact size
 *     openChanged: boolean }
 */
export function planViewportCommit({
  gap,
  inset,
  keyboardOpen,
  lastGap = null,
  lastInset = null,
  lastKeyboardOpen = null,
  stepPx = INSET_ANIMATION_STEP_PX,
  settleJitter = GAP_JITTER_PX
} = {}) {
  if (!Number.isFinite(gap) || !Number.isFinite(inset)) {
    return {pinBar: false, commitInset: false, settle: false, openChanged: false}
  }

  // Only a real closed↔open transition counts — first paint must not emit
  // keyboard-open-changed or terminals thrash size authority on mount.
  const openChanged = lastKeyboardOpen != null && keyboardOpen !== lastKeyboardOpen
  const first = lastGap == null || lastInset == null

  // First paint / open-close edge: commit now, no settle lag.
  if (first || openChanged) {
    return {pinBar: true, commitInset: true, settle: false, openChanged}
  }

  const gapDelta = Math.abs(gap - lastGap)
  const insetDelta = Math.abs(inset - lastInset)

  if (gapDelta < settleJitter && insetDelta < settleJitter) {
    return {pinBar: true, commitInset: false, settle: false, openChanged: false}
  }

  // Mid-animation step: commit when we've crossed another quanta so the
  // terminal roughly tracks the keyboard without a per-frame resize storm.
  if (gapDelta >= stepPx || insetDelta >= stepPx) {
    return {pinBar: true, commitInset: true, settle: true, openChanged: false}
  }

  // Small motion (animation sub-step or URL-bar wobble): pin the bar, leave
  // the terminal alone, and settle once quiet.
  return {pinBar: true, commitInset: false, settle: true, openChanged: false}
}
