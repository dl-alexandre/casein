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
