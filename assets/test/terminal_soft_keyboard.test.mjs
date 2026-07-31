// Which Enter presses give the phone its rows back.
//
// The exclusions are the whole risk surface: the mobile key bar synthesizes
// Enter keydowns when pasting multi-line text (dismissing mid-paste would
// strand the remaining lines), and agent composers read a modified Enter as
// "newline, don't submit" — the operator is still writing.

import assert from "node:assert/strict"
import test from "node:test"

import {enterDismissesSoftKeyboard} from "../js/terminal_soft_keyboard.mjs"

const keystroke = (over = {}) => ({isTrusted: true, key: "Enter", ...over})

test("a plain Enter keystroke dismisses the keyboard", () => {
  assert.equal(enterDismissesSoftKeyboard(keystroke()), true)
})

test("only Enter dismisses", () => {
  for (const key of ["a", "Escape", "ArrowUp", "Tab", "Backspace"]) {
    assert.equal(enterDismissesSoftKeyboard(keystroke({key})), false, key)
  }
  assert.equal(enterDismissesSoftKeyboard(null), false)
  assert.equal(enterDismissesSoftKeyboard({}), false)
})

test("synthesized Enter (key bar paste) never dismisses", () => {
  assert.equal(enterDismissesSoftKeyboard(keystroke({isTrusted: false})), false)
})

test("a modified Enter is a composer newline, not a submit", () => {
  for (const modifier of ["shiftKey", "altKey", "ctrlKey", "metaKey"]) {
    assert.equal(enterDismissesSoftKeyboard(keystroke({[modifier]: true})), false, modifier)
  }
})

test("an IME composition Enter commits a candidate, not the line", () => {
  assert.equal(enterDismissesSoftKeyboard(keystroke({isComposing: true})), false)
  // Pre-`isComposing` browsers still flag composition with keyCode 229.
  assert.equal(enterDismissesSoftKeyboard(keystroke({keyCode: 229})), false)
})
