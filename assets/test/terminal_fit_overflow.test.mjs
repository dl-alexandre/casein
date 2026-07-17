import assert from "node:assert/strict"
import test from "node:test"

import {fitOverflowAction, gridOverflowsFit} from "../js/terminal_fit_overflow.mjs"

test("gridOverflowsFit flags grids taller or wider than the fitted grid", () => {
  assert.equal(gridOverflowsFit({cols: 212, rows: 51, fitCols: 212, fitRows: 51}), false)
  assert.equal(gridOverflowsFit({cols: 212, rows: 53, fitCols: 212, fitRows: 51}), true)
  assert.equal(gridOverflowsFit({cols: 220, rows: 51, fitCols: 212, fitRows: 51}), true)
  // Smaller grids render top-left without clipping — not an overflow.
  assert.equal(gridOverflowsFit({cols: 80, rows: 24, fitCols: 212, fitRows: 51}), false)
})

test("gridOverflowsFit stays quiet before the first fit or render", () => {
  assert.equal(gridOverflowsFit({cols: 80, rows: 24, fitCols: undefined, fitRows: undefined}), false)
  assert.equal(gridOverflowsFit({cols: NaN, rows: NaN, fitCols: 212, fitRows: 51}), false)
})

test("fitOverflowAction scales while the grid exceeds the fitted grid", () => {
  assert.equal(
    fitOverflowAction({cols: 212, rows: 53, fitCols: 212, fitRows: 51, displayMode: "fit"}),
    "scale"
  )
  // Still oversize on a later pass: keep scaling (idempotent re-apply).
  assert.equal(
    fitOverflowAction({cols: 212, rows: 53, fitCols: 212, fitRows: 51, displayMode: "scale"}),
    "scale"
  )
  // Zoomed viewers get the scale path too; scaleToContainer folds the zoom in.
  assert.equal(
    fitOverflowAction({
      cols: 212,
      rows: 53,
      fitCols: 212,
      fitRows: 51,
      displayMode: "zoom",
      userZoom: 1.5
    }),
    "scale"
  )
})

test("fitOverflowAction restores fit or zoom once the grid converges", () => {
  assert.equal(
    fitOverflowAction({cols: 212, rows: 51, fitCols: 212, fitRows: 51, displayMode: "scale"}),
    "restore-fit"
  )
  assert.equal(
    fitOverflowAction({
      cols: 212,
      rows: 51,
      fitCols: 212,
      fitRows: 51,
      displayMode: "scale",
      userZoom: 1.5
    }),
    "restore-zoom"
  )
})

test("fitOverflowAction is a no-op at steady state", () => {
  assert.equal(
    fitOverflowAction({cols: 212, rows: 51, fitCols: 212, fitRows: 51, displayMode: "fit"}),
    null
  )
  assert.equal(
    fitOverflowAction({
      cols: 212,
      rows: 51,
      fitCols: 212,
      fitRows: 51,
      displayMode: "zoom",
      userZoom: 1.5
    }),
    null
  )
  // Never touches observer state: only the authoritative path calls this, but
  // an unset display mode must not trigger a restore either.
  assert.equal(
    fitOverflowAction({cols: 212, rows: 51, fitCols: 212, fitRows: 51, displayMode: undefined}),
    null
  )
})
