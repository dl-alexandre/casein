import assert from "node:assert/strict"
import test from "node:test"

import {JSDOM} from "jsdom"

import {terminalInputMode} from "../js/terminal_input_mode.mjs"

test("coarse pointers suppress implicit OS keyboard ownership", () => {
  assert.equal(terminalInputMode({coarsePointer: true}), "none")
  assert.equal(
    terminalInputMode({coarsePointer: true, keyboardRequested: true}),
    "text"
  )
})

test("fine pointers retain normal keyboard input", () => {
  assert.equal(terminalInputMode({coarsePointer: false}), "text")
})

test("the predicate drives the textarea inputmode attribute reactively", () => {
  const dom = new JSDOM('<textarea data-ghostty-input="true"></textarea>')
  const input = dom.window.document.querySelector("textarea")
  const sync = (state) => input.setAttribute("inputmode", terminalInputMode(state))

  sync({coarsePointer: true})
  assert.equal(input.getAttribute("inputmode"), "none")

  sync({coarsePointer: true, keyboardRequested: true})
  assert.equal(input.getAttribute("inputmode"), "text")

  sync({coarsePointer: false})
  assert.equal(input.getAttribute("inputmode"), "text")
})

test("inputmode none leaves the mobile key bar's synthetic key path intact", () => {
  const dom = new JSDOM('<textarea data-ghostty-input="true"></textarea>')
  const input = dom.window.document.querySelector("textarea")
  input.setAttribute("inputmode", terminalInputMode({coarsePointer: true}))

  let received = null
  input.addEventListener("keydown", (event) => {
    received = {key: event.key, ctrlKey: event.ctrlKey, isTrusted: event.isTrusted}
  })
  input.dispatchEvent(
    new dom.window.KeyboardEvent("keydown", {key: "c", ctrlKey: true, bubbles: true})
  )

  assert.deepEqual(received, {key: "c", ctrlKey: true, isTrusted: false})
  assert.equal(input.getAttribute("inputmode"), "none")
})
