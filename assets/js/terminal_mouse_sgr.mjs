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
