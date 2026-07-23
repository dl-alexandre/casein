// Interactive window-switch swipe — pure geometry.
//
// A single-finger horizontal drag over the workspace switches to the adjacent
// tmux window (WorkspaceLeader dispatches next/prev-window). The drag is
// interactive: an edge bar grows on the side you pull toward and, once you've
// pulled past the commit threshold, releasing switches windows. This module is
// the pure math so it can be unit-tested without the DOM.
//
// Axis lock: the gesture only commits horizontal once |dx| clearly leads |dy|
// AND clears `startPx` — vertical-dominant drags stay with the terminal (one
// finger scrolls the buffer, two fingers scroll scrollback).

/**
 * @param {number} dx  signed horizontal travel (px; negative = leftward)
 * @param {number} dy  signed vertical travel (px)
 * @param {{threshold?: number, startPx?: number}} [opts]
 * @returns {{
 *   axis: "h" | "v" | null,   // committed gesture axis (null = undecided)
 *   dir: "next" | "prev" | null,
 *   edge: "left" | "right" | null, // which edge the affordance hugs
 *   progress: number,         // 0..1 toward the commit threshold
 *   ready: boolean            // pulled far enough to commit on release
 * }}
 */
export function swipeWindowProgress(dx, dy, opts = {}) {
  const threshold = opts.threshold > 0 ? opts.threshold : 120
  const startPx = opts.startPx > 0 ? opts.startPx : 12

  const adx = Math.abs(dx)
  const ady = Math.abs(dy)

  // Vertical-dominant, or too small to decide → not our gesture (yet).
  if (adx < startPx || adx <= ady) {
    // If it's already clearly vertical, lock it out so a later horizontal
    // wobble can't hijack a scroll.
    const axis = ady > startPx && ady > adx ? "v" : null
    return {axis, dir: null, edge: null, progress: 0, ready: false}
  }

  // Pull left (dx<0) → next window, bar on the left edge (the side you pull
  // toward, matching the direction of travel). Pull right → prev, right edge.
  const dir = dx < 0 ? "next" : "prev"
  const edge = dx < 0 ? "left" : "right"
  const progress = Math.max(0, Math.min(1, adx / threshold))
  return {axis: "h", dir, edge, progress, ready: progress >= 1}
}

/**
 * Resolve the commit threshold in px from the viewport width, clamped to a
 * comfortable thumb-travel range. Kept pure (width passed in) for testing.
 */
export function swipeThresholdPx(viewportWidthPx) {
  const w = viewportWidthPx > 0 ? viewportWidthPx : 360
  return Math.max(90, Math.min(160, Math.round(w * 0.32)))
}
