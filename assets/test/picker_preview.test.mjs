import test from "node:test"
import assert from "node:assert/strict"

import {previewCacheKey, previewTarget} from "../js/picker_preview.mjs"

test("previewTarget reads session/window/pane attrs", () => {
  const el = {
    getAttribute(name) {
      if (name === "phx-value-tmux-session") return "casein_ws_main"
      if (name === "phx-value-window-id") return "@1"
      if (name === "phx-value-pane-id") return "%3"
      return null
    },
  }
  assert.deepEqual(previewTarget(el), {
    "tmux-session": "casein_ws_main",
    "window-id": "@1",
    "pane-id": "%3",
  })
})

test("previewTarget is null when the row has no capture target", () => {
  const el = {getAttribute() { return null }}
  assert.equal(previewTarget(el), null)
})

test("previewCacheKey distinguishes pane targets so a window cache is not reused", () => {
  assert.notEqual(
    previewCacheKey({"window-id": "@1"}),
    previewCacheKey({"window-id": "@1", "pane-id": "%3"}),
  )
})
