import assert from "node:assert/strict"
import test from "node:test"

import {
  copyOnSelectText,
  normalizeCellSelection,
  selectedTextFromRows
} from "../js/terminal_cell_selection.mjs"

function cell(ch) {
  return [ch]
}

function row(text) {
  return [...text].map(cell)
}

test("normalizeCellSelection returns null for empty or missing endpoints", () => {
  assert.equal(normalizeCellSelection(null, { row: 0, col: 1 }), null)
  assert.equal(normalizeCellSelection({ row: 0, col: 1 }, null), null)
  assert.equal(normalizeCellSelection({ row: 2, col: 3 }, { row: 2, col: 3 }), null)
})

test("normalizeCellSelection orders reverse drags", () => {
  assert.deepEqual(
    normalizeCellSelection({ row: 1, col: 5 }, { row: 0, col: 2 }),
    { start: { row: 0, col: 2 }, end: { row: 1, col: 5 } }
  )
  assert.deepEqual(
    normalizeCellSelection({ row: 0, col: 8 }, { row: 0, col: 3 }),
    { start: { row: 0, col: 3 }, end: { row: 0, col: 8 } }
  )
})

test("selectedTextFromRows extracts a single-line range inclusive of end col", () => {
  const rows = [row("hello world")]
  assert.equal(
    selectedTextFromRows(rows, 11, { row: 0, col: 0 }, { row: 0, col: 4 }),
    "hello"
  )
  assert.equal(
    selectedTextFromRows(rows, 11, { row: 0, col: 6 }, { row: 0, col: 10 }),
    "world"
  )
})

test("selectedTextFromRows joins multi-line ranges and trims trailing spaces", () => {
  const rows = [row("abc   "), row("de f  "), row("ghi   ")]
  assert.equal(
    selectedTextFromRows(rows, 6, { row: 0, col: 1 }, { row: 2, col: 1 }),
    "bc\nde f\ngh"
  )
})

test("selectedTextFromRows returns empty string for a click (no drag)", () => {
  const rows = [row("path/to/file.ex")]
  assert.equal(
    selectedTextFromRows(rows, 15, { row: 0, col: 4 }, { row: 0, col: 4 }),
    ""
  )
})

test("selectedTextFromRows fills missing cells with spaces", () => {
  const rows = [[cell("a"), cell("b")]]
  assert.equal(
    selectedTextFromRows(rows, 5, { row: 0, col: 0 }, { row: 0, col: 4 }),
    "ab"
  )
})

test("copyOnSelectText only accepts non-empty strings", () => {
  assert.equal(copyOnSelectText(""), null)
  assert.equal(copyOnSelectText(null), null)
  assert.equal(copyOnSelectText(undefined), null)
  assert.equal(copyOnSelectText("ok"), "ok")
  assert.equal(copyOnSelectText("line\nline"), "line\nline")
})
