import assert from "node:assert/strict"
import test from "node:test"

import {swipeThresholdPx, swipeWindowProgress} from "../js/window_swipe.mjs"

test("swipeWindowProgress: small travel is undecided", () => {
  const s = swipeWindowProgress(4, 2)
  assert.equal(s.axis, null)
  assert.equal(s.ready, false)
  assert.equal(s.progress, 0)
})

test("swipeWindowProgress: vertical-dominant locks out the swipe", () => {
  const s = swipeWindowProgress(10, 60)
  assert.equal(s.axis, "v")
  assert.equal(s.dir, null)
})

test("swipeWindowProgress: pull left → next window, left edge", () => {
  const s = swipeWindowProgress(-70, 10, {threshold: 120})
  assert.equal(s.axis, "h")
  assert.equal(s.dir, "next")
  assert.equal(s.edge, "left")
  assert.ok(s.progress > 0 && s.progress < 1)
  assert.equal(s.ready, false)
})

test("swipeWindowProgress: pull right → prev window, right edge", () => {
  const s = swipeWindowProgress(80, -12, {threshold: 120})
  assert.equal(s.dir, "prev")
  assert.equal(s.edge, "right")
})

test("swipeWindowProgress: past threshold is ready and clamps at 1", () => {
  const s = swipeWindowProgress(-240, 20, {threshold: 120})
  assert.equal(s.axis, "h")
  assert.equal(s.dir, "next")
  assert.equal(s.ready, true)
  assert.equal(s.progress, 1)
})

test("swipeWindowProgress: horizontal must clearly lead vertical", () => {
  // |dx| barely over |dy| but under startPx → undecided.
  assert.equal(swipeWindowProgress(9, 8, {startPx: 12}).axis, null)
  // Diagonal where dy >= dx is not a horizontal swipe.
  assert.equal(swipeWindowProgress(40, 40).axis, null)
})

test("swipeThresholdPx clamps to a thumb-comfortable range", () => {
  assert.equal(swipeThresholdPx(200), 90) // 0.32*200=64 → floor 90
  assert.equal(swipeThresholdPx(1000), 160) // 0.32*1000=320 → cap 160
  assert.equal(swipeThresholdPx(400), 128) // 0.32*400
  assert.equal(swipeThresholdPx(0), 115) // fallback width 360 → 0.32*360≈115
})
