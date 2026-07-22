import test from "node:test"
import assert from "node:assert/strict"

import {TmuxTransitionCoordinator} from "../js/tmux_transition_coordinator.mjs"

test("runs capture, commit, confirmed apply, animation, and cleanup in order", async () => {
  const calls = []
  const coordinator = new TmuxTransitionCoordinator()
  const frozen = {id: "frame"}

  const result = await coordinator.run({
    base: {version: 10},
    capture(base) {
      calls.push(["capture", base.version])
      return frozen
    },
    preview() {
      calls.push(["preview"])
    },
    async commit(base) {
      calls.push(["commit", base.version])
      return {ok: true, layout_version: 11}
    },
    async applyConfirmed(confirmed) {
      calls.push(["apply", confirmed.layout_version])
    },
    async animate({frozen: captured, confirmed}) {
      calls.push(["animate", captured.id, confirmed.layout_version])
    },
    cleanup(captured) {
      calls.push(["cleanup", captured.id])
    },
  })

  assert.equal(result.ok, true)
  assert.deepEqual(calls, [
    ["capture", 10],
    ["preview"],
    ["commit", 10],
    ["apply", 11],
    ["animate", "frame", 11],
    ["cleanup", "frame"],
  ])
  assert.equal(coordinator.activeTransition, null)
})

test("rolls back a rejected commit and always cleans up", async () => {
  const calls = []
  const coordinator = new TmuxTransitionCoordinator()

  const result = await coordinator.run({
    base: {version: 4},
    capture: () => ({id: "frozen"}),
    commit: async () => ({ok: false, error: "stale_layout"}),
    rollback({error}) {
      calls.push(["rollback", error.code])
    },
    cleanup(frozen) {
      calls.push(["cleanup", frozen.id])
    },
  })

  assert.equal(result.ok, false)
  assert.equal(result.cancelled, false)
  assert.deepEqual(calls, [
    ["rollback", "stale_layout"],
    ["cleanup", "frozen"],
  ])
})

test("a newer run cancels the prior transition without rolling it back", async () => {
  const calls = []
  const coordinator = new TmuxTransitionCoordinator()
  let finishFirst

  const first = coordinator.run({
    base: {version: 1},
    capture: () => ({id: "first"}),
    commit: () =>
      new Promise((resolve) => {
        finishFirst = resolve
      }),
    rollback: () => calls.push("first-rollback"),
    cleanup: (frozen) => calls.push(`${frozen.id}-cleanup`),
  })

  await Promise.resolve()

  const second = coordinator.run({
    base: {version: 2},
    capture: () => {
      assert.ok(calls.includes("first-cleanup"))
      return {id: "second"}
    },
    commit: async () => ({ok: true, layout_version: 3}),
    cleanup: (frozen) => calls.push(`${frozen.id}-cleanup`),
  })

  finishFirst({ok: true, layout_version: 2})

  const [firstResult, secondResult] = await Promise.all([first, second])
  assert.equal(firstResult.cancelled, true)
  assert.equal(secondResult.ok, true)
  assert.deepEqual(calls.sort(), ["first-cleanup", "second-cleanup"])
})
