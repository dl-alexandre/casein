// Regression tests for mobile row-pinning, against the REAL bundled hook.
//
// Row-pinning holds the PTY at its keyboard-closed row count and scrolls the
// fixed grid so the rows that matter stay above the soft keyboard, instead of
// reflowing tmux on every keyboard toggle. The bug these pin down: it scrolled
// to the grid BOTTOM unconditionally, which is only where the content lives if
// the grid is full. On a fresh session the shell has painted ~16 rows at the
// top of a ~46-row grid and left the rest blank, so opening the keyboard
// scrolled the small visible window entirely into unwritten rows — the
// terminal went blank the instant the keyboard came up (mobile PWA screenshot).
//
// terminal_display_layout.test.mjs covers the geometry in isolation and
// terminal_layout_contract.test.mjs covers the cross-mode invariants; these are
// the row-pin-specific behaviours (no reflow on toggle, clean exit).

import assert from "node:assert/strict"
import test from "node:test"

import {
  CELL_H,
  CELL_W,
  PRE_PAD,
  closeKeyboard,
  displayMode,
  expectedFit,
  gridPayload,
  lastSizeReport,
  mountTerminal,
  openKeyboard,
  render,
  sizeReports,
  translateYOf,
  wait,
} from "./support/terminal_hook_harness.mjs"

test("keyboard-closed fit reports a grid that fits inside the pre's text box", async (t) => {
  const { hook } = await mountTerminal({ t, mobile: true })

  const { payload } = lastSizeReport(hook)
  assert.deepEqual(payload, expectedFit(390, 800))
  assert.ok(payload.cols * CELL_W <= 390 - PRE_PAD)
})

test("opening the keyboard keeps a top-anchored cursor on screen", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows: pinnedRows } = expectedFit(390, 800)
  const cursorRow = 15

  // A fresh session: 16 painted rows at the top of the grid, blank tail.
  render(hook, gridPayload({ cols, rows: pinnedRows, painted: 16, cursorRow }))
  await wait(150)

  openKeyboard(hook, el, { width: 390, height: 280 })
  await wait(150)

  assert.equal(displayMode(hook), "rowpin", "row-pinning engaged")

  const visibleRows = Math.floor((280 - PRE_PAD) / CELL_H)
  const offsetY = translateYOf(hook)
  assert.notEqual(offsetY, null, "scale frame carries the row-pin translate")

  // The cursor must land inside the window still on screen. Before the fix this
  // scrolled to the grid bottom (offsetY = (pinnedRows - visibleRows) * CELL_H),
  // parking the window in the blank tail with the cursor far above it.
  const firstVisible = offsetY / CELL_H
  const lastVisible = firstVisible + visibleRows - 1
  assert.ok(
    cursorRow >= firstVisible && cursorRow <= lastVisible,
    `cursor row ${cursorRow} outside visible window ${firstVisible}..${lastVisible}`
  )
  assert.ok(firstVisible < 16, "window starts inside the painted region")
})

test("row-pinning holds the PTY at its keyboard-closed rows", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { rows: pinnedRows } = expectedFit(390, 800)
  const before = sizeReports(hook).length

  openKeyboard(hook, el, { width: 390, height: 280 })
  await wait(150)

  assert.equal(sizeReports(hook).length, before, "no tmux reflow on keyboard open")
  assert.equal(hook.__lastFitRows, pinnedRows, "PTY still held at the keyboard-closed rows")
})

test("a scrolled shell still pins to the bottom of the grid", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })
  const { cols, rows: pinnedRows } = expectedFit(390, 800)

  // Fully painted grid with the cursor on the last row — the classic shell.
  render(hook, gridPayload({ cols, rows: pinnedRows, painted: pinnedRows, cursorRow: pinnedRows - 1 }))
  await wait(150)

  openKeyboard(hook, el, { width: 390, height: 280 })
  await wait(150)

  const visibleRows = Math.floor((280 - PRE_PAD) / CELL_H)
  assert.equal(translateYOf(hook), (pinnedRows - visibleRows) * CELL_H)
})

test("closing the keyboard drops the row-pin translate", async (t) => {
  const { hook, el } = await mountTerminal({ t, mobile: true })

  openKeyboard(hook, el, { width: 390, height: 280 })
  await wait(150)
  assert.equal(displayMode(hook), "rowpin")

  closeKeyboard(hook, el, { width: 390, height: 800 })
  await wait(150)

  assert.notEqual(displayMode(hook), "rowpin")
  assert.equal(translateYOf(hook), null, "translate cleared on the way out")
})
