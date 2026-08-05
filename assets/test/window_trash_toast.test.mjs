import {test} from "node:test"
import assert from "node:assert/strict"

import {formatSeconds, graceMs, windowTrashToast} from "../js/window_trash_toast.mjs"

test("names the closed window and how long is left to undo", () => {
  const toast = windowTrashToast({label: "window “build”", grace_ms: 30000})

  assert.equal(toast.message, "Closed window “build” · 30s to undo")
  assert.equal(toast.actionLabel, "Undo")
  // The toast's lifetime IS the countdown, so it must match the server's grace.
  assert.equal(toast.durationMs, 30000)
})

test("falls back to a generic label when the window has no name", () => {
  assert.match(windowTrashToast({grace_ms: 30000}).message, /^Closed window · /)
  assert.match(windowTrashToast({label: "", grace_ms: 30000}).message, /^Closed window · /)
})

test("a missing or nonsense grace period still yields a usable toast", () => {
  // A zero/NaN duration would otherwise render a toast that never leaves or one
  // gone before it can be read.
  assert.equal(graceMs(undefined), 30000)
  assert.equal(graceMs(0), 30000)
  assert.equal(graceMs(-5), 30000)
  assert.equal(graceMs("nope"), 30000)
})

test("clamps absurd grace periods at both ends", () => {
  assert.equal(graceMs(10), 1000)
  assert.equal(graceMs(9_999_999), 300000)
  assert.equal(graceMs("45000"), 45000)
})

test("rounds seconds up so the countdown never reads 0s", () => {
  assert.equal(formatSeconds(30000), "30s")
  assert.equal(formatSeconds(29001), "30s")
  assert.equal(formatSeconds(1), "1s")
  assert.equal(formatSeconds(0), "1s")
})
