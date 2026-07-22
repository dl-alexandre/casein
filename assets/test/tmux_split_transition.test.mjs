import test from "node:test"
import assert from "node:assert/strict"

import {animateSplitTransition, splitAnimationTargets} from "../js/tmux_split_transition.mjs"

const BEFORE = {
  version: 10,
  activePaneId: "%1",
  bounds: {width: 100, height: 40},
  panes: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
}

const CONFIRMED = {
  layout_version: 11,
  zoomed: false,
  active_pane_id: "%2",
  bounds: {width: 100, height: 40},
  pane_rects: [
    {id: "%1", left: 0, top: 0, width: 50, height: 40},
    {id: "%2", left: 50, top: 0, width: 50, height: 40},
  ],
}

test("clips the frozen source pane to its confirmed tmux rectangle", () => {
  assert.deepEqual(splitAnimationTargets(BEFORE, CONFIRMED, {width: 1000, height: 400}), [
    {
      id: "%1",
      source: true,
      from: {left: 0, top: 0, width: 1000, height: 400},
      to: {left: 0, top: 0, width: 500, height: 400},
    },
  ])
})

test("settles geometry before crossfading the frozen pane", async () => {
  const previousWindow = globalThis.window
  const previousElement = globalThis.Element
  const calls = []

  globalThis.window = {matchMedia: () => ({matches: false})}
  globalThis.Element = class Element {}

  const pane = {
    el: {
      style: {},
      animate(keyframes, options) {
        calls.push({keyframes, options})
        return {finished: Promise.resolve(), cancel() {}}
      },
    },
  }

  try {
    await animateSplitTransition({
      frozen: {
        panes: new Map([["%1", pane]]),
        layoutRect: {width: 1000, height: 400},
      },
      before: BEFORE,
      confirmed: CONFIRMED,
    })

    assert.equal(calls.length, 1)
    assert.equal(pane.el.style.zIndex, "2")
    assert.deepEqual(calls[0].keyframes[1], {
      left: "0px",
      top: "0px",
      width: "500px",
      height: "400px",
      opacity: 1,
      offset: 0.74,
    })
    assert.equal(calls[0].keyframes[2].opacity, 0)
    assert.equal(calls[0].options.duration, 190)
  } finally {
    if (previousWindow === undefined) delete globalThis.window
    else globalThis.window = previousWindow

    if (previousElement === undefined) delete globalThis.Element
    else globalThis.Element = previousElement
  }
})

test("reduced motion skips split animation", async () => {
  const previousWindow = globalThis.window
  const previousElement = globalThis.Element
  let animationCalls = 0

  globalThis.window = {matchMedia: () => ({matches: true})}
  globalThis.Element = class Element {}

  try {
    await animateSplitTransition({
      frozen: {
        panes: new Map([["%1", {el: {animate: () => (animationCalls += 1)}}]]),
        layoutRect: {width: 1000, height: 400},
      },
      before: BEFORE,
      confirmed: CONFIRMED,
    })

    assert.equal(animationCalls, 0)
  } finally {
    if (previousWindow === undefined) delete globalThis.window
    else globalThis.window = previousWindow

    if (previousElement === undefined) delete globalThis.Element
    else globalThis.Element = previousElement
  }
})
