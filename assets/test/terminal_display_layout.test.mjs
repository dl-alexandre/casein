import assert from "node:assert/strict"
import test from "node:test"

import {
  fitBaseScale,
  isMobileTerminalLayout,
  scaledContentOffsets,
  viewportActiveForClient
} from "../js/terminal_display_layout.mjs"

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
