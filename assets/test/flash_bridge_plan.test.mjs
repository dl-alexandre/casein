import assert from "node:assert/strict"
import test from "node:test"

import {HOISTED_FLASHES, planHoist} from "../js/flash_bridge_plan.mjs"

const present = (key, message, kind = key) => ({key, kind, message})

test("only info and error flashes are hoisted", () => {
  assert.deepEqual(
    HOISTED_FLASHES.map((entry) => entry.key),
    ["info", "error"]
  )

  // The reconnect banners are connection state, not events — they must stay put.
  const selectors = HOISTED_FLASHES.map((entry) => entry.selector)
  assert.ok(!selectors.includes("#client-error"))
  assert.ok(!selectors.includes("#server-error"))
})

test("a fresh flash is hoisted and remembered", () => {
  const {hoist, lastHoisted} = planHoist([present("error", "Boom")], {})

  assert.deepEqual(hoist, [{key: "error", kind: "error", message: "Boom"}])
  assert.equal(lastHoisted.error, "Boom")
})

// The hook re-runs on every diff; the window between hoisting and the server
// clearing the flash must not produce a second toast.
test("a re-render before the server clears does not double-toast", () => {
  const first = planHoist([present("error", "Boom")], {})
  const second = planHoist([present("error", "Boom")], first.lastHoisted)

  assert.deepEqual(second.hoist, [])
  assert.equal(second.lastHoisted.error, "Boom")
})

// Without this the same error text could never toast again for the life of the
// LiveView — the memo would pin it forever.
test("a cleared flash is forgotten so the same text can toast again", () => {
  const first = planHoist([present("error", "Boom")], {})
  const cleared = planHoist([], first.lastHoisted)

  assert.deepEqual(cleared.hoist, [])
  assert.equal(cleared.lastHoisted.error, null)

  const again = planHoist([present("error", "Boom")], cleared.lastHoisted)
  assert.deepEqual(again.hoist, [{key: "error", kind: "error", message: "Boom"}])
})

test("a changed message hoists even without a clear in between", () => {
  const first = planHoist([present("error", "Boom")], {})
  const second = planHoist([present("error", "Different")], first.lastHoisted)

  assert.deepEqual(second.hoist, [{key: "error", kind: "error", message: "Different"}])
})

test("both lanes can hoist in one pass, in configured order", () => {
  const {hoist} = planHoist([present("error", "Boom"), present("info", "Saved")], {})

  assert.deepEqual(
    hoist.map((entry) => entry.key),
    ["info", "error"]
  )
})

test("blank and whitespace-only messages are ignored without being remembered", () => {
  for (const blank of ["", "   ", null, undefined]) {
    const {hoist, lastHoisted} = planHoist([present("error", blank)], {})
    assert.deepEqual(hoist, [], `blank: ${JSON.stringify(blank)}`)
    assert.equal(lastHoisted.error, undefined)
  }
})

test("surrounding whitespace is trimmed before hoisting", () => {
  const {hoist} = planHoist([present("error", "  Boom\n")], {})
  assert.deepEqual(hoist, [{key: "error", kind: "error", message: "Boom"}])
})

test("an unknown flash key is ignored", () => {
  const {hoist} = planHoist([present("gossip", "not a flash")], {})
  assert.deepEqual(hoist, [])
})

test("defaults tolerate being called with no arguments", () => {
  const {hoist, lastHoisted} = planHoist()
  assert.deepEqual(hoist, [])
  assert.deepEqual(lastHoisted, {info: null, error: null})
})

test("the input memo is not mutated", () => {
  const memo = {}
  planHoist([present("error", "Boom")], memo)
  assert.deepEqual(memo, {})
})
