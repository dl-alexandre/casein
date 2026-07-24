import assert from "node:assert/strict"
import test from "node:test"

import {
  fitBaseScale,
  fitGridForViewport,
  isMobileTerminalLayout,
  latchMobileAuthority,
  rowPinAnchorRow,
  rowPinOffsets,
  scaledContentOffsets,
  strandedFitReheal,
  viewportActiveForClient
} from "../js/terminal_display_layout.mjs"

const row = (text, cols = 40) =>
  Array.from({length: cols}, (_, i) => [text[i] ?? " "])

test("rowPinOffsets: scrolls a pinned grid to show its bottom rows", () => {
  // 40-row grid pinned; keyboard leaves room for 22 → hide the top 18.
  const r = rowPinOffsets({availableH: 22 * 17, cellH: 17, pinnedRows: 40})
  assert.equal(r.visibleRows, 22)
  assert.equal(r.hiddenRows, 18)
  assert.equal(r.offsetY, 18 * 17)
  assert.equal(r.pinnedRows, 40)
})

test("rowPinOffsets: no offset when everything already fits", () => {
  const r = rowPinOffsets({availableH: 40 * 17, cellH: 17, pinnedRows: 40})
  assert.equal(r.hiddenRows, 0)
  assert.equal(r.offsetY, 0)
})

// The keyboard-open blank-screen bug: a fresh session paints ~16 rows at the
// top of a 46-row grid and leaves the rest unwritten. Scrolling to the grid
// bottom put the 15-row keyboard-open window entirely inside blank rows.
test("rowPinOffsets: keeps the anchor row visible instead of a blank tail", () => {
  const r = rowPinOffsets({availableH: 15 * 17, cellH: 17, pinnedRows: 46, anchorRow: 15})
  assert.equal(r.visibleRows, 15)
  assert.equal(r.hiddenRows, 1)
  assert.equal(r.offsetY, 17)
})

test("rowPinOffsets: a bottom anchor still scrolls to the bottom", () => {
  const bottom = rowPinOffsets({availableH: 15 * 17, cellH: 17, pinnedRows: 46, anchorRow: 45})
  const implicit = rowPinOffsets({availableH: 15 * 17, cellH: 17, pinnedRows: 46})
  assert.equal(bottom.hiddenRows, 31)
  assert.deepEqual(implicit, bottom)
})

test("rowPinOffsets: never scrolls past the end of the grid", () => {
  const r = rowPinOffsets({availableH: 15 * 17, cellH: 17, pinnedRows: 46, anchorRow: 999})
  assert.equal(r.hiddenRows, 31)
})

test("rowPinOffsets: an anchor already on screen needs no scroll", () => {
  const r = rowPinOffsets({availableH: 15 * 17, cellH: 17, pinnedRows: 46, anchorRow: 3})
  assert.equal(r.hiddenRows, 0)
  assert.equal(r.offsetY, 0)
})

test("rowPinAnchorRow: prefers the live cursor", () => {
  assert.equal(rowPinAnchorRow({cursor: {y: 12, visible: true}, pinnedRows: 46}), 12)
})

test("rowPinAnchorRow: clamps a cursor past the pinned grid", () => {
  assert.equal(rowPinAnchorRow({cursor: {y: 99, visible: true}, pinnedRows: 46}), 45)
})

test("rowPinAnchorRow: falls back to the last painted row when the cursor is hidden", () => {
  const rowsData = [row("hello"), row("world"), row(""), row("")]
  assert.equal(rowPinAnchorRow({cursor: {y: 1, visible: false}, rowsData, pinnedRows: 46}), 1)
})

test("rowPinAnchorRow: falls back to the grid bottom with nothing to go on", () => {
  assert.equal(rowPinAnchorRow({pinnedRows: 46}), 45)
  assert.equal(rowPinAnchorRow({cursor: {visible: false}, rowsData: [], pinnedRows: 46}), 45)
})

// The vanishing-characters bug: the <pre> carries `padding: 8px` inside its
// border box, so a grid sized from the container alone overhangs the text box
// and the overflow-hidden <pre> clips the last column/row.
test("fitGridForViewport: subtracts the pre's own padding", () => {
  const bare = fitGridForViewport({
    availableW: 390,
    availableH: 800,
    cellW: 8.5,
    cellH: 17
  })
  const padded = fitGridForViewport({
    availableW: 390,
    availableH: 800,
    cellW: 8.5,
    cellH: 17,
    padX: 16,
    padY: 16
  })

  assert.equal(bare.cols, 45)
  assert.equal(padded.cols, 44)
  assert.equal(padded.rows, 46)
  // The whole grid fits inside the text box, with no column overhanging it.
  assert.ok(padded.cols * 8.5 <= padded.textW)
  assert.ok(bare.cols * 8.5 > padded.textW)
})

test("fitGridForViewport: floors at a usable grid and guards bad metrics", () => {
  assert.equal(fitGridForViewport({availableW: 100, availableH: 100, cellW: 0, cellH: 17}), null)
  const tiny = fitGridForViewport({
    availableW: 10,
    availableH: 10,
    cellW: 8.5,
    cellH: 17,
    padX: 16,
    padY: 16
  })
  assert.equal(tiny.cols, 2)
  assert.equal(tiny.rows, 2)
})

test("strandedFitReheal: padding-aware measure stays quiet in steady state", () => {
  // 44x46 is the correct padded fit for this container; without padX/padY the
  // raw measure reads 45x47 and would re-fire the reheal forever.
  const args = {
    availableW: 390,
    availableH: 800,
    cellW: 8.5,
    cellH: 17,
    lastFitCols: 44,
    lastFitRows: 46
  }
  assert.equal(strandedFitReheal({...args, padX: 16, padY: 16}), false)
})

test("rowPinOffsets: guards bad input", () => {
  assert.equal(rowPinOffsets({availableH: 0, cellH: 17, pinnedRows: 40}), null)
  assert.equal(rowPinOffsets({availableH: 100, cellH: 0, pinnedRows: 40}), null)
  assert.equal(rowPinOffsets({availableH: 100, cellH: 17, pinnedRows: 0}), null)
})

test("isMobileTerminalLayout matches coarse, standalone, or narrow media", () => {
  assert.equal(isMobileTerminalLayout(() => ({ matches: false })), false)
  assert.equal(
    isMobileTerminalLayout((q) => ({ matches: q.includes("pointer: coarse") })),
    true
  )
  assert.equal(
    isMobileTerminalLayout((q) => ({ matches: q.includes("display-mode: standalone") })),
    true
  )
  assert.equal(
    isMobileTerminalLayout((q) => ({ matches: q.includes("max-width: 639px") })),
    true
  )
})

test("latchMobileAuthority: raw-active always wins upward", () => {
  assert.equal(latchMobileAuthority({raw: true, mobileLayout: false}), true)
  assert.equal(latchMobileAuthority({raw: true, mobileLayout: true}), true)
})

test("latchMobileAuthority: desktop never holds past a false raw signal", () => {
  assert.equal(
    latchMobileAuthority({raw: false, mobileLayout: false, wasActive: true, sinceActiveMs: 10}),
    false
  )
})

test("latchMobileAuthority: mobile holds through a brief blip then releases", () => {
  // Within grace, still authoritative — absorbs the iOS hasFocus flap.
  assert.equal(
    latchMobileAuthority({
      raw: false,
      mobileLayout: true,
      wasActive: true,
      sinceActiveMs: 300,
      graceMs: 1200
    }),
    true
  )
  // Past grace, authority settles to observer.
  assert.equal(
    latchMobileAuthority({
      raw: false,
      mobileLayout: true,
      wasActive: true,
      sinceActiveMs: 1500,
      graceMs: 1200
    }),
    false
  )
  // Never active to begin with → nothing to hold.
  assert.equal(
    latchMobileAuthority({
      raw: false,
      mobileLayout: true,
      wasActive: false,
      sinceActiveMs: 5,
      graceMs: 1200
    }),
    false
  )
})

test("viewportActiveForClient stays strict on desktop", () => {
  assert.equal(
    viewportActiveForClient({
      visibilityState: "visible",
      hasFocus: true,
      mobileLayout: false
    }),
    true
  )
  assert.equal(
    viewportActiveForClient({
      visibilityState: "visible",
      hasFocus: false,
      keyboardOpen: true,
      mobileLayout: false
    }),
    false
  )
  assert.equal(
    viewportActiveForClient({
      visibilityState: "hidden",
      hasFocus: true,
      mobileLayout: true
    }),
    false
  )
})

test("viewportActiveForClient relaxes for mobile keyboard / terminal focus", () => {
  assert.equal(
    viewportActiveForClient({
      visibilityState: "visible",
      hasFocus: false,
      keyboardOpen: true,
      mobileLayout: true
    }),
    true
  )
  assert.equal(
    viewportActiveForClient({
      visibilityState: "visible",
      hasFocus: false,
      terminalInputFocused: true,
      mobileLayout: true
    }),
    true
  )
  assert.equal(
    viewportActiveForClient({
      visibilityState: "visible",
      hasFocus: false,
      keyboardOpen: false,
      terminalInputFocused: false,
      mobileLayout: true
    }),
    false
  )
})

test("scaledContentOffsets centers by default and top-pins on mobile align", () => {
  const base = {
    availableW: 400,
    availableH: 200,
    padL: 0,
    padT: 0,
    contentW: 200,
    contentH: 100,
    scale: 1
  }

  const centered = scaledContentOffsets({ ...base, align: "center" })
  assert.equal(centered.offsetX, 100)
  assert.equal(centered.offsetY, 50)

  const top = scaledContentOffsets({ ...base, align: "top-center" })
  assert.equal(top.offsetX, 100)
  assert.equal(top.offsetY, 0)
})

test("fitBaseScale uses the limiting axis", () => {
  assert.equal(fitBaseScale(400, 200, 200, 100), 2)
  assert.equal(fitBaseScale(100, 200, 200, 100), 0.5)
  assert.equal(fitBaseScale(0, 200, 200, 100), 1)
})

test("strandedFitReheal: heals when the container can hold a much wider grid", () => {
  // Stranded at 62 cols (fit ran while the container was ~620px); container is
  // now full-width (~1950px) → ~195 cols available → heal.
  assert.equal(
    strandedFitReheal({
      availableW: 1950,
      availableH: 800,
      cellW: 10,
      cellH: 20,
      lastFitCols: 62,
      lastFitRows: 40
    }),
    true
  )
})

test("strandedFitReheal: heals on a stranded row count too", () => {
  assert.equal(
    strandedFitReheal({
      availableW: 620,
      availableH: 800, // 40 rows available vs 22 reported
      cellW: 10,
      cellH: 20,
      lastFitCols: 62,
      lastFitRows: 22
    }),
    true
  )
})

test("strandedFitReheal: steady state (grid already matches) does not heal", () => {
  // 1950/10 = 195 cols, 800/20 = 40 rows — exactly what we reported.
  assert.equal(
    strandedFitReheal({
      availableW: 1950,
      availableH: 800,
      cellW: 10,
      cellH: 20,
      lastFitCols: 195,
      lastFitRows: 40
    }),
    false
  )
})

test("strandedFitReheal: sub-hysteresis growth does not heal (no ±1 jitter)", () => {
  // 1 extra column/row available — within the default 2-cell margin.
  assert.equal(
    strandedFitReheal({
      availableW: 1959,
      availableH: 819,
      cellW: 10,
      cellH: 20,
      lastFitCols: 195,
      lastFitRows: 40
    }),
    false
  )
})

test("strandedFitReheal: never fires on shrink (leave that to the event path)", () => {
  // Container is now smaller than what we reported — growth-only, so no heal.
  assert.equal(
    strandedFitReheal({
      availableW: 620,
      availableH: 400,
      cellW: 10,
      cellH: 20,
      lastFitCols: 195,
      lastFitRows: 40
    }),
    false
  )
})

test("strandedFitReheal: guards missing metrics and unseeded fit", () => {
  const ok = { availableW: 1950, availableH: 800, cellW: 10, cellH: 20 }
  // No prior fit reported yet → the normal fit path owns the first report.
  assert.equal(strandedFitReheal({ ...ok, lastFitCols: NaN, lastFitRows: NaN }), false)
  assert.equal(strandedFitReheal({ ...ok, lastFitCols: undefined, lastFitRows: 40 }), false)
  // Degenerate metrics (hidden container mid-layout) → no decision.
  assert.equal(strandedFitReheal({ ...ok, cellW: 0, lastFitCols: 62, lastFitRows: 40 }), false)
  assert.equal(
    strandedFitReheal({ ...ok, availableW: 0, lastFitCols: 62, lastFitRows: 40 }),
    false
  )
  assert.equal(strandedFitReheal(), false)
})
