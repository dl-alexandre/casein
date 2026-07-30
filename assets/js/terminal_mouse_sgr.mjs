// Pure SGR mouse helpers for PTY wheel encoding.
//
// Programs in the alternate screen (Grok, Claude Code, tmux copy-mode, …)
// receive scroll as SGR mouse-wheel reports. Coordinates are 1-based cells;
// the pane under the cursor is how multi-pane TUIs route scroll.

/** Wheel up / down button codes in SGR extended mouse (1006). */
export const SGR_WHEEL_UP = 64
export const SGR_WHEEL_DOWN = 65

/**
 * Encode a wheel delta as one or more SGR mouse reports.
 *
 * @param {number} deltaY browser wheel deltaY (negative = up / toward history)
 * @param {number} col 0-based cell column under the pointer
 * @param {number} row 0-based cell row under the pointer
 * @returns {string} CSI sequence(s) ready to write to the PTY
 */
export function sgrWheelSequence(deltaY, col = 0, row = 0) {
  if (!Number.isFinite(deltaY) || deltaY === 0) return ""

  const steps = Math.max(1, Math.min(8, Math.ceil(Math.abs(deltaY) / 40)))
  const btn = deltaY < 0 ? SGR_WHEEL_UP : SGR_WHEEL_DOWN
  const c = Math.max(1, Math.floor(Number(col) || 0) + 1)
  const r = Math.max(1, Math.floor(Number(row) || 0) + 1)

  let seq = ""
  for (let i = 0; i < steps; i += 1) seq += `\x1b[<${btn};${c};${r}M`
  return seq
}

/**
 * Whether the running program has enabled mouse tracking (any DECSET mode
 * that Ghostty reports as `mouse.tracking`).
 */
export function mouseTrackingActive(mouse) {
  return Boolean(mouse?.tracking)
}

/**
 * Whether a *drag* can mean anything to the running program — i.e. it asked for
 * motion reports via DECSET 1002 (button-event) or 1003 (any-event).
 *
 * A program that only set 1000 (normal) or 9 (x10) hears about presses and
 * releases and never about motion, so a drag inside it is dead input: the most
 * it can produce is a press at one cell and a release at another. Claude Code
 * is one of these — it sets 1000 + 1006 and neither 1002 nor 1003 — which is
 * why a plain drag there is free to drive local selection, while tmux with
 * `mouse on` (1002/1003, where drag means copy-mode select or pane-border
 * resize) still owns its drags.
 *
 * `tracking` alone is too coarse for this question: it is true for every mode.
 */
export function dragReachesProgram(mouse) {
  return Boolean(mouse?.button || mouse?.any)
}

/**
 * Whether a *click* can mean anything to the running program. Every tracking
 * mode reports press/release, so this is the umbrella `tracking` flag — named
 * for the question it answers at the call site.
 */
export function clickReachesProgram(mouse) {
  return mouseTrackingActive(mouse)
}

/**
 * Map a browser point onto a terminal cell when the grid is CSS-scaled.
 *
 * `cellWidth` comes from a DOM measurement inside the transformed frame, so it
 * is already scaled. Computed line-height and padding remain unscaled CSS
 * values. Normalize both axes into the grid's coordinate space before deriving
 * the cell; otherwise a half-scale pane sends a click on visible row 20 to row
 * 10 in the foreground TUI.
 */
export function terminalCellFromClientPoint({
  clientX,
  clientY,
  rectLeft,
  rectTop,
  cellWidth,
  cellHeight,
  paddingLeft = 0,
  paddingTop = 0,
  scale = 1,
  cols = 1,
  rows = 1
}) {
  const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1
  const renderedCellWidth = Number.isFinite(cellWidth) && cellWidth > 0 ? cellWidth : 1
  const unscaledCellHeight =
    Number.isFinite(cellHeight) && cellHeight > 0 ? cellHeight : 1
  const unscaledCellWidth = renderedCellWidth / safeScale
  const x = (clientX - rectLeft) / safeScale - paddingLeft
  const y = (clientY - rectTop) / safeScale - paddingTop
  const maxCol = Math.max(0, Math.floor(cols) - 1)
  const maxRow = Math.max(0, Math.floor(rows) - 1)

  return {
    col: Math.max(0, Math.min(maxCol, Math.floor(x / unscaledCellWidth))),
    row: Math.max(0, Math.min(maxRow, Math.floor(y / unscaledCellHeight)))
  }
}

/**
 * Payload for a structured "mouse" LiveView event at a given cell, matching the
 * vendor pushMouseEvent shape. x/y encode the cell as col*10+5 / row*20+10
 * (the vendor's pixel-in-cell convention); the server re-derives the cell and
 * emits the escape bytes for the app's actual mouse mode (1000/1006/1015/…),
 * so a synthesized tap-click is encoded exactly like a real desktop click.
 *
 * @param {"press"|"release"|"motion"} action
 * @param {number} col 0-based cell column
 * @param {number} row 0-based cell row
 * @param {"left"|"middle"|"right"} [button]
 */
export function mouseReportPayload(action, col, row, button = "left") {
  const c = Math.max(0, Math.floor(Number(col) || 0))
  const r = Math.max(0, Math.floor(Number(row) || 0))
  return {
    action,
    button,
    x: c * 10 + 5,
    y: r * 20 + 10,
    shiftKey: false,
    ctrlKey: false,
    altKey: false,
    metaKey: false
  }
}
