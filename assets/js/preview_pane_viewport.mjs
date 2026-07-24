// Pure helpers for the preview pane's locked-viewport ("device frame") mode.
//
// A preview registration may carry a viewport (`WxH`, e.g. a phone's 390x844).
// When it does, the iframe is sized to those exact CSS pixels and scaled down to
// letterbox into whatever the tmux pane happens to be — so the embedded app
// lays out at a real device width instead of the pane's width.
//
// Scaling is growth-free on purpose: a viewport smaller than the pane renders
// 1:1 and sits in the corner rather than being blown up, so what you see is the
// device's own pixel grid. Everything the viewer reports back to the server
// (snapshot click coordinates) must be divided by the same scale, which is why
// the scale and the bounds check live here next to each other rather than being
// re-derived at each call site.

const VIEWPORT_PATTERN = /^(\d+)x(\d+)$/i

// Parses the `WxH` attribute form. Returns null for anything else — an absent,
// empty, or malformed value all mean "no locked viewport", i.e. fit the pane.
export function parseViewport(raw) {
  if (!raw) return null

  const match = String(raw).match(VIEWPORT_PATTERN)
  if (!match) return null

  const width = Number(match[1])
  const height = Number(match[2])
  if (!width || !height) return null

  return {width, height}
}

// Factor the viewport box is multiplied by to fit the available area. Capped at
// 1: we shrink to fit, never magnify. Returns 1 when there is nothing to scale
// or the area has not been laid out yet (clientWidth/Height still 0).
export function viewportScale(viewport, availableWidth, availableHeight) {
  if (!viewport?.width || !viewport?.height) return 1
  if (!availableWidth || !availableHeight) return 1

  return Math.min(1, availableWidth / viewport.width, availableHeight / viewport.height)
}

// The clip/iframe style pair for a given viewport. With no viewport the iframe
// simply fills the pane; with one it becomes a fixed-pixel box pinned to the
// top-left of the clip and scaled from that origin.
export function viewportFrameStyles(viewport, scale) {
  const clip = {overflow: "hidden", width: "100%", height: "100%"}

  if (!viewport) {
    return {
      clip,
      iframe: {
        width: "100%",
        height: "100%",
        border: "0",
        transform: "none",
        transformOrigin: "0 0",
      },
    }
  }

  return {
    clip,
    iframe: {
      width: `${viewport.width}px`,
      height: `${viewport.height}px`,
      border: "0",
      transform: scale < 1 ? `scale(${scale})` : "none",
      transformOrigin: "0 0",
    },
  }
}

// Whether an unscaled point falls inside the locked viewport. Mirrors the
// server's own guard (Casein.PreviewPanes.ensure_inside_viewport/3) so an
// out-of-frame click in the letterbox margin is dropped before it is sent.
// With no locked viewport every point is in bounds; the pane is the frame.
export function withinViewport(viewport, x, y) {
  if (!viewport) return true

  return x >= 0 && y >= 0 && x < viewport.width && y < viewport.height
}
