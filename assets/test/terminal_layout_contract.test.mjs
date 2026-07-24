// The terminal layout CONTRACT — invariants every display mode must preserve.
//
// This subsystem has produced the same class of bug for months (narrow-column
// condense, stranded fit, letterboxed caret, blank-on-keyboard, vanishing right
// column). Each was fixed with another guard on top of the previous layer's
// blind spot, because the pure helpers were well tested but their COMPOSITION
// was not. These tests mount the real bundled hook and assert the properties
// that must hold no matter which mode wins:
//
//   I1  every reported (cols, rows) fits inside the <pre>'s text box
//   I2  the transform never hides the anchor row (cursor / last painted / bottom)
//   I3  everything transformed moves together, regardless of creation order
//   I4  fixed point: laying out twice from one state changes nothing
//   I5  a non-authoritative viewer never pushes a size
//   I6  the canvas renderer engages only when the transform is identity
//
// I4 is the load-bearing one: every "it re-fires forever" and every "it never
// re-corrects" bug in this file's history is a fixed-point violation.

import assert from "node:assert/strict"
import test from "node:test"

import { preIsScaled } from "../js/terminal_canvas_scale.mjs"
import {
  CELL_H,
  CELL_W,
  PRE_PAD,
  displayMode,
  expectedFit,
  frameOf,
  gridPayload,
  lastSizeReport,
  layoutSnapshot,
  mountTerminal,
  openKeyboard,
  render,
  renderSettled,
  sizeReports,
  translateYOf,
  wait,
} from "./support/terminal_hook_harness.mjs"

// ---------------------------------------------------------------------------
// I1 — every reported grid fits inside the <pre>'s text box
// ---------------------------------------------------------------------------

const FIT_CASES = [
  { name: "desktop wide", width: 1600, height: 900, mobile: false },
  { name: "desktop squeezed", width: 640, height: 480, mobile: false },
  { name: "phone portrait", width: 390, height: 800, mobile: true },
  { name: "phone landscape", width: 800, height: 390, mobile: true },
]

for (const c of FIT_CASES) {
  test(`I1: ${c.name} reports a grid that fits the pre's text box`, async (t) => {
    const { hook } = await mountTerminal({ t, width: c.width, height: c.height, mobile: c.mobile })

    const report = lastSizeReport(hook)
    assert.ok(report, "a fitted size was reported")

    const { cols, rows } = report.payload
    assert.deepEqual({ cols, rows }, expectedFit(c.width, c.height))
    assert.ok(
      cols * CELL_W <= c.width - PRE_PAD,
      `${cols} cols overhang the text box (${c.width - PRE_PAD}px)`
    )
    assert.ok(
      rows * CELL_H <= c.height - PRE_PAD,
      `${rows} rows overhang the text box (${c.height - PRE_PAD}px)`
    )

  })
}

// ---------------------------------------------------------------------------
// I2 — the transform never hides the anchor row
// ---------------------------------------------------------------------------

const ANCHOR_CASES = [
  { name: "fresh session, content at the top", painted: 16, cursorRow: 15 },
  { name: "half-filled grid", painted: 30, cursorRow: 29 },
  { name: "scrolled shell, cursor on the last row", painted: 46, cursorRow: 45 },
  { name: "hidden cursor falls back to last painted row", painted: 12, cursorRow: 11, cursorVisible: false },
]

for (const c of ANCHOR_CASES) {
  test(`I2: keyboard open keeps the anchor visible — ${c.name}`, async (t) => {
    const { hook, el } = await mountTerminal({ t, mobile: true })
    const { cols, rows: pinnedRows } = expectedFit(390, 800)

    render(hook, gridPayload({
      cols,
      rows: pinnedRows,
      painted: c.painted,
      cursorRow: c.cursorRow,
      cursorVisible: c.cursorVisible ?? true,
    }))
    await wait(150)

    openKeyboard(hook, el, { width: 390, height: 280 })
    await wait(150)

    assert.equal(displayMode(hook), "rowpin", "row-pinning engaged")

    const visibleRows = Math.floor((280 - PRE_PAD) / CELL_H)
    const firstVisible = translateYOf(hook) / CELL_H
    const lastVisible = firstVisible + visibleRows - 1
    const anchor = c.cursorVisible === false ? c.painted - 1 : c.cursorRow

    assert.ok(
      anchor >= firstVisible && anchor <= lastVisible,
      `anchor row ${anchor} outside visible window ${firstVisible}..${lastVisible}`
    )

  })
}

// ---------------------------------------------------------------------------
// I3 — everything transformed moves together, regardless of creation order
// ---------------------------------------------------------------------------

// The scale frame is what carries the transform. Anything painting cells or
// marking a position must live inside it, or it stays behind while the grid
// moves (the classic "caret parked on the left edge of the letterbox").
function transformedNodes(hook) {
  return {
    pre: hook.pre,
    cursorEl: hook.cursorEl,
    selectionLayer: hook.selectionLayer,
    input: hook.input,
    glyphCanvas: hook.__glyphCanvas,
  }
}

function assertAllInsideFrame(hook, label) {
  const frame = frameOf(hook)
  assert.ok(frame, `${label}: a scale frame exists`)

  for (const [name, node] of Object.entries(transformedNodes(hook))) {
    if (!node) continue
    assert.ok(
      frame.contains(node),
      `${label}: ${name} is outside the transformed frame, so it will not move with the grid`
    )
  }
}

// KNOWN FAILING (Phase 2 fixes). ensureScaleFrame adopts hook.__glyphCanvas
// only if it exists when the frame is built — but the frame is built during the
// transient "scale" beat at mount, before the first paint creates the canvas.
// So the adopt branch is effectively dead and the canvas is ALWAYS left outside
// the frame, painting unscrolled while the DOM layers move.
const CANVAS_FRAME_TODO = {
  todo: "Phase 2: ensureScaleFrame must adopt late-created children",
}

test("I3: canvas created BEFORE the frame moves with the transform", CANVAS_FRAME_TODO, async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true, renderer: "canvas" })
  const { cols, rows } = expectedFit(390, 800)

  // Render until settled: this creates the glyph canvas.
  await renderSettled(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  assert.ok(hook.__glyphCanvas, "canvas renderer created its canvas")

  // Then transform: row-pinning builds the frame.
  openKeyboard(hook, el)
  await wait(150)

  assertAllInsideFrame(hook, "canvas-before-frame")
})

test("I3: canvas created AFTER the frame moves with the transform", CANVAS_FRAME_TODO, async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true, renderer: "canvas" })
  const { cols, rows } = expectedFit(390, 800)

  // Transform first: build the frame with no canvas in existence yet.
  openKeyboard(hook, el)
  await wait(150)
  assert.ok(frameOf(hook), "frame built before any canvas existed")

  // Then render: ensureCanvas runs with the frame already in place.
  await renderSettled(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  assert.ok(hook.__glyphCanvas, "canvas renderer created its canvas")

  assertAllInsideFrame(hook, "frame-before-canvas")
})

// ---------------------------------------------------------------------------
// I4 — fixed point
// ---------------------------------------------------------------------------

const IDEMPOTENCE_CASES = [
  { name: "desktop fit", mobile: false, keyboard: false },
  { name: "phone fit", mobile: true, keyboard: false },
  { name: "phone row-pinned", mobile: true, keyboard: true },
]

for (const c of IDEMPOTENCE_CASES) {
  test(`I4: laying out twice changes nothing — ${c.name}`, async (t) => {
    const { hook, el } = await mountTerminal({ t, mobile: c.mobile })
    const { cols, rows } = expectedFit(390, 800)
    render(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
    await wait(150)

    if (c.keyboard) {
      openKeyboard(hook, el)
      await wait(150)
    }

    const before = layoutSnapshot(hook)
    hook.onWindowResize()
    await wait(150)
    const after = layoutSnapshot(hook)

    assert.equal(after, before, "a second layout pass over identical state changed something")

  })
}

test("I4: the periodic reheal is silent in steady state", async (t) => {
  // The 2s level-triggered backstop re-measures forever. If its measure
  // disagrees with the fit path's, it re-fires every tick — the shape of a
  // self-sustaining resize loop.
  const { hook } = await mountTerminal({ t, width: 1600, height: 900 })
  const settled = layoutSnapshot(hook)
  const reports = sizeReports(hook).length

  await wait(4500) // two reheal ticks

  assert.equal(sizeReports(hook).length, reports, "the reheal pushed a size in steady state")
  assert.equal(layoutSnapshot(hook), settled, "the reheal mutated a settled layout")

})

// ---------------------------------------------------------------------------
// I5 — a non-authoritative viewer never pushes a size
// ---------------------------------------------------------------------------

test("I5: an unfocused desktop viewer scales to fit and reports nothing", async (t) => {
  const { hook } = await mountTerminal({ t, width: 1600, height: 900, hasFocus: false })

  assert.deepEqual(sizeReports(hook), [], "an observer pushed a size at mount")

  render(hook, gridPayload({ cols: 200, rows: 60 }))
  await wait(150)
  hook.onWindowResize()
  await wait(150)

  assert.deepEqual(sizeReports(hook), [], "an observer pushed a size on resize")
  assert.equal(displayMode(hook), "scale", "observers scale the shared grid to fit")

})

// ---------------------------------------------------------------------------
// I6 — the canvas engages only when the transform is identity
// ---------------------------------------------------------------------------

// The canvas draws glyphs at unscaled cell metrics into its own element. It is
// only correct when the frame carries no transform; under any other mode the
// DOM painter must take over. This decision has to cover EVERY mode — the
// original list was written before row-pinning existed and never grew.
const TRANSFORMED_MODES = ["scale", "zoom", "rowpin"]

for (const mode of TRANSFORMED_MODES) {
  // "rowpin" is KNOWN FAILING (Phase 2 fixes): preIsScaled's mode list was
  // written before row-pinning existed and never grew, so the canvas stays
  // engaged while the frame is translated.
  const opts = mode === "rowpin"
    ? { todo: "Phase 2: canvasSafe must come from the layout model, not a hand-kept list" }
    : {}

  test(`I6: canvas is released to the DOM in "${mode}" mode`, opts, () => {
    const hook = { el: { dataset: { displayMode: mode } } }
    assert.equal(
      preIsScaled(hook),
      true,
      `"${mode}" transforms the frame, so the canvas must hand back to the DOM painter`
    )
  })
}

test('I6: canvas stays engaged in "fit" mode and before any mode is set', () => {
  assert.equal(preIsScaled({ el: { dataset: { displayMode: "fit" } } }), false)
  assert.equal(preIsScaled({ el: { dataset: {} } }), false)
})
