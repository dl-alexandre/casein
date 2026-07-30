// Regression tests for the click-vs-drag split, against the REAL bundled hook.
//
// The bug: the Shift requirement for local selection was gated on the coarse
// `mouse.tracking` flag, which is true for every mouse mode. Claude Code sets
// DECSET 1000 + 1006 — press/release only, never motion — so a plain drag there
// was withheld from selection and forwarded to a program that cannot receive
// motion reports. The gesture was dead input either way, and copying output
// required knowing about an undocumented Shift.
//
// Three properties have to hold together, and the middle one is the one most
// likely to regress: relaxing the drag must not swallow the CLICK, because that
// is what focuses the pane and reaches clickable TUI hotspots (agent login
// screens, lazygit, menus). Programs that genuinely read motion keep their
// drags — tmux `mouse on` would otherwise lose copy-mode and border resize.

import assert from "node:assert/strict"
import test from "node:test"

import {
  gridPayload,
  mountTerminal,
  render,
  wait,
} from "./support/terminal_hook_harness.mjs"

// Claude Code: 1000 (press/release) + 1006 (SGR coords), no 1002/1003.
const CLICK_ONLY = { tracking: true, normal: true, sgr: true }
// tmux `mouse on`, lazygit, htop: 1002 button-event tracking reports motion.
const MOTION = { tracking: true, normal: true, button: true, sgr: true }
// Plain shell: the program never asked for the mouse at all.
const NO_TRACKING = { tracking: false }

function paint(hook, mouse) {
  render(hook, {
    ...gridPayload({ cols: hook.cols, rows: hook.rows }),
    mouse,
  })
}

function mouseEvent(type, { x, y, shiftKey = false }) {
  return new window.MouseEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button: 0,
    buttons: type === "mouseup" ? 0 : 1,
    shiftKey,
  })
}

const press = (hook, opts) => hook.pre.dispatchEvent(mouseEvent("mousedown", opts))
const move = (hook, opts) => hook.pre.dispatchEvent(mouseEvent("mousemove", opts))
const release = (hook, opts) => hook.pre.dispatchEvent(mouseEvent("mouseup", opts))

// What actually reached the server: the hook wraps pushEvent with the
// shouldDropMouseEvent gate, so anything recorded here really was forwarded.
function mouseActions(hook) {
  return hook.pushes.filter((p) => p.event === "mouse").map((p) => p.payload.action)
}

async function paneWith(t, mouse) {
  const mounted = await mountTerminal({ t })
  paint(mounted.hook, mouse)
  await wait(20)
  mounted.hook.pushes.length = 0
  return mounted
}

test("click-only tracking: plain drag selects locally and sends nothing", async (t) => {
  const { hook } = await paneWith(t, CLICK_ONLY)

  press(hook, { x: 50, y: 50 })
  move(hook, { x: 200, y: 50 })
  release(hook, { x: 200, y: 50 })
  await wait(50)

  assert.equal(hook.__selectionActive, true)
  assert.deepEqual(mouseActions(hook), [])
})

test("click-only tracking: a plain click still reaches the program", async (t) => {
  const { hook } = await paneWith(t, CLICK_ONLY)

  // Released within the slop — a click, not a drag.
  press(hook, { x: 50, y: 50 })
  release(hook, { x: 52, y: 50 })
  await wait(50)

  assert.deepEqual(mouseActions(hook), ["press", "release"])
  assert.notEqual(hook.__selectionActive, true)
})

test("click-only tracking: the press is withheld until the gesture is known", async (t) => {
  const { hook } = await paneWith(t, CLICK_ONLY)

  press(hook, { x: 50, y: 50 })
  // Nothing yet: sending the press here is what would leak a stray click into
  // the program on every drag-select.
  assert.deepEqual(mouseActions(hook), [])

  move(hook, { x: 200, y: 50 })
  assert.equal(hook.__nativeSelecting, true)
  assert.deepEqual(mouseActions(hook), [])

  release(hook, { x: 200, y: 50 })
  await wait(50)
  assert.deepEqual(mouseActions(hook), [])
})

test("click-only tracking: a click lands on the cell the press started on", async (t) => {
  const { hook } = await paneWith(t, CLICK_ONLY)

  press(hook, { x: 120, y: 50 })
  release(hook, { x: 122, y: 50 })
  await wait(50)

  const reports = hook.pushes.filter((p) => p.event === "mouse").map((p) => p.payload)
  assert.equal(reports.length, 2)
  assert.equal(reports[0].x, reports[1].x)
  assert.equal(reports[0].y, reports[1].y)
})

test("click-only tracking: a click inside the pane retires the old highlight", async (t) => {
  const { hook } = await paneWith(t, CLICK_ONLY)

  press(hook, { x: 50, y: 50 })
  move(hook, { x: 200, y: 50 })
  release(hook, { x: 200, y: 50 })
  await wait(50)
  assert.equal(hook.__selectionActive, true)

  // A click is not a new selection, so it never re-anchors — the previous
  // highlight has to be dropped explicitly or it stays painted over output the
  // operator has moved on from.
  press(hook, { x: 300, y: 90 })
  release(hook, { x: 301, y: 90 })
  await wait(50)

  assert.equal(hook.__selectionActive, false)
  assert.equal(hook.selectionLayer.children.length, 0)
})

test("motion tracking keeps its drags: plain drag reaches the program, no selection", async (t) => {
  const { hook } = await paneWith(t, MOTION)

  press(hook, { x: 50, y: 50 })
  move(hook, { x: 200, y: 50 })
  release(hook, { x: 200, y: 50 })
  await wait(50)

  assert.notEqual(hook.__selectionActive, true)
  assert.ok(
    mouseActions(hook).includes("press"),
    `expected the drag to reach the program, got ${JSON.stringify(mouseActions(hook))}`
  )
})

test("motion tracking: Shift+drag still selects locally", async (t) => {
  const { hook } = await paneWith(t, MOTION)

  press(hook, { x: 50, y: 50, shiftKey: true })
  move(hook, { x: 200, y: 50, shiftKey: true })
  release(hook, { x: 200, y: 50, shiftKey: true })
  await wait(50)

  assert.equal(hook.__selectionActive, true)
  assert.deepEqual(mouseActions(hook), [])
})

test("no tracking: plain drag selects immediately, without deferring", async (t) => {
  const { hook } = await paneWith(t, NO_TRACKING)

  press(hook, { x: 50, y: 50 })
  // Immediate mode, not deferred: the selection opens on the press itself.
  assert.equal(hook.__nativeSelecting, true)

  move(hook, { x: 200, y: 50 })
  release(hook, { x: 200, y: 50 })
  await wait(50)

  assert.equal(hook.__selectionActive, true)
  assert.deepEqual(mouseActions(hook), [])
})
