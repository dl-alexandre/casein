// Pure helpers for the MobileKeyBar visual-viewport tracker.
//
// The bar pins itself to the bottom of the *visual* viewport (riding above the
// soft keyboard) and publishes --casein-mobile-terminal-inset so the terminal
// shell shortens by keyboard + bar. Two failure modes shaped this module:
//
// - Load flicker: committing a new inset triggers a terminal refit + tmux
//   resize round-trip, so every spurious commit is a visible repaint. Commits
//   must be hysteresis-gated against keyboard-animation jitter.
// - Pinch-zoom: while zoomed, visualViewport geometry reflects the zoom, not a
//   keyboard. Treating that gap as keyboard height crushed the terminal grid
//   and auto-hid the header mid-zoom.

export const KEYBOARD_OPEN_MIN_GAP_PX = 40
export const GAP_JITTER_PX = 2

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
