// Cell flag bits emitted by Ghostty.Terminal cell payloads.
export const BOLD = 1
export const ITALIC = 2
export const FAINT = 4
export const UNDERLINE = 8
export const STRIKE = 16
export const INVERSE = 32
export const OVERLINE = 128

export const TEXT_DECORATION_FLAGS = UNDERLINE | STRIKE | OVERLINE

export function visibleCellChar(char) {
  return Boolean(char && char.trim() !== "")
}

// Full-screen TUIs can mark blank padding cells as decorated. CSS decorations
// over coalesced whitespace become row-wide rules, so keep style flags that
// affect colors/weight but drop text decorations from invisible cells.
export function effectiveCellFlags(char, flags) {
  if (!flags) return 0
  if (visibleCellChar(char)) return flags
  return flags & ~TEXT_DECORATION_FLAGS
}

/**
 * Resolve painted fg/bg for a cell, applying the inverse (reverse video) flag.
 * Defaults fill missing sides so reverse on unstyled cells still paints.
 *
 * @param {number[]|null|undefined} fg
 * @param {number[]|null|undefined} bg
 * @param {number} flags
 * @param {number[]|null|undefined} defaultFg
 * @param {number[]|null|undefined} defaultBg
 * @returns {{fg: number[]|null|undefined, bg: number[]|null|undefined}}
 */
export function resolveInverseColors(fg, bg, flags, defaultFg = null, defaultBg = null) {
  if (!(flags & INVERSE)) return {fg, bg}

  return {
    fg: bg || defaultBg || null,
    bg: fg || defaultFg || null
  }
}
