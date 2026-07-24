// Shared jsdom harness for tests that mount the REAL bundled terminal hook
// (vendor + extension, esbuild-bundled) instead of exercising pure helpers.
//
// The layout bugs this subsystem keeps producing live in the COMPOSITION —
// container measured here, cell metrics measured there, transform applied to a
// third element — so the pure-helper tests never saw them. Anything asserting a
// layout invariant needs the real hook in a real (if synthetic) DOM.

import path from "node:path"
import { Buffer } from "node:buffer"
import { fileURLToPath } from "node:url"

import esbuild from "esbuild"
import { JSDOM } from "jsdom"

const assetsDir = path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url))))

// Reference metrics used across the layout tests: a 10px-advance monospace cell
// (the measure span holds 10 chars, so a 100px rect) on a 17px line height, and
// the vendor <pre>'s own `padding: 8px` on each side.
export const CELL_W = 10
export const CELL_H = 17
export const PRE_PAD = 16

let cachedModule = null

// esbuild-bundling the hook costs ~1.5s; every suite in a run shares one build.
export async function loadHookModule() {
  if (cachedModule) return cachedModule

  const result = await esbuild.build({
    entryPoints: [path.join(assetsDir, "js", "ghostty_terminal.js")],
    bundle: true,
    format: "esm",
    write: false,
    logLevel: "silent",
  })

  const code = Buffer.from(result.outputFiles[0].contents).toString("base64")
  cachedModule = await import(`data:text/javascript;base64,${code}`)
  return cachedModule
}

// jsdom has no 2D canvas (the optional `canvas` package isn't installed), so
// getContext returns null and the canvas renderer silently no-ops at its `!ctx`
// guard. That would make every canvas invariant vacuously pass. Stub a context
// that records nothing but answers every call, so the canvas path really runs.
function installCanvasStub(window) {
  window.HTMLCanvasElement.prototype.getContext = function getContext() {
    return new Proxy(
      {
        canvas: this,
        measureText: (text) => ({ width: String(text).length * CELL_W }),
      },
      {
        get(target, prop) {
          if (prop in target) return target[prop]
          return () => undefined
        },
        set(target, prop, value) {
          target[prop] = value
          return true
        },
      }
    )
  }
}

/**
 * @param {{mobile?: boolean, hasFocus?: boolean}} opts
 *   mobile   — stand in for a touch device; isMobileTerminalLayout() gates
 *              row-pinning and the top-center scaled alignment on it, and
 *              jsdom's matchMedia always reports false.
 *   hasFocus — jsdom reports false, which makes every hook a passive
 *              (non-size-authoritative) viewer. Most layout tests want the
 *              focused-viewer contract.
 */
export function installDom({ mobile = false, hasFocus = true } = {}) {
  const dom = new JSDOM(`<!doctype html><html><body></body></html>`, {
    url: "http://localhost/",
    pretendToBeVisual: true,
  })

  dom.window.document.hasFocus = () => hasFocus
  dom.window.matchMedia = (query) => ({
    matches: mobile ? query.includes("pointer: coarse") : false,
  })
  installCanvasStub(dom.window)

  globalThis.window = dom.window
  globalThis.document = dom.window.document
  globalThis.localStorage = dom.window.localStorage
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window)
  globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)

  return dom
}

export function makeTerminalEl(document, { fit = true, cols = 80, rows = 24, renderer } = {}) {
  const el = document.createElement("div")
  el.id = "ghostty-test"
  el.dataset.cols = String(cols)
  el.dataset.rows = String(rows)
  el.dataset.fit = String(fit)
  el.dataset.autofocus = "false"
  el.dataset.renderAuthority = "worker"
  if (renderer) el.dataset.renderer = renderer

  const input = document.createElement("textarea")
  input.setAttribute("data-ghostty-input", "true")
  el.appendChild(input)
  document.body.appendChild(el)
  return el
}

// Mount the LiveView hook object the way phoenix_live_view does: the hook spec
// becomes the prototype, `el` / push callbacks are instance state.
export function mountHook(GhosttyTerminal, el) {
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

export const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export function setViewport(el, { width, height }) {
  el.getBoundingClientRect = () => ({
    width, height, left: 0, top: 0, right: width, bottom: height,
  })
}

export function sizeReports(hook) {
  return hook.pushes.filter((p) => p.event === "ready" || p.event === "resize")
}

export function lastSizeReport(hook) {
  return sizeReports(hook).at(-1) ?? null
}

/**
 * A grid whose first `painted` rows carry text and whose tail is blank — the
 * shape a fresh shell leaves behind, and the one that made row-pinning scroll
 * into nothing.
 */
export function gridPayload({ id, cols, rows, painted = rows, cursorRow = rows - 1, cursorVisible = true }) {
  const cells = Array.from({ length: rows }, (_, row) =>
    Array.from({ length: cols }, () => [row < painted ? "x" : " ", null, null, 0])
  )
  return {
    id,
    cells,
    cursor: { x: 0, y: cursorRow, visible: cursorVisible },
  }
}

// `id` last: the vendor handler drops any payload whose id doesn't match the
// element, and gridPayload leaves it undefined unless a caller supplies one.
export function render(hook, payload) {
  hook.__eventHandlers["ghostty:render"]({ ...payload, id: hook.el.id })
}

/**
 * Render until the grid has converged on the fitted size.
 *
 * A freshly mounted hook still carries the dataset default (80x24) as its
 * rendered grid, which overflows the fit, so authoritativeOverflowGuard
 * correctly borrows scale-to-fit for one beat. The mode only settles to "fit"
 * on the paint AFTER the real grid arrives — and the canvas renderer, which
 * only engages in identity modes, is therefore not created until that second
 * paint. Tests that care about the settled state need both.
 */
export async function renderSettled(hook, payload) {
  render(hook, payload)
  await wait(150)
  render(hook, payload)
  await wait(150)
}

export function frameOf(hook) {
  return hook.screen?.querySelector('[data-terminal-scale-frame="true"]') ?? null
}

export function translateYOf(hook) {
  const transform = frameOf(hook)?.style.transform || ""
  const m = /translateY\(-?([\d.]+)px\)/.exec(transform)
  return m ? Number(m[1]) : null
}

export function scaleOf(hook) {
  const transform = frameOf(hook)?.style.transform || ""
  const m = /scale\(([\d.]+)\)/.exec(transform)
  return m ? Number(m[1]) : null
}

export function displayMode(hook) {
  return hook.el?.dataset?.displayMode ?? null
}

// A stable snapshot of everything the layout pass is allowed to touch. Used to
// assert the fixed-point invariant: computing twice must change nothing.
export function layoutSnapshot(hook) {
  const frame = frameOf(hook)
  return JSON.stringify({
    mode: displayMode(hook),
    frame: frame
      ? {
          left: frame.style.left,
          top: frame.style.top,
          width: frame.style.width,
          height: frame.style.height,
          transform: frame.style.transform,
        }
      : null,
    pre: {
      left: hook.pre.style.left,
      top: hook.pre.style.top,
      width: hook.pre.style.width,
      height: hook.pre.style.height,
      transform: hook.pre.style.transform,
    },
    lastFit: [hook.__lastFitCols ?? null, hook.__lastFitRows ?? null],
    reports: sizeReports(hook).length,
  })
}

/**
 * Bring a hook up on a measurable viewport with the keyboard closed, so the fit
 * pass records the keyboard-closed row count row-pinning anchors to.
 *
 * Pass the test context as `t` so teardown is registered up front. The hook
 * installs a 2s reheal interval; a failed assertion that skips `hook.destroyed()`
 * leaves it running and node:test waits out the whole file timeout, turning one
 * clean assertion failure into an opaque 30s hang.
 */
export async function mountTerminal({
  t,
  width = 390,
  height = 800,
  mobile = false,
  hasFocus = true,
  renderer,
  fit = true,
} = {}) {
  installDom({ mobile, hasFocus })
  const mod = await loadHookModule()
  const el = makeTerminalEl(document, { fit, renderer })
  const hook = mountHook(mod.GhosttyTerminal, el)
  t?.after?.(() => {
    try {
      hook.destroyed()
    } catch (_) {
      /* already torn down */
    }
  })

  setViewport(el, { width, height })
  hook.measure.getBoundingClientRect = () => ({ width: CELL_W * 10 })
  hook.onWindowResize()
  await wait(150)

  return { hook, el, mod }
}

export function openKeyboard(hook, el, { width = 390, height = 280 } = {}) {
  document.documentElement.classList.add("devide-keyboard-open")
  setViewport(el, { width, height })
  hook.onWindowResize()
}

export function closeKeyboard(hook, el, { width = 390, height = 800 } = {}) {
  document.documentElement.classList.remove("devide-keyboard-open")
  setViewport(el, { width, height })
  hook.onWindowResize()
}

// Cols/rows that actually fit inside the <pre>'s text box for a container.
export function expectedFit(width, height) {
  return {
    cols: Math.floor((width - PRE_PAD) / CELL_W),
    rows: Math.floor((height - PRE_PAD) / CELL_H),
  }
}
