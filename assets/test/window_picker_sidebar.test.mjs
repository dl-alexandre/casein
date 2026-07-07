import test from "node:test"
import assert from "node:assert/strict"

import {itemFilterText, matchesPickerFilter} from "../js/window_picker_sidebar_utils.mjs"

function mockPickerItem({index = "", label = ""} = {}) {
  const item = document.createElement("a")

  if (index !== "") {
    const indexEl = document.createElement("span")
    indexEl.className = "font-mono"
    indexEl.textContent = index
    item.appendChild(indexEl)
  }

  const labelEl = document.createElement("span")
  labelEl.setAttribute("data-picker-label", "")
  labelEl.textContent = label
  item.appendChild(labelEl)

  return item
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
