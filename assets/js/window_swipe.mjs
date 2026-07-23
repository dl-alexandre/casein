// Interactive window-switch swipe — pure geometry.
//
// A single-finger horizontal drag over the workspace switches to the adjacent
// tmux window (WorkspaceLeader dispatches next/prev-window). The drag is
// interactive: a full-height edge bar — labelled with the adjacent window it
// will switch to — grows on the edge that window slides IN from, and once
// you've pulled past the commit threshold (or flicked fast enough) releasing
// switches windows. This module is the pure math so it can be unit-tested
// without the DOM.
//
// Reveal-from-opposite-edge: matching native paging (iOS tabs, photo
// galleries), a leftward pull advances to the NEXT window, which enters from
// the RIGHT edge — so the affordance hugs the edge opposite the finger, not the
// side you pull toward.
//
// Axis lock: the gesture only commits horizontal once |dx| clearly leads |dy|
// AND clears `startPx` — vertical-dominant drags stay with the terminal (one
// finger scrolls the buffer, two fingers scroll scrollback).

/**
 * @param {number} dx  signed horizontal travel (px; negative = leftward)
 * @param {number} dy  signed vertical travel (px)
 * @param {{threshold?: number, startPx?: number, velocity?: number,
 *          flickVelocity?: number, flickMinProgress?: number}} [opts]
 *   velocity is signed horizontal speed (px/ms) of the last move; a fast flick
 *   in the gesture direction commits before full travel is reached.
 * @returns {{
 *   axis: "h" | "v" | null,   // committed gesture axis (null = undecided)
 *   dir: "next" | "prev" | null,
 *   edge: "left" | "right" | null, // which edge the affordance hugs (incoming side)
 *   progress: number,         // 0..1 toward the commit threshold
 *   ready: boolean,           // pulled/flicked far enough to commit on release
 *   flick: boolean            // ready was reached by velocity, not distance
 * }}
 */
export function swipeWindowProgress(dx, dy, opts = {}) {
  const threshold = opts.threshold > 0 ? opts.threshold : 120
  const startPx = opts.startPx > 0 ? opts.startPx : 12
  const velocity = Number.isFinite(opts.velocity) ? opts.velocity : 0
  const flickVelocity = opts.flickVelocity > 0 ? opts.flickVelocity : 0.5
  const flickMinProgress = opts.flickMinProgress > 0 ? opts.flickMinProgress : 0.4

  const adx = Math.abs(dx)
  const ady = Math.abs(dy)

  // Vertical-dominant, or too small to decide → not our gesture (yet).
  if (adx < startPx || adx <= ady) {
    // If it's already clearly vertical, lock it out so a later horizontal
    // wobble can't hijack a scroll.
    const axis = ady > startPx && ady > adx ? "v" : null
    return {axis, dir: null, edge: null, progress: 0, ready: false, flick: false}
  }

  // Pull left (dx<0) → NEXT window, which slides in from the RIGHT edge.
  // Pull right (dx>0) → PREV window, entering from the LEFT edge.
  const dir = dx < 0 ? "next" : "prev"
  const edge = dx < 0 ? "right" : "left"
  const progress = Math.max(0, Math.min(1, adx / threshold))
  // A fast flick in the gesture's own direction commits before full travel.
  const flick =
    progress >= flickMinProgress &&
    Math.abs(velocity) >= flickVelocity &&
    Math.sign(velocity) === Math.sign(dx)
  return {axis: "h", dir, edge, progress, ready: progress >= 1 || flick, flick}
}

/**
 * Resolve the commit threshold in px from the viewport width, clamped to a
 * comfortable thumb-travel range. Kept pure (width passed in) for testing.
 */
export function swipeThresholdPx(viewportWidthPx) {
  const w = viewportWidthPx > 0 ? viewportWidthPx : 360
  return Math.max(90, Math.min(160, Math.round(w * 0.32)))
}
