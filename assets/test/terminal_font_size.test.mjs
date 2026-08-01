import assert from "node:assert/strict"
import test from "node:test"

import {
  DEFAULT_TERMINAL_FONT_PX,
  MAX_TERMINAL_FONT_PX,
  MIN_TERMINAL_FONT_PX,
  clampFontSize,
  lineHeightFor,
  nextFontSize,
  storedFontSize
} from "../js/terminal_font_size.mjs"

test("the default reproduces what the grid rendered before the variable was read", () => {
  // `text-sm` on the terminal container, and the 17px line-height the old
  // 13 × 1.31 landed on. Both must survive the fix untouched.
  assert.equal(DEFAULT_TERMINAL_FONT_PX, 14)
  assert.equal(lineHeightFor(DEFAULT_TERMINAL_FONT_PX), 17)
})

test("A+ and A− move one pixel at a time and carry the leading with them", () => {
  assert.equal(nextFontSize(14, 1), 15)
  assert.equal(lineHeightFor(15), 18)
  assert.equal(nextFontSize(14, -1), 13)
  assert.equal(lineHeightFor(13), 16)
})

test("stepping stops at the ends instead of running off", () => {
  assert.equal(nextFontSize(MAX_TERMINAL_FONT_PX, 1), MAX_TERMINAL_FONT_PX)
  assert.equal(nextFontSize(MIN_TERMINAL_FONT_PX, -1), MIN_TERMINAL_FONT_PX)
})

test("a missing or corrupt stored value falls back to the default", () => {
  assert.equal(storedFontSize(null), DEFAULT_TERMINAL_FONT_PX)
  assert.equal(storedFontSize(""), DEFAULT_TERMINAL_FONT_PX)
  assert.equal(storedFontSize("not-a-number"), DEFAULT_TERMINAL_FONT_PX)
  assert.equal(storedFontSize("16"), 16)
})

test("a stored value outside the range is pulled back in", () => {
  assert.equal(storedFontSize("400"), MAX_TERMINAL_FONT_PX)
  assert.equal(storedFontSize("-3"), MIN_TERMINAL_FONT_PX)
})

test("clampFontSize keeps whole pixels — fractional cells blur the grid", () => {
  assert.equal(clampFontSize(14.4), 14)
  assert.equal(clampFontSize(14.6), 15)
  assert.equal(clampFontSize(NaN), DEFAULT_TERMINAL_FONT_PX)
})

test("every size in range yields a line-height taller than the glyph", () => {
  for (let px = MIN_TERMINAL_FONT_PX; px <= MAX_TERMINAL_FONT_PX; px++) {
    assert.ok(lineHeightFor(px) > px, `line-height must exceed font-size at ${px}px`)
  }
})
