import assert from "node:assert/strict"
import test from "node:test"

import {
  BOLD,
  INVERSE,
  OVERLINE,
  STRIKE,
  TEXT_DECORATION_FLAGS,
  UNDERLINE,
  effectiveCellFlags,
  visibleCellChar
} from "../js/terminal_cell_flags.mjs"

test("blank cells keep non-decoration flags but drop text decorations", () => {
  const flags = BOLD | INVERSE | TEXT_DECORATION_FLAGS

  assert.equal(effectiveCellFlags(" ", flags), BOLD | INVERSE)
  assert.equal(effectiveCellFlags("", flags), BOLD | INVERSE)
  assert.equal(effectiveCellFlags(null, flags), BOLD | INVERSE)
  assert.equal(effectiveCellFlags("\u00a0", flags), BOLD | INVERSE)
})

test("visible cells keep text decoration flags", () => {
  const flags = BOLD | UNDERLINE | STRIKE | OVERLINE

  assert.equal(effectiveCellFlags("x", flags), flags)
  assert.equal(effectiveCellFlags("─", flags), flags)
  assert.equal(visibleCellChar("─"), true)
})
