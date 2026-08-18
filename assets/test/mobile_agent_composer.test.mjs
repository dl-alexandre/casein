import assert from "node:assert/strict"
import test from "node:test"

import {clearComposerText, truncateUtf8} from "../js/mobile_agent_composer.mjs"

function root(paneId, textarea = null) {
  return {
    dataset: {paneId},
    querySelector: () => textarea,
  }
}

test("clears and keeps focus after confirmed delivery", () => {
  const textarea = {
    value: "ship this",
    focusOptions: null,
    focus(options) { this.focusOptions = options },
  }

  assert.equal(clearComposerText(root("%7", textarea), "%7"), true)
  assert.equal(textarea.value, "")
  assert.deepEqual(textarea.focusOptions, {preventScroll: true})
})

test("does not clear a composer for another pane", () => {
  const textarea = {value: "keep this", focus() {}}

  assert.equal(clearComposerText(root("%8", textarea), "%7"), false)
  assert.equal(textarea.value, "keep this")
})

test("uses the slot byte limit without splitting multibyte characters", () => {
  assert.equal(truncateUtf8("ab😀cd", 6), "ab😀")
  assert.equal(truncateUtf8("ééé", 5), "éé")
  assert.equal(truncateUtf8("native input", 20), "native input")
})
