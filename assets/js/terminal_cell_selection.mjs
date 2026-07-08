// Pure helpers for desktop terminal cell selection.
//
// ghostty_terminal.js owns the DOM overlay, mouse handlers, and clipboard
// writes. This module keeps geometry → text logic testable without a hook.

/**
 * Normalize an unordered anchor/focus pair into {start, end}.
 * Returns null when either endpoint is missing or the selection is empty
 * (same cell — a click, not a drag).
 */
export function normalizeCellSelection(anchor, focus) {
  if (!anchor || !focus) return null

  if (focus.row < anchor.row || (focus.row === anchor.row && focus.col < anchor.col)) {
    return { start: focus, end: anchor }
  }

  if (anchor.row === focus.row && anchor.col === focus.col) return null

  return { start: anchor, end: focus }
}

/**
 * Plain text for a cell selection over rowsData[row][col] = [char, ...].
 * End column is inclusive (matches the selection overlay width).
 * Trailing spaces are stripped per line; lines join with "\n".
 */
export function selectedTextFromRows(rowsData, cols, anchor, focus) {
  const selection = normalizeCellSelection(anchor, focus)
  if (!selection) return ""

  const lines = []
  const safeCols = Number.isFinite(cols) ? cols : 0
  const rows = Array.isArray(rowsData) ? rowsData : []

  for (let row = selection.start.row; row <= selection.end.row; row += 1) {
    const sourceRow = rows[row] || []
    const startCol = row === selection.start.row ? selection.start.col : 0
    const endCol = row === selection.end.row ? selection.end.col : Math.max(0, safeCols - 1)
    let text = ""

    for (let col = startCol; col <= endCol; col += 1) {
      text += sourceRow[col]?.[0] || " "
    }

    lines.push(text.trimEnd())
  }

  return lines.join("\n")
}

/**
 * Whether mouseup should write the clipboard for copy-on-select.
 * Empty / non-string selections never copy (plain click, zero-width drag).
 */
export function copyOnSelectText(text) {
  if (typeof text !== "string" || text.length === 0) return null
  return text
}
