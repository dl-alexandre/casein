import test from "node:test"
import assert from "node:assert/strict"
import {JSDOM} from "jsdom"

import {
  insertionNeighbor,
  movePayload,
  previewTabMove,
  restoreTabOrder,
} from "../js/window_tab_reorder.mjs"

function tab(document, id, left) {
  const node = document.createElement("div")
  node.dataset.ctxWindowId = id
  node.getBoundingClientRect = () => ({left, width: 100})
  return node
}

function fixture() {
  const {document} = new JSDOM("<div id='strip'></div>").window
  const strip = document.querySelector("#strip")
  const tabs = [
    tab(document, "@0", 0),
    tab(document, "@1", 100),
    tab(document, "@2", 200),
  ]
  tabs.forEach((node) => strip.appendChild(node))
  return {strip, tabs}
}

function ids(strip) {
  return [...strip.children].map((node) => node.dataset.ctxWindowId)
}

test("insertionNeighbor ignores the dragged tab and uses tab midpoints", () => {
  const {tabs} = fixture()

  assert.deepEqual(
    insertionNeighbor(tabs, "@0", 140),
    {id: "@1", placement: "before", tab: tabs[1]},
  )
  assert.deepEqual(
    insertionNeighbor(tabs, "@0", 400),
    {id: "@2", placement: "after", tab: tabs[2]},
  )
})

test("previewTabMove reorders the local strip immediately", () => {
  const {strip, tabs} = fixture()

  assert.equal(
    previewTabMove(tabs[0], {id: "@2", placement: "after", tab: tabs[2]}),
    true,
  )
  assert.deepEqual(ids(strip), ["@1", "@2", "@0"])
})

test("previewTabMove reports a no-op at the current insertion boundary", () => {
  const {strip, tabs} = fixture()

  assert.equal(
    previewTabMove(tabs[0], {id: "@1", placement: "before", tab: tabs[1]}),
    false,
  )
  assert.deepEqual(ids(strip), ["@0", "@1", "@2"])
})

test("restoreTabOrder rolls a cancelled drag back", () => {
  const {strip, tabs} = fixture()
  previewTabMove(tabs[0], {id: "@2", placement: "after", tab: tabs[2]})

  restoreTabOrder(strip, ["@0", "@1", "@2"])

  assert.deepEqual(ids(strip), ["@0", "@1", "@2"])
})

test("movePayload preserves before and after placement", () => {
  assert.deepEqual(
    movePayload("@2", {id: "@0", placement: "before"}),
    {"window-id": "@2", "before-window-id": "@0"},
  )
  assert.deepEqual(
    movePayload("@0", {id: "@2", placement: "after"}),
    {"window-id": "@0", "before-window-id": "@2", dir: "after"},
  )
})
