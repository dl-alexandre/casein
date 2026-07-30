import assert from "node:assert/strict"
import test from "node:test"

import {
  LANE_HINT,
  LANE_MESSAGE,
  MAX_QUEUED,
  PREEMPT_CUT_MS,
  createQueue,
  dismiss,
  enqueue,
  nextDeadline,
  pendingCount,
  tick,
  visible
} from "../js/toast_queue.mjs"

const info = (text) => ({text, kind: "info"})
const error = (text) => ({text, kind: "error"})

test("blank messages are ignored", () => {
  const state = createQueue()
  assert.equal(enqueue(state, info("")), state)
  assert.equal(enqueue(state, info("   ")), state)
  assert.equal(enqueue(state, {kind: "info"}), state)
})

test("first message becomes visible immediately", () => {
  const state = enqueue(createQueue(), info("Copied to clipboard"), 1000)
  const shown = visible(state)

  assert.equal(shown[LANE_MESSAGE].text, "Copied to clipboard")
  assert.equal(shown[LANE_MESSAGE].kind, "info")
  assert.equal(shown[LANE_HINT], null)
  assert.equal(nextDeadline(state), 5000)
})

// The whole point of the queue: the old single-node presenter replaced the
// visible text mid-display, so a second action erased the first one's result.
test("a second distinct message queues instead of clobbering the visible one", () => {
  let state = enqueue(createQueue(), info("Copied to clipboard"), 0)
  state = enqueue(state, info("Selection sent to the agent"), 100)

  assert.equal(visible(state)[LANE_MESSAGE].text, "Copied to clipboard")
  assert.equal(pendingCount(state), 1)

  state = tick(state, 4000)
  assert.equal(visible(state)[LANE_MESSAGE].text, "Selection sent to the agent")
  assert.equal(pendingCount(state), 0)
})

test("repeating the visible message groups it rather than restarting the node", () => {
  let state = enqueue(createQueue(), info("Copied to clipboard"), 0)
  state = enqueue(state, info("Copied to clipboard"), 1000)

  const shown = visible(state)
  assert.equal(shown[LANE_MESSAGE].count, 2)
  assert.equal(pendingCount(state), 0)
  // Extended from the repeat, not from the original enqueue.
  assert.equal(shown[LANE_MESSAGE].expiresAt, 5000)
})

test("action payload follows the newest grouped message", () => {
  const first = [{label: "Copy", onClick: () => "first"}]
  const latest = [{label: "Copy", onClick: () => "latest"}]
  let state = enqueue(createQueue(), {...info("Agent copied text"), actions: first}, 0)
  state = enqueue(state, {...info("Agent copied text"), actions: latest}, 100)

  assert.equal(visible(state)[LANE_MESSAGE].actions, latest)
})

test("repeating a queued message groups it in place", () => {
  let state = enqueue(createQueue(), info("first"), 0)
  state = enqueue(state, error("boom"), 0)
  state = enqueue(state, error("boom"), 10)

  assert.equal(pendingCount(state), 1)
  assert.equal(state[LANE_MESSAGE].queue[0].count, 2)
})

test("errors jump the queue ahead of waiting info messages", () => {
  let state = enqueue(createQueue(), info("visible"), 0)
  state = enqueue(state, info("waiting"), 0)
  state = enqueue(state, error("failed to save"), 0)

  assert.deepEqual(
    state[LANE_MESSAGE].queue.map((item) => item.text),
    ["failed to save", "waiting"]
  )
})

test("an error truncates the visible low-priority message instead of dropping it", () => {
  let state = enqueue(createQueue(), info("Copied to clipboard"), 0)
  assert.equal(visible(state)[LANE_MESSAGE].expiresAt, 4000)

  state = enqueue(state, error("Copy failed"), 1000)

  // Still on screen, but cut short — nothing is silently discarded.
  assert.equal(visible(state)[LANE_MESSAGE].text, "Copied to clipboard")
  assert.equal(visible(state)[LANE_MESSAGE].expiresAt, 1000 + PREEMPT_CUT_MS)

  state = tick(state, 1000 + PREEMPT_CUT_MS)
  assert.equal(visible(state)[LANE_MESSAGE].text, "Copy failed")
})

test("equal priority does not truncate the visible message", () => {
  let state = enqueue(createQueue(), error("first failure"), 0)
  const before = visible(state)[LANE_MESSAGE].expiresAt

  state = enqueue(state, error("second failure"), 500)
  assert.equal(visible(state)[LANE_MESSAGE].expiresAt, before)
})

test("hints occupy a separate lane and never delay a message", () => {
  let state = enqueue(createQueue(), info("Copied to clipboard"), 0)
  state = enqueue(state, {text: "Press Ctrl + B, then c", kind: "shortcut"}, 0)

  const shown = visible(state)
  assert.equal(shown[LANE_MESSAGE].text, "Copied to clipboard")
  assert.equal(shown[LANE_HINT].text, "Press Ctrl + B, then c")
  assert.equal(pendingCount(state), 0)
})

test("a newer hint replaces the older one outright", () => {
  let state = enqueue(createQueue(), {text: "hint one", kind: "shortcut"}, 0)
  state = enqueue(state, {text: "hint two", kind: "shortcut"}, 100)

  assert.equal(visible(state)[LANE_HINT].text, "hint two")
  assert.equal(state[LANE_HINT].queue.length, 0)
})

test("lanes expire independently", () => {
  let state = enqueue(createQueue(), info("message"), 0)
  state = enqueue(state, {text: "hint", kind: "shortcut"}, 0)

  // Hint duration (2600) is shorter than info (4000).
  state = tick(state, 2600)
  assert.equal(visible(state)[LANE_HINT], null)
  assert.equal(visible(state)[LANE_MESSAGE].text, "message")

  state = tick(state, 4000)
  assert.equal(visible(state)[LANE_MESSAGE], null)
})

test("nextDeadline is the earliest live deadline and null when idle", () => {
  const state = createQueue()
  assert.equal(nextDeadline(state), null)

  let live = enqueue(state, info("message"), 0)
  live = enqueue(live, {text: "hint", kind: "shortcut"}, 0)
  assert.equal(nextDeadline(live), 2600)

  assert.equal(nextDeadline(tick(live, 4000)), null)
})

test("dismiss retires the visible item and promotes the next", () => {
  let state = enqueue(createQueue(), info("first"), 0)
  state = enqueue(state, info("second"), 0)

  state = dismiss(state, LANE_MESSAGE, 500)
  assert.equal(visible(state)[LANE_MESSAGE].text, "second")
  assert.equal(visible(state)[LANE_MESSAGE].expiresAt, 4500)
})

test("dismiss on an empty lane is a no-op", () => {
  const state = createQueue()
  assert.equal(dismiss(state, LANE_MESSAGE, 0), state)
})

test("the queue sheds the least important backlog past the cap", () => {
  let state = enqueue(createQueue(), error("visible"), 0)
  for (let i = 0; i < MAX_QUEUED + 4; i++) {
    state = enqueue(state, info(`info ${i}`), 0)
  }

  assert.equal(pendingCount(state), MAX_QUEUED)
  assert.equal(state.dropped, 4)
})

test("unknown kinds fall back to info priority and duration", () => {
  const state = enqueue(createQueue(), {text: "odd", kind: "banana"}, 0)
  assert.equal(visible(state)[LANE_MESSAGE].kind, "info")
  assert.equal(nextDeadline(state), 4000)
})

test("enqueue does not mutate the input state", () => {
  const state = createQueue()
  const snapshot = JSON.stringify(state)
  enqueue(state, info("message"), 0)
  assert.equal(JSON.stringify(state), snapshot)
})
