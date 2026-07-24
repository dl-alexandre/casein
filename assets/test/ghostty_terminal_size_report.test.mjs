// Regression tests for the terminal size-report wire contract.
//
// The "narrow column" incident (PR #148): the extension layer disables the
// vendor hook's fit path (hook.fit = false) and reports fitted sizes itself,
// but the vendor's deferred sendReady (rAF / 50ms) then took the non-fit
// branch and pushed "ready" with the dataset defaults 80x24 — overwriting the
// fitted size server-side. SessionOwner recorded 80x24 as the focused
// viewer's viewport and stamped it onto the shared tmux window forever.
//
// These tests mount the REAL hook (vendor + extension, bundled with esbuild)
// inside jsdom and pin the contract:
//   1. a fit-managed hook never reports the dataset-default size — not as
//      "ready", not as "resize";
//   2. a fixed-size (fit=false) hook still sends the vendor "ready" verbatim;
//   3. once the container is measurable, the FIRST fitted report goes out as
//      "ready" (playing the vendor ready's role) and later fits as "resize".

import assert from "node:assert/strict"
import test from "node:test"
import path from "node:path"
import { Buffer } from "node:buffer"
import { fileURLToPath } from "node:url"

import esbuild from "esbuild"
import { JSDOM } from "jsdom"

const assetsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

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

  // jsdom documents report hasFocus()=false, which makes every hook a
  // passive (non-size-authoritative) viewer. These tests exercise the
  // focused-viewer contract, so pretend the window holds focus.
  dom.window.document.hasFocus = () => true

  globalThis.window = dom.window
  globalThis.document = dom.window.document
  globalThis.localStorage = dom.window.localStorage
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window)
  globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)

  return dom
}

function makeTerminalEl(document, { fit, cols = 80, rows = 24 }) {
  const el = document.createElement("div")
  el.id = "ghostty-test"
  el.dataset.cols = String(cols)
  el.dataset.rows = String(rows)
  el.dataset.fit = String(fit)
  el.dataset.autofocus = "false"
  el.dataset.renderAuthority = "worker"

  const input = document.createElement("textarea")
  input.setAttribute("data-ghostty-input", "true")
  el.appendChild(input)
  document.body.appendChild(el)
  return el
}

// Mount the LiveView hook object the way phoenix_live_view does: the hook
// spec becomes the prototype, `el` / push callbacks are instance state.
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

function sizeReports(hook) {
  return hook.pushes.filter((p) => p.event === "ready" || p.event === "resize")
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Give the vendor's deferred sendReady paths (rAF, the 50ms timeout, and a
// first render frame) every chance to fire before asserting.
async function settleMount(hook) {
  await wait(120)
  hook.__eventHandlers["ghostty:render"]?.({
    id: hook.el.id,
    cells: [[[" ", null, null, 0]]],
    cursor: null,
  })
  await wait(120)
}

// The container is unmeasurable in jsdom by default (all rects are 0), which
// mirrors a real mount before layout settles — exactly the window in which
// the vendor's dataset-default "ready" used to escape.
test("fit hook never reports the dataset-default size, even before layout", async () => {
  installDom()
  const mod = await loadHookModule()
  const el = makeTerminalEl(document, { fit: true, cols: 80, rows: 24 })
  const hook = mountHook(mod.GhosttyTerminal, el)

  await settleMount(hook)

  const defaults = sizeReports(hook).filter(
    (p) => p.payload.cols === 80 && p.payload.rows === 24
  )
  assert.deepEqual(
    defaults,
    [],
    `fit-managed hook must not report the dataset 80x24; got ${JSON.stringify(hook.pushes)}`
  )

  hook.destroyed()
})

test("fixed-size (fit=false) hook still sends the vendor ready verbatim", async () => {
  installDom()
  const mod = await loadHookModule()
  const el = makeTerminalEl(document, { fit: false, cols: 100, rows: 30 })
  const hook = mountHook(mod.GhosttyTerminal, el)

  await settleMount(hook)

  const readies = hook.pushes.filter((p) => p.event === "ready")
  assert.equal(readies.length, 1, JSON.stringify(hook.pushes))
  assert.deepEqual(readies[0].payload, { cols: 100, rows: 30 })

  hook.destroyed()
})

test("first fitted report is sent as ready, later fits as resize", async () => {
  installDom()
  const mod = await loadHookModule()
  const el = makeTerminalEl(document, { fit: true })
  const hook = mountHook(mod.GhosttyTerminal, el)
  await settleMount(hook)
  assert.deepEqual(sizeReports(hook), [], "no size report while unmeasurable")

  // Make the container measurable: 1600x900 viewport, 10px-advance monospace
  // cells (measure span holds 10 chars), 17px line height from the pre's
  // inline style.
  //
  // The reported grid is derived from the <pre>'s TEXT box, not the container:
  // the vendor gives the <pre> `padding: 8px` with `box-sizing: border-box`, so
  // 16px of each axis is unavailable to cells. Sizing off the container alone
  // reported floor(1600/10)=160 cols, of which the last two overhung the text
  // box and were silently clipped by the <pre>'s `overflow: hidden` — the
  // "characters vanish off the right edge" bug (mobile PWA screenshot, where
  // one lost column ate a character out of every wrapped path).
  // Expected grid: floor((1600-16)/10) x floor((900-16)/17) = 158x52.
  el.getBoundingClientRect = () =>
    ({ width: 1600, height: 900, left: 0, top: 0, right: 1600, bottom: 900 })
  hook.measure.getBoundingClientRect = () => ({ width: 100 })

  hook.onWindowResize()
  await wait(150)

  let reports = sizeReports(hook)
  assert.equal(reports.length, 1, JSON.stringify(hook.pushes))
  assert.equal(reports[0].event, "ready", "first fitted report plays the vendor ready role")
  assert.deepEqual(reports[0].payload, { cols: 158, rows: 52 })
  // Every reported cell fits inside the text box, with none overhanging it.
  assert.ok(reports[0].payload.cols * 10 <= 1600 - 16, "no column overhangs the pre's text box")
  assert.ok(reports[0].payload.rows * 17 <= 900 - 16, "no row overhangs the pre's text box")

  // Container shrinks: subsequent fits are plain resizes, and the ready is
  // never re-sent. floor((1200-16)/10) x floor((600-16)/17) = 118x34.
  el.getBoundingClientRect = () =>
    ({ width: 1200, height: 600, left: 0, top: 0, right: 1200, bottom: 600 })
  hook.onWindowResize()
  await wait(150)

  reports = sizeReports(hook)
  assert.equal(reports.length, 2, JSON.stringify(hook.pushes))
  assert.equal(reports[1].event, "resize")
  assert.deepEqual(reports[1].payload, { cols: 118, rows: 34 })

  hook.destroyed()
})
