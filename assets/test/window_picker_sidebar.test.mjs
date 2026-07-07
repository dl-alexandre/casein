import test from "node:test"
import assert from "node:assert/strict"

import {itemFilterText, matchesPickerFilter} from "../js/window_picker_sidebar_utils.mjs"

function mockPickerItem({index = "", label = ""} = {}) {
  return {
    querySelector(selector) {
      if (selector === "[data-picker-label]") return {textContent: label}
      if (selector === ".font-mono" && index !== "") return {textContent: index}
      return null
    },
  }
}

test("itemFilterText lowercases index and label", () => {
  const item = mockPickerItem({index: "2", label: "Agent"})
  assert.equal(itemFilterText(item), "2 agent")
})

test("matchesPickerFilter accepts empty query", () => {
  const item = mockPickerItem({index: "1", label: "Verify"})
  assert.equal(matchesPickerFilter(item, ""), true)
})

test("matchesPickerFilter matches substrings case-insensitively", () => {
  const item = mockPickerItem({index: "3", label: "in-progress-sidebar-cleanup"})
  assert.equal(matchesPickerFilter(item, "SIDEBAR"), true)
  assert.equal(matchesPickerFilter(item, "nope"), false)
})
