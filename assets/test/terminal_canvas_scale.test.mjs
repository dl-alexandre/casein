import assert from "node:assert/strict"
import test from "node:test"

import {preIsScaled, releaseCanvasToDom} from "../js/terminal_canvas_scale.mjs"

// The gate now reads the verdict the layout model published on the hook, rather
// than matching mode strings itself. That hand-kept list never learned about
// "rowpin" and left the canvas painting under a translated frame; deriving it
// from the model means a new mode cannot forget to declare itself. See
// terminal_layout_contract.test.mjs I6 for the end-to-end wiring.
const hookWith = (canvasSafe) => ({ __canvasSafe: canvasSafe })

test("preIsScaled follows the model's canvasSafe verdict", () => {
  assert.equal(preIsScaled(hookWith(false)), true) // scale / zoom / rowpin
  assert.equal(preIsScaled(hookWith(true)), false) // identity fit
})

test("preIsScaled defaults to safe before the first layout", () => {
  // No transform has been applied yet, so there is nothing to be wrong about.
  assert.equal(preIsScaled(hookWith(undefined)), false)
  assert.equal(preIsScaled({}), false)
  assert.equal(preIsScaled(undefined), false)
})

function preparedHook() {
  return {
    pre: { style: { color: "transparent", backgroundColor: "transparent" } },
    __preCanvasPrepared: true,
    __preSavedColor: "rgb(1, 2, 3)",
    __preSavedBg: "rgb(4, 5, 6)",
    __glyphCanvas: { style: { display: "" } },
    __canvasRows: [[]],
    __canvasCols: 80,
    __canvasLastCells: [[]],
    __canvasLastText: "stale"
  }
}

test("releaseCanvasToDom restores the pre ink, hides the canvas, drops caches", () => {
  const hook = preparedHook()
  releaseCanvasToDom(hook)
  // pre ink restored so the DOM RLE painter's text is visible again
  assert.equal(hook.pre.style.color, "rgb(1, 2, 3)")
  assert.equal(hook.pre.style.backgroundColor, "rgb(4, 5, 6)")
  assert.equal(hook.__preCanvasPrepared, false)
  // stale canvas hidden
  assert.equal(hook.__glyphCanvas.style.display, "none")
  // caches dropped so a later return to "fit" fully repaints the canvas
  assert.equal(hook.__canvasRows, null)
  assert.equal(hook.__canvasCols, null)
  assert.equal(hook.__canvasLastCells, null)
  assert.equal(hook.__canvasLastText, undefined)
})

test("releaseCanvasToDom falls back to empty saved styles", () => {
  const hook = { pre: { style: { color: "transparent", backgroundColor: "x" } }, __preCanvasPrepared: true }
  releaseCanvasToDom(hook)
  assert.equal(hook.pre.style.color, "") // no __preSavedColor -> ""
  assert.equal(hook.pre.style.backgroundColor, "")
})

test("releaseCanvasToDom is idempotent and safe before the pre was prepared", () => {
  const hook = { pre: { style: { color: "rgb(9, 9, 9)", backgroundColor: "" } }, __preCanvasPrepared: false }
  releaseCanvasToDom(hook)
  // not prepared -> leaves the pre's own color untouched
  assert.equal(hook.pre.style.color, "rgb(9, 9, 9)")
  assert.doesNotThrow(() => releaseCanvasToDom(hook)) // no canvas, no throw
})
