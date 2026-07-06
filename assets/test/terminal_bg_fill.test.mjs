import assert from "node:assert/strict"
import test from "node:test"

import {backgroundLeadingPad} from "../js/terminal_bg_fill.mjs"

test("pads each side by the half-leading, bottom overlapped by half a pixel", () => {
  assert.deepEqual(backgroundLeadingPad(19.5, 15.5), {top: 2, bottom: 2.5})
  assert.deepEqual(backgroundLeadingPad(17, 15), {top: 1, bottom: 1.5})
})

test("rounds pads to hundredths of a pixel", () => {
  assert.deepEqual(backgroundLeadingPad(17, 15.333), {top: 0.83, bottom: 1.33})
})

test("no pad when the content box already fills the line box", () => {
  assert.equal(backgroundLeadingPad(15, 15), null)
  assert.equal(backgroundLeadingPad(14, 15), null)
})

test("no pad without usable measurements", () => {
  assert.equal(backgroundLeadingPad(0, 15), null)
  assert.equal(backgroundLeadingPad(17, 0), null)
  assert.equal(backgroundLeadingPad(NaN, 15), null)
  assert.equal(backgroundLeadingPad(17, NaN), null)
})
