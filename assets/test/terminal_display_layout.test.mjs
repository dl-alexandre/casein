import assert from "node:assert/strict"
import test from "node:test"

import {
  fitBaseScale,
  isMobileTerminalLayout,
  latchMobileAuthority,
  rowPinOffsets,
  scaledContentOffsets,
  viewportActiveForClient
} from "../js/terminal_display_layout.mjs"

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
