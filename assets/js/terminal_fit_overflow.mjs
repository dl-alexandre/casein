// Overflow guard for the authoritative "fit" layout path.
//
// The focused viewer sizes the shared tmux grid to its own viewport
// (authoritativeFitToContainer) and renders untransformed, with the <pre>
// pinned inset:0 inside an overflow:hidden container. That assumes tmux always
// obeys the requested size — but the grid can be taller/wider than the fitted
// grid whenever the resize hasn't landed yet or another writer (second client,
// stale instance) resizes the window. authoritativeFitToContainer early-returns
// on `fitUnchanged`, so nothing shrinks the oversize content and the bottom /
// right rows are clipped. This module decides when the authoritative viewer
// should temporarily borrow the observer's scale-to-fit path instead, and when
// to hand back to plain fit/zoom once the grid converges.

// True when the rendered grid exceeds the grid this viewer asked for. Smaller
// grids are fine (normal mount / grow transients render top-left, unclipped).
export function gridOverflowsFit({cols, rows, fitCols, fitRows}) {
  if (!Number.isFinite(fitCols) || !Number.isFinite(fitRows)) return false
  if (!Number.isFinite(cols) || !Number.isFinite(rows)) return false
  return cols > fitCols || rows > fitRows
}

// Decide the layout action for an authoritative viewer after the fit pass:
//   "scale"        — grid overflows the fitted grid: scale-to-fit it.
//   "restore-fit"  — converged back and no user zoom: drop the transform.
//   "restore-zoom" — converged back with a user zoom: reapply zoom layout.
//   null           — nothing to do (steady state).
export function fitOverflowAction({cols, rows, fitCols, fitRows, displayMode, userZoom = 1}) {
  if (gridOverflowsFit({cols, rows, fitCols, fitRows})) return "scale"
  if (displayMode !== "scale") return null
  return userZoom === 1 ? "restore-fit" : "restore-zoom"
}
