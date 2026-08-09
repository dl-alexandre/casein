import test from "node:test"
import assert from "node:assert/strict"

import {
  normalizeConfirmedProjection,
  waitForConfirmedLayout,
} from "../js/tmux_layout_transition.mjs"
import {
  animateZoomTransition,
  zoomAnimationTargets,
} from "../js/tmux_zoom_transition.mjs"

const BEFORE = {
  version: 10,
  activePaneId: "%1",
  bounds: {width: 100, height: 40},
  panes: [
    {id: "%1", left: 0, top: 0, width: 60, height: 40},
    {id: "%2", left: 60, top: 0, width: 40, height: 40},
  ],
}

test("normalizes the compact LiveView confirmation payload", () => {
  assert.deepEqual(
    normalizeConfirmedProjection({
      version: 88,
      layout_version: 11,
      zoomed: true,
      active_pane_id: "%1",
      bounds: {width: 100, height: 40},
      pane_rects: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
    }),
    {
      version: 11,
      topologyVersion: 88,
      zoomed: true,
      activePaneId: "%1",
      bounds: {width: 100, height: 40},
      panes: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
    },
  )
})

test("expands the active pane and nudges a hidden neighbor outward", () => {
  const targets = zoomAnimationTargets(
    BEFORE,
    {
      layout_version: 11,
      zoomed: true,
      active_pane_id: "%1",
      bounds: {width: 100, height: 40},
      pane_rects: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
    },
    {width: 1000, height: 400},
  )

  assert.deepEqual(targets[0].to, {left: 0, top: 0, width: 1000, height: 400})
  assert.equal(targets[0].active, true)
  assert.equal(targets[1].to.left, 606)
  assert.equal(targets[1].opacity, 0)
})

test("confirmed layout wait resolves immediately when version and zoom already match", async () => {
  const layout = {dataset: {layoutVersion: "11", windowZoomed: "true"}}

  await waitForConfirmedLayout(layout, {layout_version: 11, zoomed: true}, undefined, 5)
})

test("confirmed layout wait also verifies pane identities when the DOM exposes them", async () => {
  const panes = [{dataset: {paneId: "%1"}}, {dataset: {paneId: "%2"}}]
  const layout = {
    dataset: {layoutVersion: "11", windowZoomed: "false"},
    querySelectorAll: () => panes,
  }

  await waitForConfirmedLayout(
    layout,
    {
      layout_version: 11,
      zoomed: false,
      pane_rects: [{id: "%2"}, {id: "%1"}],
    },
    undefined,
    5,
  )
})

test("reduced motion uses a short opacity settle instead of geometry", async () => {
  const previousWindow = globalThis.window
  const previousElement = globalThis.Element
  const calls = []

  globalThis.window = {matchMedia: () => ({matches: true})}
  globalThis.Element = class Element {}

  try {
    await animateZoomTransition({
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
      confirmed: {
        layout_version: 11,
        zoomed: true,
        active_pane_id: "%1",
        bounds: {width: 100, height: 40},
        pane_rects: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
      },
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
