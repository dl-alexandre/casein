import assert from "node:assert/strict"
import test from "node:test"

import {
  SGR_WHEEL_DOWN,
  SGR_WHEEL_UP,
  mouseTrackingActive,
  sgrWheelSequence
} from "../js/terminal_mouse_sgr.mjs"

test("sgrWheelSequence uses 1-based cell under the pointer", () => {
  // col=40,row=10 → CSI 41;11 so multi-pane TUIs scroll the right pane
  assert.equal(sgrWheelSequence(-40, 40, 10), `\x1b[<${SGR_WHEEL_UP};41;11M`)
  assert.equal(sgrWheelSequence(40, 40, 10), `\x1b[<${SGR_WHEEL_DOWN};41;11M`)
})

test("sgrWheelSequence never falls back to a hard-coded (1,1) corner", () => {
  const seq = sgrWheelSequence(-1, 5, 12)
  assert.match(seq, /;6;13M$/)
  assert.doesNotMatch(seq, /;1;1M/)
})

test("sgrWheelSequence clamps invalid coords to the origin cell", () => {
  assert.equal(sgrWheelSequence(-40, -3, NaN), `\x1b[<${SGR_WHEEL_UP};1;1M`)
  assert.equal(sgrWheelSequence(40), `\x1b[<${SGR_WHEEL_DOWN};1;1M`)
})

test("sgrWheelSequence steps scale with delta magnitude, capped at 8", () => {
  assert.equal(sgrWheelSequence(-1, 0, 0).split("M").length - 1, 1)
  assert.equal(sgrWheelSequence(-200, 0, 0).split("M").length - 1, 5)
  assert.equal(sgrWheelSequence(-10_000, 0, 0).split("M").length - 1, 8)
})

test("sgrWheelSequence is empty for zero/non-finite deltas", () => {
  assert.equal(sgrWheelSequence(0, 1, 1), "")
  assert.equal(sgrWheelSequence(NaN, 1, 1), "")
})

test("mouseTrackingActive mirrors Ghostty mouse payload", () => {
  assert.equal(mouseTrackingActive(null), false)
  assert.equal(mouseTrackingActive({}), false)
  assert.equal(mouseTrackingActive({tracking: false}), false)
  assert.equal(mouseTrackingActive({tracking: true}), true)
})
