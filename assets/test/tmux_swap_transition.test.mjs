import test from "node:test"
import assert from "node:assert/strict"

import {animateSwapTransition, swapAnimationTargets} from "../js/tmux_swap_transition.mjs"

const BEFORE = {
  version: 10,
  activePaneId: "%1",
  bounds: {width: 100, height: 40},
  panes: [
    {id: "%1", left: 0, top: 0, width: 60, height: 40},
    {id: "%2", left: 60, top: 0, width: 40, height: 40},
  ],
}

const CONFIRMED = {
  layout_version: 11,
  zoomed: false,
  active_pane_id: "%1",
  bounds: {width: 100, height: 40},
  pane_rects: [
    {id: "%2", left: 0, top: 0, width: 60, height: 40},
    {id: "%1", left: 60, top: 0, width: 40, height: 40},
  ],
}

test("moves frozen pane identities to their confirmed tmux rectangles", () => {
  const targets = swapAnimationTargets(BEFORE, CONFIRMED, {width: 1000, height: 400})

  assert.deepEqual(targets[0], {
    id: "%1",
    active: true,
    from: {left: 0, top: 0, width: 600, height: 400},
    to: {left: 600, top: 0, width: 400, height: 400},
    opacity: 0,
  })
  assert.deepEqual(targets[1].to, {left: 0, top: 0, width: 600, height: 400})
})

test("animates both frozen panes and layers the active identity above its neighbor", async () => {
  const previousWindow = globalThis.window
  const previousElement = globalThis.Element
  const calls = []

  globalThis.window = {matchMedia: () => ({matches: false})}
  globalThis.Element = class Element {}

  const frozenPane = (id) => ({
    el: {
      style: {},
      animate(keyframes, options) {
        calls.push({id, keyframes, options})
        return {finished: Promise.resolve(), cancel() {}}
      },
    },
  })

  const frozen = {
    panes: new Map([
      ["%1", frozenPane("%1")],
      ["%2", frozenPane("%2")],
    ]),
    layoutRect: {width: 1000, height: 400},
  }

  try {
    await animateSwapTransition({frozen, before: BEFORE, confirmed: CONFIRMED})

    assert.equal(calls.length, 2)
    assert.equal(frozen.panes.get("%1").el.style.zIndex, "2")
    assert.equal(frozen.panes.get("%2").el.style.zIndex, "1")
    assert.deepEqual(calls[0].keyframes[1], {
      left: "600px",
      top: "0px",
      width: "400px",
      height: "400px",
      opacity: 0,
    })
  } finally {
    if (previousWindow === undefined) delete globalThis.window
    else globalThis.window = previousWindow

    if (previousElement === undefined) delete globalThis.Element
    else globalThis.Element = previousElement
  }
})

test("reduced motion uses a short opacity settle instead of geometry", async () => {
  const previousWindow = globalThis.window
  const previousElement = globalThis.Element
  const calls = []

  globalThis.window = {matchMedia: () => ({matches: true})}
  globalThis.Element = class Element {}

  try {
    await animateSwapTransition({
      frozen: {
        panes: new Map([
          [
            "%1",
            {
              el: {
                style: {},
                animate(keyframes, options) {
                  calls.push({keyframes, options})
                  return {finished: Promise.resolve(), cancel() {}}
                },
              },
            },
          ],
        ]),
        layoutRect: {width: 1000, height: 400},
      },
      before: BEFORE,
      confirmed: CONFIRMED,
    })

    assert.equal(calls.length, 1)
    assert.deepEqual(calls[0].keyframes, [{opacity: 1}, {opacity: 0}])
    assert.equal(calls[0].options.duration, 100)
    assert.equal(calls[0].keyframes[0].left, undefined)
  } finally {
    if (previousWindow === undefined) delete globalThis.window
    else globalThis.window = previousWindow

    if (previousElement === undefined) delete globalThis.Element
    else globalThis.Element = previousElement
  }
})
