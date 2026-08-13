import assert from "node:assert/strict"
import test from "node:test"

import {cropCellMetrics} from "../js/terminal_layout_model.mjs"

// The mobile focus crop used to translate by a percentage of the surface mount's
// box. That box is not the glyph grid: the grid is quantized to whole cells and
// centered in the remainder, so `box / cols` runs slightly wide and the error
// compounds with the pane's column offset. Measured on a 600px viewport with a
// 69-column window, `(600 - 16) / 69` = 8.4638px against a rendered 8.41px —
// enough to shave 2.3px off the focused pane's first glyph at column 35.
const RENDERED_CELL = {w: 8.41, h: 17}

test("passes the rendered cell size through when nothing is scaled", () => {
  const m = cropCellMetrics({cell: RENDERED_CELL, layoutW: 600, paintedW: 600})

  assert.equal(m.w, 8.41)
  assert.equal(m.h, 17)
})

test("the published cell beats a container-derived one at the pane offset", () => {
  const {w} = cropCellMetrics({cell: RENDERED_CELL, layoutW: 600, paintedW: 600})
  const containerDerived = (600 - 16) / 69

  // What the crop shifts by, at the pane that exposed the bug.
  const shipped = 35 * w
  const old = 35 * containerDerived

  assert.ok(old - shipped > 1.8, `expected the old basis to overshoot, got ${old - shipped}`)
  assert.equal(Number((35 * 8.41).toFixed(2)), Number(shipped.toFixed(2)))
})

test("divides out an ancestor scale so the translate stays in local px", () => {
  // cell.w is read via getBoundingClientRect, so a 2x ancestor scale doubles it.
  // The translate resolves before scale() in the transform list and so must be
  // expressed in unscaled px.
  const m = cropCellMetrics({cell: {w: 16.82, h: 34}, layoutW: 300, paintedW: 600})

  assert.equal(m.w, 8.41)
  assert.equal(m.h, 17)
})

test("treats sub-half-percent deviation as measurement noise, not a transform", () => {
  const m = cropCellMetrics({cell: RENDERED_CELL, layoutW: 600, paintedW: 600.6})

  assert.equal(m.w, 8.41, "a 0.1% rounding wobble must not rescale the cell")
})

test("returns null until the cell is measurable", () => {
  assert.equal(cropCellMetrics({cell: null, layoutW: 600, paintedW: 600}), null)
  assert.equal(cropCellMetrics({cell: {w: 0, h: 17}, layoutW: 600, paintedW: 600}), null)
  assert.equal(cropCellMetrics({cell: {w: 8.41, h: 0}, layoutW: 600, paintedW: 600}), null)
  assert.equal(cropCellMetrics(), null)
})

test("falls back to unscaled when the mount has no measurable box", () => {
  // A pane mounting mid-transition reports 0 width; publishing the raw cell is
  // better than publishing NaN, which would kill the translate entirely.
  const m = cropCellMetrics({cell: RENDERED_CELL, layoutW: 0, paintedW: 0})

  assert.equal(m.w, 8.41)
  assert.equal(m.h, 17)
})
