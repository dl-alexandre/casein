import assert from "node:assert/strict"
import test from "node:test"

import {
  COACH_VERSION,
  MASTERY_THRESHOLD,
  actionKey,
  createState,
  parseState,
  recordUse,
  remainingHints,
  serializeState,
  shouldShowHint,
  usesOf
} from "../js/shortcut_coach.mjs"

test("a fresh operator sees the hint", () => {
  assert.equal(shouldShowHint(createState(), "Ctrl + B, then c"), true)
})

test("the hint retires after the mastery threshold", () => {
  let state = createState()

  for (let i = 0; i < MASTERY_THRESHOLD; i++) {
    assert.equal(shouldShowHint(state, "Ctrl + B, then c"), true, `sighting ${i + 1}`)
    state = recordUse(state, "Ctrl + B, then c")
  }

  assert.equal(shouldShowHint(state, "Ctrl + B, then c"), false)
  assert.equal(remainingHints(state, "Ctrl + B, then c"), 0)
})

test("mastery is per action, not global", () => {
  let state = createState()
  for (let i = 0; i < MASTERY_THRESHOLD; i++) state = recordUse(state, "Ctrl + B, then c")

  assert.equal(shouldShowHint(state, "Ctrl + B, then c"), false)
  assert.equal(shouldShowHint(state, "Ctrl + B, then x"), true)
})

test("use counts saturate so stored numbers stay bounded", () => {
  let state = createState()
  for (let i = 0; i < 50; i++) state = recordUse(state, "Ctrl + B, then c")

  assert.equal(usesOf(state, "Ctrl + B, then c"), MASTERY_THRESHOLD)
})

// A toggling button relabels itself ("Zoom pane" / "Unzoom pane") while keeping
// one chord. Keying on the shortcut means it still reaches mastery.
test("the action key normalizes whitespace and case", () => {
  assert.equal(actionKey("Ctrl + B, then Z"), actionKey("ctrl  +  b,   then  z"))

  let state = recordUse(createState(), "Ctrl + B, then z")
  assert.equal(usesOf(state, "ctrl + b, then z"), 1)
})

test("a missing shortcut never shows a hint", () => {
  assert.equal(actionKey(null), null)
  assert.equal(actionKey("   "), null)
  assert.equal(shouldShowHint(createState(), null), false)
  assert.equal(shouldShowHint(createState(), ""), false)
})

test("recordUse on a missing shortcut is a no-op", () => {
  const state = createState()
  assert.equal(recordUse(state, null), state)
})

test("the preference wins over remaining decay", () => {
  assert.equal(shouldShowHint(createState(), "Ctrl + B, then c", {enabled: false}), false)
  assert.equal(shouldShowHint(createState(), "Ctrl + B, then c", {enabled: true}), true)
})

test("state round-trips through storage", () => {
  const state = recordUse(createState(), "Ctrl + B, then c")
  const restored = parseState(serializeState(state))

  assert.deepEqual(restored, state)
  assert.equal(shouldShowHint(restored, "Ctrl + B, then c"), true)
})

test("a stale coach version resets the decay", () => {
  const stale = JSON.stringify({v: "0", uses: {"ctrl + b, then c": 99}})
  assert.deepEqual(parseState(stale), createState())
  assert.equal(shouldShowHint(parseState(stale), "Ctrl + B, then c"), true)
})

test("corrupt or absent storage degrades to a fresh state", () => {
  assert.deepEqual(parseState(null), createState())
  assert.deepEqual(parseState(""), createState())
  assert.deepEqual(parseState("{not json"), createState())
  assert.deepEqual(parseState(JSON.stringify({v: COACH_VERSION})), createState())
  assert.deepEqual(parseState(JSON.stringify(null)), createState())
})

test("recordUse does not mutate the input state", () => {
  const state = createState()
  const snapshot = JSON.stringify(state)
  recordUse(state, "Ctrl + B, then c")
  assert.equal(JSON.stringify(state), snapshot)
})
