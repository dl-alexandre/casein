// Scale-to-fit guard for the canvas terminal renderer.
//
// The glyph canvas is a sibling of the <pre> (see ensureCanvas), so it does NOT
// inherit the pre's scale-to-fit `transform` (applyScaledLayout in
// ghostty_terminal.js). The canvas draws glyphs at *unscaled* cell metrics, so
// a non-authoritative "scale" observer — or a user "zoom" — would paint the
// grid oversized and clipped (the top-left cells fill the viewport, the rest
// runs off the right/bottom edge; mid-resize it composites old+new pixels into
// a mash). The DOM RLE painter has no such problem: the transform applies to
// the pre's own text, so it scales correctly. So the canvas fast-path is only
// safe in the identity "fit" mode; every other display mode is handed back to
// the DOM renderer.

// True while the pane is CSS-transformed to fit its viewport ("scale" observer
// or user "zoom"). Only "fit" (and the unset initial state) is safe for canvas.
export function preIsScaled(hook) {
  const mode = hook?.el?.dataset?.displayMode
  return mode === "scale" || mode === "zoom"
}

// Hand rendering back to the DOM RLE painter: restore the pre's ink (undo
// prepareTransparentPre), hide the stale canvas, and drop the paint caches so
// re-entering "fit" mode repaints the canvas from scratch. Idempotent.
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
