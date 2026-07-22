import test from "node:test"
import assert from "node:assert/strict"
import {JSDOM} from "jsdom"

import {
  captureLayoutFrame,
  cleanupCapturedLayoutFrame,
  paneRectToPixels,
  readLayoutProjection,
} from "../js/terminal_capture.mjs"

test("reads the last server-rendered layout projection from data attributes", () => {
  const sections = [
    {
      dataset: {
        paneId: "%1",
        paneLeft: "0",
        paneTop: "0",
        paneWidth: "60",
        paneHeight: "40",
      },
    },
    {
      dataset: {
        paneId: "%2",
        paneLeft: "60",
        paneTop: "0",
        paneWidth: "40",
        paneHeight: "40",
      },
    },
  ]

  const layout = {
    dataset: {
      boundsCols: "100",
      boundsRows: "40",
      layoutVersion: "1234",
      windowZoomed: "false",
      activePaneId: "%1",
    },
    querySelectorAll: () => sections,
  }

  assert.deepEqual(readLayoutProjection(layout), {
    version: 1234,
    topologyVersion: 0,
    zoomed: false,
    activePaneId: "%1",
    bounds: {width: 100, height: 40},
    panes: [
      {id: "%1", left: 0, top: 0, width: 60, height: 40},
      {id: "%2", left: 60, top: 0, width: 40, height: 40},
    ],
  })
})

test("converts tmux cell rectangles into layout-relative pixels", () => {
  assert.deepEqual(
    paneRectToPixels(
      {left: 60, top: 10, width: 40, height: 30},
      {width: 100, height: 40},
      {width: 1000, height: 400},
    ),
    {left: 600, top: 100, width: 400, height: 300},
  )
})

test("captures a sanitized pane slice while shielding the live terminal", () => {
  const dom = new JSDOM(`<!doctype html><html><body>
    <div id="layout">
      <div data-terminal-surface-mount>
        <div id="ghostty-live" phx-hook="GhosttyTerminal">
          <pre id="terminal-text">hello</pre>
          <textarea id="terminal-input"></textarea>
        </div>
      </div>
      <section data-pane-id="%1"></section>
    </div>
  </body></html>`)
  const {document} = dom.window
  const layout = document.getElementById("layout")
  const terminal = layout.querySelector("[phx-hook='GhosttyTerminal']")
  const rect = {left: 10, top: 20, width: 800, height: 400}

  layout.getBoundingClientRect = () => rect
  terminal.getBoundingClientRect = () => rect

  const frozen = captureLayoutFrame(layout, {
    bounds: {width: 100, height: 40},
    panes: [{id: "%1", left: 0, top: 0, width: 100, height: 40}],
  })

  assert.equal(layout.inert, true)
  assert.equal(frozen.root.style.pointerEvents, "auto")
  assert.equal(frozen.root.style.background, "transparent")
  assert.notEqual(frozen.root.inert, true)
  assert.equal(frozen.root.querySelector("pre").textContent, "hello")
  assert.equal(frozen.root.querySelector("textarea"), null)
  assert.equal(frozen.root.querySelector("[id]"), null)

  cleanupCapturedLayoutFrame(frozen)

  assert.equal(layout.inert, false)
  assert.equal(document.querySelector("[data-tmux-transition-overlay]"), null)
})
