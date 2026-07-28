import assert from "node:assert/strict"
import test from "node:test"

import {applyCopySelection, copyInGesture, COPY_FALLBACK_STYLE} from "../js/clipboard_write.mjs"

/**
 * Minimal stand-in for the offscreen <textarea>. Records the call order so the
 * tests can assert on the WebKit-specific sequencing rather than just the
 * end state.
 */
function fakeTarget(overrides = {}) {
  const calls = []
  const target = {
    value: "",
    readOnly: true,
    contentEditable: "inherit",
    calls,
    focus(opts) {
      calls.push(["focus", opts])
    },
    select() {
      calls.push(["select"])
    },
    setSelectionRange(start, end) {
      calls.push(["setSelectionRange", start, end])
    },
    ...overrides
  }
  return target
}

function fakeEnv() {
  const calls = []
  const range = {
    selectNodeContents(node) {
      calls.push(["selectNodeContents", node])
    }
  }
  const selection = {
    removeAllRanges() {
      calls.push(["removeAllRanges"])
    },
    addRange(r) {
      calls.push(["addRange", r])
    }
  }
  return {
    calls,
    range,
    env: {
      doc: {
        createRange() {
          calls.push(["createRange"])
          return range
        }
      },
      win: {
        getSelection() {
          calls.push(["getSelection"])
          return selection
        }
      }
    }
  }
}

test("selects with setSelectionRange, which is what WebKit honours", () => {
  const target = fakeTarget()
  const {env} = fakeEnv()

  assert.equal(applyCopySelection(target, "hello", env), true)

  const ranged = target.calls.find(([name]) => name === "setSelectionRange")
  assert.deepEqual(ranged, ["setSelectionRange", 0, 5])
})

test("puts the text on the target before selecting it", () => {
  const target = fakeTarget()
  const {env} = fakeEnv()

  applyCopySelection(target, "payload", env)

  assert.equal(target.value, "payload")
})

test("establishes a document Range as well as the form-control selection", () => {
  const target = fakeTarget()
  const {calls, env} = fakeEnv()

  applyCopySelection(target, "hello", env)

  const names = calls.map(([name]) => name)
  assert.deepEqual(names, [
    "createRange",
    "selectNodeContents",
    "getSelection",
    "removeAllRanges",
    "addRange"
  ])
})

test("lifts readOnly and contentEditable for the selection, then restores them", () => {
  let readOnlyDuringSelection = null
  let editableDuringSelection = null

  const target = fakeTarget()
  target.setSelectionRange = function () {
    readOnlyDuringSelection = this.readOnly
    editableDuringSelection = this.contentEditable
  }

  applyCopySelection(target, "hello", fakeEnv().env)

  // Both must be relaxed while the selection is taken...
  assert.equal(readOnlyDuringSelection, false)
  assert.equal(editableDuringSelection, "true")
  // ...and put back, so the element stays keyboard-inert on iOS between copies.
  assert.equal(target.readOnly, true)
  assert.equal(target.contentEditable, "inherit")
})

test("focuses without scrolling the page to the offscreen target", () => {
  const target = fakeTarget()
  applyCopySelection(target, "hello", fakeEnv().env)

  const focus = target.calls.find(([name]) => name === "focus")
  assert.deepEqual(focus, ["focus", {preventScroll: true}])
})

test("falls back to select() when setSelectionRange is unavailable", () => {
  const target = fakeTarget({setSelectionRange: undefined})
  assert.equal(applyCopySelection(target, "hello", fakeEnv().env), true)
  assert.ok(target.calls.some(([name]) => name === "select"))
})

test("survives a target that throws on setSelectionRange", () => {
  const target = fakeTarget({
    setSelectionRange() {
      throw new Error("detached")
    }
  })

  // The Range path still established a selection, so this is not a total loss.
  assert.equal(applyCopySelection(target, "hello", fakeEnv().env), true)
})

test("reports failure when neither selection mechanism is available", () => {
  const target = fakeTarget({setSelectionRange: undefined, select: undefined})
  assert.equal(applyCopySelection(target, "hello", {}), false)
})

test("does not throw when the document/window env is missing", () => {
  const target = fakeTarget()
  assert.equal(applyCopySelection(target, "hello", {}), true)
})

test("rejects a missing target or non-string text", () => {
  assert.equal(applyCopySelection(null, "hello", {}), false)
  assert.equal(applyCopySelection(fakeTarget(), undefined, {}), false)
  assert.equal(applyCopySelection(fakeTarget(), 42, {}), false)
})

test("the offscreen target keeps real dimensions and a non-zooming font", () => {
  // Zero-sized or fully transparent elements are unreliable copy sources on
  // WebKit, and a sub-16px font triggers Safari's focus zoom.
  assert.equal(COPY_FALLBACK_STYLE.fontSize, "16px")
  assert.notEqual(COPY_FALLBACK_STYLE.width, "1px")
  assert.notEqual(COPY_FALLBACK_STYLE.height, "1px")
  assert.equal(COPY_FALLBACK_STYLE.opacity, undefined)
})

test("copyInGesture tries the synchronous copy before the async API", () => {
  const order = []
  const ok = copyInGesture("hello", {
    syncCopy: () => {
      order.push("sync")
      return true
    },
    asyncWrite: () => {
      order.push("async")
      return Promise.resolve()
    }
  })

  assert.equal(ok, true)
  // Crucially the async path is never reached — the sync copy already landed.
  assert.deepEqual(order, ["sync"])
})

test("copyInGesture falls back to the async API when the sync copy fails", async () => {
  const order = []
  let settled = null

  const ok = copyInGesture("hello", {
    syncCopy: () => {
      order.push("sync")
      return false
    },
    asyncWrite: () => {
      order.push("async")
      return Promise.resolve()
    },
    onAsyncResult: (result) => {
      settled = result
    }
  })

  assert.equal(ok, true)
  assert.deepEqual(order, ["sync", "async"])
  await Promise.resolve()
  await Promise.resolve()
  assert.equal(settled, true)
})

test("copyInGesture reports an async rejection instead of claiming success", async () => {
  let settled = null

  copyInGesture("hello", {
    syncCopy: () => false,
    asyncWrite: () => Promise.reject(new Error("NotAllowedError")),
    onAsyncResult: (result) => {
      settled = result
    }
  })

  await Promise.resolve()
  await Promise.resolve()
  assert.equal(settled, false)
})

test("copyInGesture reports failure when both paths are unavailable", () => {
  assert.equal(copyInGesture("hello", {syncCopy: () => false}), false)
  assert.equal(copyInGesture("", {syncCopy: () => true}), false)
})

test("copyInGesture tolerates an asyncWrite that returns nothing", () => {
  // navigator.clipboard?.writeText?.(…) is undefined when the API is absent.
  assert.equal(copyInGesture("hello", {syncCopy: () => false, asyncWrite: () => undefined}), false)
})
