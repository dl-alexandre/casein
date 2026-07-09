import assert from "node:assert/strict"
import test from "node:test"

import {BOLD, INVERSE, resolveInverseColors} from "../js/terminal_cell_flags.mjs"

test("resolveInverseColors is a no-op without the inverse flag", () => {
  assert.deepEqual(resolveInverseColors([1, 2, 3], [4, 5, 6], BOLD), {
    fg: [1, 2, 3],
    bg: [4, 5, 6]
  })
})

test("resolveInverseColors swaps fg/bg for reverse video", () => {
  assert.deepEqual(resolveInverseColors([10, 20, 30], [40, 50, 60], INVERSE), {
    fg: [40, 50, 60],
    bg: [10, 20, 30]
  })
})

test("resolveInverseColors fills missing sides from terminal defaults", () => {
  assert.deepEqual(
    resolveInverseColors(null, null, INVERSE, [255, 255, 255], [0, 0, 0]),
    {fg: [0, 0, 0], bg: [255, 255, 255]}
  )
  assert.deepEqual(
    resolveInverseColors([1, 1, 1], null, INVERSE, [9, 9, 9], [2, 2, 2]),
    {fg: [2, 2, 2], bg: [1, 1, 1]}
  )
})
