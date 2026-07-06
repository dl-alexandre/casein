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
