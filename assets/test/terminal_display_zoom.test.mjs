import assert from "node:assert/strict"
import test from "node:test"

import {
  adjustDisplayZoom,
  clampDisplayZoom,
  displayZoomStorageKey,
  formatDisplayZoomPercent
} from "../js/terminal_display_zoom.mjs"

test("clampDisplayZoom keeps zoom inside the supported range", () => {
  assert.equal(clampDisplayZoom(1), 1)
  assert.equal(clampDisplayZoom(0.1), 0.5)
  assert.equal(clampDisplayZoom(9), 3)
  assert.equal(clampDisplayZoom(Number.NaN), 1)
})

test("adjustDisplayZoom steps and resets", () => {
  assert.equal(adjustDisplayZoom(1, {delta: 0.1}), 1.1)
  assert.equal(adjustDisplayZoom(3, {delta: 0.2}), 3)
  assert.equal(adjustDisplayZoom(0.6, {delta: -0.2}), 0.5)
  assert.equal(adjustDisplayZoom(2, {reset: true}), 1)
})

test("formatDisplayZoomPercent renders whole percentages", () => {
  assert.equal(formatDisplayZoomPercent(1), "100%")
  assert.equal(formatDisplayZoomPercent(1.25), "125%")
})

test("displayZoomStorageKey scopes zoom per surface", () => {
  assert.equal(
    displayZoomStorageKey("terminal-surface-ws-1", "ghostty-pane-1"),
    "casein:term-display-zoom:terminal-surface-ws-1"
  )
  assert.equal(displayZoomStorageKey(null, "ghostty-pane-1"), "casein:term-display-zoom:ghostty-pane-1")
})