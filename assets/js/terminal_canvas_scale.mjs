// Canvas-renderer gate.
//
// The glyph canvas is drawn at *unscaled* cell metrics, so it is only correct
// while the frame carries no transform. Under a scaled observer, a user zoom,
// or a row-pin scroll it would paint the grid in the wrong place (the top-left
// cells fill the viewport and the rest runs off the edge; mid-resize it
// composites old and new pixels into a mash). The DOM RLE painter has no such
// problem — the transform applies to the pre's own text — so every non-identity
// mode is handed back to it.
//
// This USED to be a hand-kept list of mode strings living next to the painter.
// It was written before row-pinning existed and never grew, so row-pinned
// viewers kept the canvas engaged while the frame was translated. The decision
// now comes from the layout model (`canvasSafe`), stashed on the hook by
// applyLayoutResult, so a new mode cannot forget to declare itself.

// True while the pane is transformed and the canvas must not paint. Defaults to
// safe: before the first layout there is no transform to be wrong about.
export function preIsScaled(hook) {
  return hook?.__canvasSafe === false
}

// Hand rendering back to the DOM RLE painter: restore the pre's ink (undo
// prepareTransparentPre), hide the stale canvas, and drop the paint caches so
// re-entering an identity mode repaints the canvas from scratch. Idempotent.
export function releaseCanvasToDom(hook) {
  const pre = hook.pre
  if (hook.__preCanvasPrepared && pre) {
    pre.style.color = hook.__preSavedColor ?? ""
    pre.style.backgroundColor = hook.__preSavedBg ?? ""
    hook.__preCanvasPrepared = false
  }
  if (hook.__glyphCanvas) hook.__glyphCanvas.style.display = "none"
  hook.__canvasRows = null
  hook.__canvasCols = null
  hook.__canvasLastCells = null
  hook.__canvasLastText = undefined
}
