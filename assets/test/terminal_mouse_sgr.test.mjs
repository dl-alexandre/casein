import assert from "node:assert/strict"
import test from "node:test"

import {
  SGR_WHEEL_DOWN,
  SGR_WHEEL_UP,
  mouseReportPayload,
  mouseTrackingActive,
  sgrWheelSequence,
  terminalCellFromClientPoint
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

test("terminalCellFromClientPoint maps CSS-scaled clicks to the visible TUI cell", () => {
  assert.deepEqual(
    terminalCellFromClientPoint({
      clientX: 84,
      clientY: 210,
      rectLeft: 20,
      rectTop: 10,
      cellWidth: 4,
      cellHeight: 20,
      paddingLeft: 8,
      paddingTop: 8,
      scale: 0.5,
      cols: 80,
      rows: 40
    }),
    {col: 15, row: 19}
  )
})

test("terminalCellFromClientPoint preserves unscaled mapping and clamps to the grid", () => {
  assert.deepEqual(
    terminalCellFromClientPoint({
      clientX: 999,
      clientY: -50,
      rectLeft: 0,
      rectTop: 0,
      cellWidth: 8,
      cellHeight: 20,
      cols: 80,
      rows: 24
    }),
    {col: 79, row: 0}
  )
})

test("mouseReportPayload encodes the cell like the vendor pushMouseEvent", () => {
  // col*10+5 / row*20+10 is the vendor's pixel-in-cell convention the server
  // decodes back to a cell; a tap-click must match a real desktop click.
  assert.deepEqual(mouseReportPayload("press", 3, 7), {
    action: "press",
    button: "left",
    x: 35,
    y: 150,
    shiftKey: false,
    ctrlKey: false,
    altKey: false,
    metaKey: false
  })
  assert.equal(mouseReportPayload("release", 0, 0).x, 5)
  assert.equal(mouseReportPayload("release", 0, 0).y, 10)
})

test("mouseReportPayload clamps invalid coords to the origin cell", () => {
  const p = mouseReportPayload("press", -4, NaN)
  assert.equal(p.x, 5)
  assert.equal(p.y, 10)
})
