import test from "node:test"
import assert from "node:assert/strict"

import {
  normalizeConfirmedProjection,
  waitForConfirmedLayout,
} from "../js/tmux_layout_transition.mjs"

test("normalizeConfirmedProjection maps snake_case LiveView payload fields", () => {
  assert.deepEqual(
    normalizeConfirmedProjection({
      layout_version: 11,
      version: 4,
      zoomed: true,
      active_pane_id: "%2",
      bounds: {width: 100, height: 40},
      pane_rects: [{id: "%1"}, {id: "%2"}],
    }),
    {
      version: 11,
      topologyVersion: 4,
      zoomed: true,
      activePaneId: "%2",
      bounds: {width: 100, height: 40},
      panes: [{id: "%1"}, {id: "%2"}],
    },
  )
})

test("normalizeConfirmedProjection accepts camelCase and applies defaults", () => {
  const projection = normalizeConfirmedProjection({
    layoutVersion: 7,
    activePaneId: "%9",
  })

  assert.equal(projection.version, 7)
  assert.equal(projection.zoomed, false)
  assert.equal(projection.activePaneId, "%9")
  assert.deepEqual(projection.bounds, {width: 1, height: 1})
  assert.deepEqual(projection.panes, [])
})

test("waitForConfirmedLayout resolves immediately when layout already matches", async () => {
  const layout = {
    dataset: {layoutVersion: "11", windowZoomed: "false"},
    querySelectorAll: () => [{dataset: {paneId: "%1"}}, {dataset: {paneId: "%2"}}],
  }
  const confirmed = {
    layout_version: 11,
    zoomed: false,
    pane_rects: [{id: "%1"}, {id: "%2"}],
  }

  await waitForConfirmedLayout(layout, confirmed)
})

test("waitForConfirmedLayout rejects AbortError for a pre-aborted signal", async () => {
  const nonMatchingLayout = {
    dataset: {layoutVersion: "1", windowZoomed: "false"},
    querySelectorAll: () => [],
  }
  const confirmed = {
    layout_version: 11,
    zoomed: false,
    pane_rects: [{id: "%1"}, {id: "%2"}],
  }

  await assert.rejects(
    waitForConfirmedLayout(nonMatchingLayout, confirmed, {aborted: true}),
    (error) => error.name === "AbortError",
  )
})

test("waitForConfirmedLayout rejects confirmed_layout_timeout when DOM never matches", async () => {
  const nonMatchingLayout = {
    dataset: {layoutVersion: "1", windowZoomed: "false"},
    querySelectorAll: () => [],
  }
  const confirmed = {
    layout_version: 11,
    zoomed: false,
    pane_rects: [{id: "%1"}, {id: "%2"}],
  }

  await assert.rejects(
    waitForConfirmedLayout(nonMatchingLayout, confirmed, undefined, 5),
    (error) => error instanceof Error && error.message === "confirmed_layout_timeout",
  )
})
