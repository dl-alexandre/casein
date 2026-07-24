import test from "node:test"
import assert from "node:assert/strict"

import {
  parseViewport,
  viewportFrameStyles,
  viewportScale,
  withinViewport,
} from "../js/preview_pane_viewport.mjs"

test("parseViewport reads the WxH attribute form", () => {
  assert.deepEqual(parseViewport("390x844"), {width: 390, height: 844})
  assert.deepEqual(parseViewport("1280X900"), {width: 1280, height: 900})
})

test("parseViewport treats absent or malformed values as no locked viewport", () => {
  for (const raw of [null, undefined, "", "garbage", "390", "390x", "x844", "390x844px", "-390x844"]) {
    assert.equal(parseViewport(raw), null, `expected null for ${JSON.stringify(raw)}`)
  }
})

test("parseViewport rejects zero dimensions", () => {
  // A 0-wide frame would make viewportScale divide by zero.
  assert.equal(parseViewport("0x844"), null)
  assert.equal(parseViewport("390x0"), null)
})

test("viewportScale shrinks a viewport larger than the available area", () => {
  // Width-bound: 640/1280 is tighter than 900/900.
  assert.equal(viewportScale({width: 1280, height: 900}, 640, 900), 0.5)
  // Height-bound: 422/844 is tighter than 390/390.
  assert.equal(viewportScale({width: 390, height: 844}, 390, 422), 0.5)
})

test("viewportScale never magnifies a viewport smaller than the pane", () => {
  assert.equal(viewportScale({width: 390, height: 844}, 1200, 1200), 1)
})

test("viewportScale is 1 when there is nothing to scale or no layout yet", () => {
  assert.equal(viewportScale(null, 800, 600), 1)
  // clientWidth/Height are 0 before the pane is laid out — do not divide by it.
  assert.equal(viewportScale({width: 390, height: 844}, 0, 0), 1)
  assert.equal(viewportScale({width: 390, height: 844}, 800, 0), 1)
})

test("viewportFrameStyles pins a locked viewport to exact CSS pixels", () => {
  const {clip, iframe} = viewportFrameStyles({width: 390, height: 844}, 0.5)

  assert.equal(iframe.width, "390px")
  assert.equal(iframe.height, "844px")
  assert.equal(iframe.transform, "scale(0.5)")
  assert.equal(iframe.transformOrigin, "0 0")
  assert.equal(clip.overflow, "hidden")
})

test("viewportFrameStyles omits the transform when it would be a no-op", () => {
  const {iframe} = viewportFrameStyles({width: 390, height: 844}, 1)
  assert.equal(iframe.transform, "none")
})

test("viewportFrameStyles with no viewport fills the pane", () => {
  const {iframe} = viewportFrameStyles(null, 1)

  assert.equal(iframe.width, "100%")
  assert.equal(iframe.height, "100%")
  assert.equal(iframe.transform, "none")
})

// Every style the locked branch sets must also be set by the unlocked branch,
// or clearing a viewport on a live pane would leave the old value behind —
// Object.assign only overwrites keys it is given.
test("both viewportFrameStyles branches set the same style keys", () => {
  const locked = viewportFrameStyles({width: 390, height: 844}, 0.5)
  const unlocked = viewportFrameStyles(null, 1)

  assert.deepEqual(Object.keys(locked.iframe).sort(), Object.keys(unlocked.iframe).sort())
  assert.deepEqual(Object.keys(locked.clip).sort(), Object.keys(unlocked.clip).sort())
})

test("withinViewport bounds clicks to the locked frame", () => {
  const viewport = {width: 390, height: 844}

  assert.equal(withinViewport(viewport, 0, 0), true)
  assert.equal(withinViewport(viewport, 389, 843), true)
  // Exclusive upper bound — 390 is the first column outside a 390-wide frame.
  assert.equal(withinViewport(viewport, 390, 100), false)
  assert.equal(withinViewport(viewport, 100, 844), false)
  assert.equal(withinViewport(viewport, -1, 100), false)
  assert.equal(withinViewport(viewport, 100, -1), false)
})

test("withinViewport accepts any point when the pane itself is the frame", () => {
  assert.equal(withinViewport(null, 0, 0), true)
  assert.equal(withinViewport(null, 5000, 5000), true)
})
