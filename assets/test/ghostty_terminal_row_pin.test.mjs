// Regression tests for mobile row-pinning, against the REAL bundled hook.
//
// Row-pinning holds the PTY at its keyboard-closed row count and scrolls the
// fixed grid so the rows that matter stay above the soft keyboard, instead of
// reflowing tmux on every keyboard toggle. The bug these pin down: it scrolled
// to the grid BOTTOM unconditionally, which is only where the content lives if
// the grid is full. On a fresh session the shell has painted ~16 rows at the
// top of a ~46-row grid and left the rest blank, so opening the keyboard
// scrolled the small visible window entirely into unwritten rows — the
// terminal went blank the instant the keyboard came up (mobile PWA screenshot).
//
// terminal_display_layout.test.mjs covers the geometry in isolation; these
// mount the real vendor+extension hook so the wiring (cursor plumbing, the
// keyboard-open gate, the post-paint follow) is exercised too.

import assert from "node:assert/strict"
import test from "node:test"
import path from "node:path"
import { Buffer } from "node:buffer"
import { fileURLToPath } from "node:url"

import esbuild from "esbuild"
import { JSDOM } from "jsdom"

const assetsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

const CELL_W = 10
const CELL_H = 17
const PRE_PAD = 16 // vendor <pre> padding: 8px, both sides

async function loadHookModule() {
  const result = await esbuild.build({
    entryPoints: [path.join(assetsDir, "js", "ghostty_terminal.js")],
    bundle: true,
    format: "esm",
    write: false,
    logLevel: "silent",
  })

  const code = Buffer.from(result.outputFiles[0].contents).toString("base64")
  return import(`data:text/javascript;base64,${code}`)
}

function installDom() {
  const dom = new JSDOM(`<!doctype html><html><body></body></html>`, {
    url: "http://localhost/",
    pretendToBeVisual: true,
  })

  dom.window.document.hasFocus = () => true
  // Row-pinning is mobile-only (isMobileTerminalLayout). jsdom's matchMedia
  // always reports false, so stand in for a touch device.
  dom.window.matchMedia = (query) => ({ matches: query.includes("pointer: coarse") })

  globalThis.window = dom.window
  globalThis.document = dom.window.document
  globalThis.localStorage = dom.window.localStorage
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window)
  globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)

  return dom
}

function makeTerminalEl(document) {
  const el = document.createElement("div")
  el.id = "ghostty-test"
  el.dataset.cols = "80"
  el.dataset.rows = "24"
  el.dataset.fit = "true"
  el.dataset.autofocus = "false"
  el.dataset.renderAuthority = "worker"

  const input = document.createElement("textarea")
  input.setAttribute("data-ghostty-input", "true")
  el.appendChild(input)
  document.body.appendChild(el)
  return el
}

function mountHook(GhosttyTerminal, el) {
  const hook = Object.create(GhosttyTerminal)
  hook.el = el
  hook.pushes = []
  hook.__eventHandlers = {}
  hook.pushEvent = (event, payload) => hook.pushes.push({ event, payload })
  hook.pushEventTo = (_target, event, payload) => hook.pushes.push({ event, payload })
  hook.handleEvent = (name, cb) => {
    hook.__eventHandlers[name] = cb
  }
  hook.mounted()
  return hook
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function setViewport(el, { width, height }) {
  el.getBoundingClientRect = () => ({
    width, height, left: 0, top: 0, right: width, bottom: height,
  })
}

// A grid whose first `painted` rows carry text and whose tail is blank —
// exactly the shape a fresh shell leaves behind.
function gridPayload({ id, cols, rows, painted, cursorRow }) {
  const cells = Array.from({ length: rows }, (_, row) =>
    Array.from({ length: cols }, () => [row < painted ? "x" : " ", null, null, 0])
  )
  return {
    id,
    cells,
    cursor: { x: 0, y: cursorRow, visible: true },
  }
}

function frameOf(hook) {
  return hook.screen.querySelector('[data-terminal-scale-frame="true"]')
}

function translateYOf(hook) {
  const transform = frameOf(hook)?.style.transform || ""
  const m = /translateY\(-?([\d.]+)px\)/.exec(transform)
  return m ? Number(m[1]) : null
}

// Bring the hook up on a phone-sized viewport with the keyboard closed, so the
// fit pass records the keyboard-closed row count row-pinning holds the PTY at.
async function mountPinnedTerminal() {
  installDom()
  const mod = await loadHookModule()
  const el = makeTerminalEl(document)
  const hook = mountHook(mod.GhosttyTerminal, el)

  setViewport(el, { width: 390, height: 800 })
  hook.measure.getBoundingClientRect = () => ({ width: CELL_W * 10 })
  hook.onWindowResize()
  await wait(150)

  return { hook, el }
}

test("keyboard-closed fit reports a grid that fits inside the pre's text box", async () => {
  const { hook } = await mountPinnedTerminal()

  const fit = hook.pushes.filter((p) => p.event === "ready" || p.event === "resize").pop()
  assert.equal(fit.payload.cols, Math.floor((390 - PRE_PAD) / CELL_W))
  assert.equal(fit.payload.rows, Math.floor((800 - PRE_PAD) / CELL_H))
  assert.ok(fit.payload.cols * CELL_W <= 390 - PRE_PAD)

  hook.destroyed()
})

test("opening the keyboard keeps a top-anchored cursor on screen", async () => {
  const { hook, el } = await mountPinnedTerminal()

  const pinnedRows = Math.floor((800 - PRE_PAD) / CELL_H)
  const cols = Math.floor((390 - PRE_PAD) / CELL_W)
  const cursorRow = 15

  // A fresh session: 16 painted rows at the top of the grid, blank tail.
  hook.__eventHandlers["ghostty:render"]({
    ...gridPayload({ id: hook.el.id, cols, rows: pinnedRows, painted: 16, cursorRow }),
  })
  await wait(150)

  // Keyboard opens: the shell shortens and the keyboard-open class goes on.
  document.documentElement.classList.add("devide-keyboard-open")
  setViewport(el, { width: 390, height: 280 })
  hook.onWindowResize()
  await wait(150)

  assert.equal(hook.el.dataset.displayMode, "rowpin", "row-pinning engaged")

  const visibleRows = Math.floor((280 - PRE_PAD) / CELL_H)
  const offsetY = translateYOf(hook)
  assert.notEqual(offsetY, null, "scale frame carries the row-pin translate")

  // The cursor must land inside the window still on screen. Before the fix this
  // scrolled to the grid bottom (offsetY = (pinnedRows - visibleRows) * CELL_H),
  // parking the window in the blank tail with the cursor far above it.
  const firstVisible = offsetY / CELL_H
  const lastVisible = firstVisible + visibleRows - 1
  assert.ok(
    cursorRow >= firstVisible && cursorRow <= lastVisible,
    `cursor row ${cursorRow} outside visible window ${firstVisible}..${lastVisible}`
  )
  // And the painted content is on screen, not a blank tail.
  assert.ok(firstVisible < 16, "window starts inside the painted region")

  hook.destroyed()
})

test("row-pinning holds the PTY at its keyboard-closed rows", async () => {
  const { hook, el } = await mountPinnedTerminal()

  const pinnedRows = Math.floor((800 - PRE_PAD) / CELL_H)
  const before = hook.pushes.filter((p) => p.event === "resize" || p.event === "ready").length

  document.documentElement.classList.add("devide-keyboard-open")
  setViewport(el, { width: 390, height: 280 })
  hook.onWindowResize()
  await wait(150)

  const reports = hook.pushes.filter((p) => p.event === "resize" || p.event === "ready")
  assert.equal(reports.length, before, "no tmux reflow on keyboard open")
  assert.equal(hook.__lastFitRows, pinnedRows, "PTY still held at the keyboard-closed rows")

  hook.destroyed()
})

test("a scrolled shell still pins to the bottom of the grid", async () => {
  const { hook, el } = await mountPinnedTerminal()

  const pinnedRows = Math.floor((800 - PRE_PAD) / CELL_H)
  const cols = Math.floor((390 - PRE_PAD) / CELL_W)

  // Fully painted grid with the cursor on the last row — the classic shell.
  hook.__eventHandlers["ghostty:render"](
    gridPayload({
      id: hook.el.id,
      cols,
      rows: pinnedRows,
      painted: pinnedRows,
      cursorRow: pinnedRows - 1,
    })
  )
  await wait(150)

  document.documentElement.classList.add("devide-keyboard-open")
  setViewport(el, { width: 390, height: 280 })
  hook.onWindowResize()
  await wait(150)

  const visibleRows = Math.floor((280 - PRE_PAD) / CELL_H)
  assert.equal(translateYOf(hook), (pinnedRows - visibleRows) * CELL_H)

  hook.destroyed()
})

test("closing the keyboard drops the row-pin translate", async () => {
  const { hook, el } = await mountPinnedTerminal()

  document.documentElement.classList.add("devide-keyboard-open")
  setViewport(el, { width: 390, height: 280 })
  hook.onWindowResize()
  await wait(150)
  assert.equal(hook.el.dataset.displayMode, "rowpin")

  document.documentElement.classList.remove("devide-keyboard-open")
  setViewport(el, { width: 390, height: 800 })
  hook.onWindowResize()
  await wait(150)

  assert.notEqual(hook.el.dataset.displayMode, "rowpin")
  assert.equal(translateYOf(hook), null, "translate cleared on the way out")

  hook.destroyed()
})
