import test from "node:test"
import assert from "node:assert/strict"

import {
  itemFilterText,
  matchesPickerFilter,
  itemSubtreeMatches,
  buildPickerTree,
  applyTreePickerFilter,
} from "../js/window_picker_sidebar_utils.mjs"

function mockPickerItem({index = "", label = "", parent = null, branchId = null, id = null} = {}) {
  return {
    id,
    style: {display: ""},
    classList: {
      _hidden: false,
      contains(name) {
        return name === "hidden" && this._hidden
      },
      add(name) {
        if (name === "hidden") this._hidden = true
      },
      remove(name) {
        if (name === "hidden") this._hidden = false
      },
    },
    dataset: {},
    getAttribute(name) {
      if (name === "data-picker-parent") return parent
      if (name === "data-picker-branch-id") return branchId
      if (name === "data-picker-sessions-id") return branchId
      if (name === "data-picker-collapsed") return this._collapsed ? "" : null
      if (name === "data-picker-search") return this._search || null
      return null
    },
    _collapsed: false,
    querySelector(selector) {
      if (selector === "[data-picker-label]") return this._labelNode
      if (selector === ".font-mono" && index !== "") return {textContent: index}
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-picker-item]") return this._childItems || []
      if (selector === "[data-picker-label]") return this._labelNode ? [this._labelNode] : []
      return []
    },
    _labelNode: {
      textContent: label,
      getAttribute(name) {
        if (name === "data-picker-label") return this._full || ""
        return null
      },
      _full: "",
    },
  }
}

function mockBranch({collapsed = true, childItems = []} = {}) {
  const children = {
    _collapsed: collapsed,
    classList: {
      _hidden: collapsed,
      contains(name) {
        return name === "hidden" && this._hidden
      },
      add(name) {
        if (name === "hidden") this._hidden = true
      },
      remove(name) {
        if (name === "hidden") this._hidden = false
      },
    },
    dataset: {},
    getAttribute(name) {
      if (name === "data-picker-collapsed") return collapsed ? "" : null
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-picker-item]") return childItems
      return []
    },
  }

  return {
    style: {display: ""},
    _childItems: childItems,
    _children: children,
    querySelector(selector) {
      if (selector === "[data-picker-item]") return childItems[0] || null
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-picker-item]") return childItems
      if (selector === "[data-picker-branch-children]") return [children]
      if (selector === "[data-picker-tree-branch]") return [this]
      return []
    },
    children: children,
  }
}

function mockRoot({items = [], branches = [], filterEl = null} = {}) {
  return {
    querySelector(selector) {
      if (selector === "[data-picker-filter]") return filterEl
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-picker-item]") return items
      if (selector === "[data-picker-tree-branch]") return branches
      if (selector === "[data-picker-branch-children]") {
        return branches.flatMap((branch) => branch.querySelectorAll("[data-picker-branch-children]"))
      }
      return []
    },
  }
}

test("itemFilterText lowercases index and label", () => {
  const item = mockPickerItem({index: "2", label: "Agent"})
  assert.equal(itemFilterText(item), "2 agent")
})

test("itemFilterText matches the full id when visible text is middle-truncated", () => {
  const full = "agent-opencode-b921-perf-lifecycle-events-20260813013053"
  const item = mockPickerItem({index: "1", label: "agent-openc…13053"})
  item._labelNode._full = full
  assert.match(itemFilterText(item), /b921-perf-lifecycle-events/)
  assert.equal(matchesPickerFilter(item, "b921-perf"), true)
  assert.equal(matchesPickerFilter(item, "13013053"), true)
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

test("itemSubtreeMatches keeps ancestors when a child leaf matches", () => {
  const parent = mockPickerItem({branchId: "sidebar-window--1", label: "main"})
  const child = mockPickerItem({parent: "sidebar-window--1", label: "agent pane"})
  const {childrenByParent} = buildPickerTree([parent, child])

  assert.equal(itemSubtreeMatches(parent, "agent", childrenByParent, matchesPickerFilter), true)
  assert.equal(itemSubtreeMatches(parent, "missing", childrenByParent, matchesPickerFilter), false)
})

test("applyTreePickerFilter reveals matching pane ancestors and expands branch", () => {
  const pane = mockPickerItem({parent: "sidebar-window--1", label: "agent"})
  const window = mockPickerItem({branchId: "sidebar-window--1", label: "main"})
  const branch = mockBranch({collapsed: true, childItems: [window, pane]})
  const root = mockRoot({items: [window, pane], branches: [branch]})

  applyTreePickerFilter(root, "agent")

  assert.equal(window.style.display, "")
  assert.equal(pane.style.display, "")
  assert.equal(branch.children.classList.contains("hidden"), false)
  assert.equal(branch.children.dataset.pickerFilterExpanded, "true")
})

test("applyTreePickerFilter restores collapsed branches when filter clears", () => {
  const pane = mockPickerItem({parent: "sidebar-window--1", label: "agent"})
  const window = mockPickerItem({branchId: "sidebar-window--1", label: "main"})
  const branch = mockBranch({collapsed: true, childItems: [window, pane]})
  const filterEl = {textContent: "", style: {display: "none"}}
  const root = mockRoot({items: [window, pane], branches: [branch], filterEl})

  applyTreePickerFilter(root, "agent")
  applyTreePickerFilter(root, "")

  assert.equal(branch.children.classList.contains("hidden"), true)
  assert.equal(branch.children.dataset.pickerFilterExpanded, undefined)
})