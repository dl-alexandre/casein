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

import { DisplayMode, computeTerminalLayout, isIdentityMode } from "../js/terminal_layout_model.mjs"
import {
  CELL_H,
  CELL_W,
  PRE_PAD,
  displayMode,
  expectedFit,
  frameOf,
  closeKeyboard,
  gridPayload,
  lastSizeReport,
  layoutSnapshot,
  mountTerminal,
  openKeyboard,
  render,
  renderSettled,
  setViewport,
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

test("I3: canvas created BEFORE the frame moves with the transform", async (t) => {
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

test("I3: a canvas created after the frame already exists still moves with it", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true, renderer: "canvas" })
  const { cols, rows } = expectedFit(390, 800)

  // Build the frame first, with no canvas in existence. The canvas cannot be
  // created while row-pinned — it is correctly disabled under a transform — so
  // drop back to an identity mode before painting. That is the real hazard: a
  // frame from an earlier transform, still in the DOM, and a canvas created
  // afterwards that has to find its way inside it.
  openKeyboard(hook, el)
  await wait(150)
  assert.ok(frameOf(hook), "frame built before any canvas existed")
  assert.ok(!hook.__glyphCanvas, "no canvas is created while the frame is transformed")

  closeKeyboard(hook, el)
  await wait(150)
  await renderSettled(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  assert.ok(hook.__glyphCanvas, "canvas renderer created its canvas once back in an identity mode")

  // Now transform again: the late-created canvas must have been adopted.
  openKeyboard(hook, el)
  await wait(150)

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

test("I4: overflow scaling cannot feed its transform back into cell measurement", async (t) => {
  const { hook } = await mountTerminal({ t, mobile: true })

  // A real browser includes the scale-frame transform in the measure span's
  // bounding rect. Model that composition explicitly: the old measurement
  // path interpreted the transformed width as a smaller cell, requested a
  // different grid on every pass, and produced the mobile width flicker.
  Object.defineProperty(hook.measure, "offsetWidth", {
    configurable: true,
    value: CELL_W * 10,
  })
  hook.measure.getBoundingClientRect = () => {
    const raw = window
      .getComputedStyle(hook.el)
      .getPropertyValue("--casein-term-display-scale")
    const scale = Number.parseFloat(raw)
    return {width: CELL_W * 10 * (Number.isFinite(scale) && scale > 0 ? scale : 1)}
  }

  render(hook, gridPayload({cols: 80, rows: 50, painted: 16, cursorRow: 15}))
  await wait(150)

  const firstReportCount = sizeReports(hook).length
  const firstFit = [hook.__lastFitCols, hook.__lastFitRows]

  hook.onWindowResize()
  await wait(150)
  hook.onWindowResize()
  await wait(150)

  assert.equal(
    sizeReports(hook).length,
    firstReportCount,
    "the scale-frame transform changed the fitted grid"
  )
  assert.deepEqual(
    [hook.__lastFitCols, hook.__lastFitRows],
    firstFit,
    "the fitted grid drifted while only its display transform changed"
  )
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

// The canvas draws glyphs at unscaled cell metrics into its own element, so it
// is only correct while the frame carries no transform. The decision must be
// derived from the mode itself — the old hand-kept list next to the painter was
// written before row-pinning existed and never grew.
for (const mode of Object.values(DisplayMode)) {
  const identity = mode === DisplayMode.FIT

  test(`I6: "${mode}" declares canvas safety from the model`, () => {
    assert.equal(isIdentityMode(mode), identity)
  })
}

test("I6: every layout the model can produce agrees with its own mode", () => {
  const base = {
    container: {availableW: 390, availableH: 800, padL: 0, padT: 0},
    cell: {w: CELL_W, h: CELL_H, padX: PRE_PAD, padY: PRE_PAD},
    renderedGrid: {cols: 37, rows: 46},
    lastFit: {cols: 37, rows: 46},
    lastAppliedUserZoom: 1,
    pinnedRows: 46,
    cursor: {x: 0, y: 45, visible: true},
    rowsData: null,
    authority: true,
    mobile: true,
    keyboardOpen: false,
    rowPinAllowed: true,
    userZoom: 1,
  }

  const variants = [
    {name: "fit", input: base},
    {name: "zoom", input: {...base, userZoom: 1.5, lastAppliedUserZoom: 1.5}},
    {name: "scale (overflow)", input: {...base, renderedGrid: {cols: 200, rows: 60}}},
    {name: "observer", input: {...base, authority: false}},
    {name: "rowpin", input: {...base, keyboardOpen: true, container: {availableW: 390, availableH: 280, padL: 0, padT: 0}}},
  ]

  for (const v of variants) {
    const out = computeTerminalLayout(v.input)
    assert.ok(!out.noop, `${v.name}: produced a layout`)
    assert.equal(
      out.canvasSafe,
      isIdentityMode(out.mode),
      `${v.name}: canvasSafe disagrees with mode "${out.mode}"`
    )
    // A transformed frame and canvas safety are mutually exclusive by definition.
    assert.equal(out.canvasSafe, out.frame == null, `${v.name}: frame/canvasSafe mismatch`)
  }
})

test("I6: the hook publishes the model's verdict for the painter", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows } = expectedFit(390, 800)

  await renderSettled(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  assert.equal(displayMode(hook), DisplayMode.FIT)
  assert.equal(hook.__canvasSafe, true, "identity fit keeps the canvas engaged")

  openKeyboard(hook, el)
  await wait(150)
  assert.equal(displayMode(hook), DisplayMode.ROWPIN)
  assert.equal(hook.__canvasSafe, false, "a translated frame must release the canvas")
})

// ---------------------------------------------------------------------------
// Screen mode — row-pinning must not crop a full-screen TUI
// ---------------------------------------------------------------------------

// A scrolling shell keeps its live content on the last written row, so holding
// the PTY size and scrolling the grid is right. An alternate-screen TUI draws to
// the whole grid and pins its UI to the bottom row; cropping it to a
// keyboard-sized window shows a slice of a layout built for a taller screen and
// the program never learns to redraw. This was the originally reported bug:
// "clauded was not adhering to the keyboard showing up".
test("screen mode: a normal-screen shell is row-pinned on keyboard open", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows } = expectedFit(390, 800)

  render(hook, { ...gridPayload({ cols, rows, painted: 16, cursorRow: 15 }), screen_mode: "normal" })
  await wait(150)

  const before = sizeReports(hook).length
  openKeyboard(hook, el)
  await wait(150)

  assert.equal(displayMode(hook), DisplayMode.ROWPIN)
  assert.equal(sizeReports(hook).length, before, "a shell is held at its keyboard-closed size")
})

test("screen mode: an alternate-screen TUI is resized instead of cropped", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows } = expectedFit(390, 800)

  render(hook, { ...gridPayload({ cols, rows, painted: rows, cursorRow: rows - 1 }), screen_mode: "alternate" })
  await wait(150)

  openKeyboard(hook, el)
  await wait(150)

  assert.notEqual(displayMode(hook), DisplayMode.ROWPIN, "a full-screen TUI must not be row-pinned")

  const report = lastSizeReport(hook)
  assert.deepEqual(
    report.payload,
    expectedFit(390, 280),
    "the TUI is told the real keyboard-open size so it can reflow"
  )
})

test("screen mode: a pane that has not painted yet behaves as before", () => {
  // No frame has arrived, so no screen mode is known. Default to the
  // shell-shaped assumption rather than suppressing row-pinning entirely.
  const input = {
    container: {availableW: 390, availableH: 280, padL: 0, padT: 0},
    cell: {w: CELL_W, h: CELL_H, padX: PRE_PAD, padY: PRE_PAD},
    renderedGrid: {cols: 37, rows: 46},
    lastFit: {cols: 37, rows: 46},
    lastAppliedUserZoom: 1,
    pinnedRows: 46,
    cursor: {x: 0, y: 45, visible: true},
    authority: true,
    mobile: true,
    keyboardOpen: true,
    rowPinAllowed: true,
    userZoom: 1,
  }

  assert.equal(computeTerminalLayout(input).mode, DisplayMode.ROWPIN)
  assert.equal(computeTerminalLayout({...input, screenMode: "normal"}).mode, DisplayMode.ROWPIN)

  // Alternate screen: no row-pin, and a real resize is proposed. The mode is
  // SCALE rather than FIT only because the 46-row grid still on screen
  // overflows the new 15-row fit — the letterbox is borrowed until the resize
  // lands, which is exactly the convergence path.
  const alt = computeTerminalLayout({...input, screenMode: "alternate"})
  assert.notEqual(alt.mode, DisplayMode.ROWPIN)
  assert.deepEqual(alt.requestedGrid, {cols: 37, rows: 15})
})

// ---------------------------------------------------------------------------
// Triggers — every route into the layout goes through one entry point
// ---------------------------------------------------------------------------

// The soft keyboard used to reach the layout only via reportViewportActive ->
// onViewportAuthorityChanged, which early-returns when authority did not flip.
// Row-pin engagement therefore depended on a chain of side effects: the key
// bar's inset commit clearing its hysteresis gate, changing a CSS custom
// property, that changing the shell's padding-bottom, and THAT reaching the
// ResizeObserver. Any link failing left the keyboard silently ignored.
test("triggers: the keyboard event alone engages row-pinning", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows } = expectedFit(390, 800)

  render(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  await wait(150)
  assert.equal(displayMode(hook), DisplayMode.FIT)

  // Shrink the container and mark the keyboard open, but do NOT call
  // onWindowResize — no ResizeObserver, no window resize. Only the event.
  document.documentElement.classList.add("casein-keyboard-open")
  setViewport(el, { width: 390, height: 280 })
  window.dispatchEvent(new window.CustomEvent("casein:keyboard-open-changed", {
    detail: { open: true },
  }))
  await wait(150)

  assert.equal(displayMode(hook), DisplayMode.ROWPIN, "the keyboard event alone must reach the layout")
})

// ---------------------------------------------------------------------------
// Drastic column shrinks are confirmed before they reach the shared PTY
// ---------------------------------------------------------------------------
//
// Prod, 2026-07-27: `226x116 -> 81x116 -> 226x116` from a single viewer inside
// 400ms, reason `keyboard_toggle` — a measurement taken mid-transition. Every
// size on record afterwards is correct, but the program inside tmux had already
// re-wrapped its output to 81 columns, and widening back does not un-wrap it.
// The operator is left reading a narrow column of text in a wide pane.

const wideModelInput = (overrides = {}) => ({
  // 2260 / 10 = 226 cols, 1972 / 17 = 116 rows.
  container: { availableW: 2260, availableH: 1972, padL: 0, padT: 0 },
  cell: { w: 10, h: 17, padX: 0, padY: 0 },
  renderedGrid: { cols: 226, rows: 116 },
  lastFit: { cols: 226, rows: 116 },
  lastAppliedUserZoom: 1,
  pinnedRows: null,
  cursor: null,
  rowsData: null,
  authority: true,
  mobile: false,
  keyboardOpen: false,
  rowPinAllowed: true,
  userZoom: 1,
  trigger: "event",
  ...overrides,
})

test("shrink confirm: a drastic column shrink is not pushed on first sight", () => {
  const result = computeTerminalLayout(
    wideModelInput({ container: { availableW: 810, availableH: 1972, padL: 0, padT: 0 } })
  )

  assert.equal(result.requestedGrid, null, "81 columns must not reach the PTY unconfirmed")
  assert.deepEqual(result.confirmShrink, { cols: 81, rows: 116 })
  assert.deepEqual(result.fitAnchor, { cols: 226, rows: 116 }, "the wide grid stays anchored")
})

test("shrink confirm: the confirming pass pushes the same shrink", () => {
  const result = computeTerminalLayout(
    wideModelInput({
      container: { availableW: 810, availableH: 1972, padL: 0, padT: 0 },
      trigger: "confirm",
    })
  )

  assert.deepEqual(result.requestedGrid, { cols: 81, rows: 116 })
  assert.equal(result.confirmShrink, null)
})

test("shrink confirm: an ordinary shrink still goes out immediately", () => {
  const result = computeTerminalLayout(
    wideModelInput({ container: { availableW: 2000, availableH: 1972, padL: 0, padT: 0 } })
  )

  assert.deepEqual(result.requestedGrid, { cols: 200, rows: 116 })
  assert.ok(!result.confirmShrink)
})

test("shrink confirm: rows may collapse without confirmation", () => {
  // The soft keyboard does exactly this, and a short grid costs nothing
  // permanent — no reflow, no re-wrap. Only width is held back.
  const result = computeTerminalLayout(
    wideModelInput({ container: { availableW: 2260, availableH: 680, padL: 0, padT: 0 } })
  )

  assert.deepEqual(result.requestedGrid, { cols: 226, rows: 40 })
  assert.ok(!result.confirmShrink)
})

test("shrink confirm: a transient narrow measurement never reaches the PTY", async (t) => {
  const { hook, el } = await mountTerminal({ t, width: 1600, height: 900 })
  const wide = expectedFit(1600, 900)
  assert.deepEqual(lastSizeReport(hook).payload, wide, "the wide fit landed")

  const narrow = expectedFit(560, 900)
  setViewport(el, { width: 560, height: 900 })
  hook.onWindowResize()
  await wait(150)

  // ...and the container is back before the confirmation is due.
  setViewport(el, { width: 1600, height: 900 })
  hook.onWindowResize()
  await wait(800)

  assert.ok(
    !sizeReports(hook).some((r) => r.payload.cols === narrow.cols),
    `the spike was pushed to the PTY: ${JSON.stringify(sizeReports(hook).map((r) => r.payload))}`
  )
  assert.deepEqual(lastSizeReport(hook).payload, wide)
})

test("shrink confirm: a real narrow container still lands, one beat later", async (t) => {
  const { hook, el } = await mountTerminal({ t, width: 1600, height: 900 })
  const narrow = expectedFit(560, 900)

  setViewport(el, { width: 560, height: 900 })
  hook.onWindowResize()
  await wait(800)

  assert.deepEqual(
    lastSizeReport(hook).payload,
    narrow,
    "a shrink that is still there when re-measured must be honoured"
  )
})

test("triggers: a burst of resizes collapses into one layout pass", async (t) => {
  const { hook } = await mountTerminal({ t, width: 1600, height: 900 })
  const before = sizeReports(hook).length

  // Ten events inside the coalescing window must not cost ten tmux resizes.
  for (let i = 0; i < 10; i += 1) hook.onWindowResize()
  await wait(200)

  assert.ok(
    sizeReports(hook).length - before <= 1,
    `a resize burst pushed ${sizeReports(hook).length - before} sizes`
  )
})

// ---------------------------------------------------------------------------
// Breadcrumb — the client half of the size negotiation reaches the journal
// ---------------------------------------------------------------------------

const layoutChanges = (hook) => hook.pushes.filter((p) => p.event === "layout_change")

test("breadcrumb: a layout change is reported with its trigger", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })

  const first = layoutChanges(hook).at(-1)
  assert.ok(first, "the initial fit is reported")
  assert.deepEqual(
    { cols: first.payload.cols, rows: first.payload.rows },
    expectedFit(390, 800)
  )
  assert.equal(first.payload.authority, true)

  const before = layoutChanges(hook).length
  openKeyboard(hook, el)
  await wait(150)

  const latest = layoutChanges(hook).at(-1)
  assert.ok(layoutChanges(hook).length > before, "the keyboard toggle is reported")
  assert.equal(latest.payload.mode, DisplayMode.ROWPIN)
  assert.equal(latest.payload.reason, "keyboard_toggle", "the trigger is named, not inferred")
})

test("breadcrumb: steady state and the row-pin follow stay silent", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows } = expectedFit(390, 800)

  render(hook, gridPayload({ cols, rows, painted: 16, cursorRow: 15 }))
  await wait(150)
  openKeyboard(hook, el)
  await wait(150)

  const settled = layoutChanges(hook).length

  // Output arriving while row-pinned scrolls the window but never changes the
  // mode or the proposed grid — this must not become per-frame chatter.
  for (let row = 16; row < 40; row += 1) {
    render(hook, gridPayload({ cols, rows, painted: row + 1, cursorRow: row }))
    await wait(20)
  }
  hook.onWindowResize()
  await wait(200)

  assert.equal(layoutChanges(hook).length, settled, "unchanged layouts were reported")
})
