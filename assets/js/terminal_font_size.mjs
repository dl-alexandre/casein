// Terminal font size — the numbers behind the A− / A+ controls in the ⋯ menu
// and the mobile keybar.
//
// These used to move `--casein-terminal-line-height` alone: `--casein-font-size`
// was published but no rule and no hook ever read it, so the <pre> kept the
// `text-sm` (14px) it inherited from its container and only the leading grew or
// shrank. "Smaller text" made the rows tighter, never the glyphs smaller. The
// pre now takes its font-size from the variable too, so the defaults here have
// to reproduce what that container was already rendering.

// `text-sm` on the terminal container — the size the grid has always painted.
export const DEFAULT_TERMINAL_FONT_PX = 14
export const MIN_TERMINAL_FONT_PX = 8
export const MAX_TERMINAL_FONT_PX = 24

// 14 × 1.21 = 17px, the line-height the terminal already ran at (the old ×1.31
// off a 13px base landed on the same 17px). Keeping the product identical is
// what makes this fix invisible until someone actually presses a button.
export const TERMINAL_LINE_HEIGHT_RATIO = 1.21

// New key on purpose. The old "casein:font-size" recorded a leading-only
// preference — a stored 9 meant "tighter rows", not "9px glyphs" — so honouring
// it now would shrink the text of anyone who ever tapped A− on mobile.
export const TERMINAL_FONT_STORAGE_KEY = "casein:terminal-font-size"

export function clampFontSize(px) {
  if (!Number.isFinite(px)) return DEFAULT_TERMINAL_FONT_PX
  return Math.max(MIN_TERMINAL_FONT_PX, Math.min(MAX_TERMINAL_FONT_PX, Math.round(px)))
}

// Parses whatever localStorage handed back (string, null, garbage).
export function storedFontSize(raw) {
  const parsed = parseInt(raw, 10)
  return Number.isNaN(parsed) ? DEFAULT_TERMINAL_FONT_PX : clampFontSize(parsed)
}

export function nextFontSize(current, delta) {
  return clampFontSize(storedFontSize(current) + (Number.isFinite(delta) ? delta : 0))
}

export function lineHeightFor(px) {
  return Math.round(clampFontSize(px) * TERMINAL_LINE_HEIGHT_RATIO)
}
