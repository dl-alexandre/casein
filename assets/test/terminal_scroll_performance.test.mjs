import test from "node:test"
import assert from "node:assert/strict"

import {
  installDom,
  loadHookModule,
  makeTerminalEl,
  mountHook,
  wait,
} from "./support/terminal_hook_harness.mjs"

test("PTY wheel bursts perform one terminal hit-test per animation frame", async (t) => {
  const dom = installDom()
  t.after(() => dom.window.close())

  const {GhosttyTerminal} = await loadHookModule()
  const hook = mountHook(GhosttyTerminal, makeTerminalEl(document))
  t.after(() => hook.destroyed())

  let measurements = 0
  hook.measure.getBoundingClientRect = () => {
    measurements += 1
    return {width: 100}
  }

  for (let i = 0; i < 12; i += 1) {
    hook.el.dispatchEvent(
      new window.WheelEvent("wheel", {
        deltaY: 4,
        clientX: 40 + i,
        clientY: 60,
        bubbles: true,
        cancelable: true,
      })
    )
  }

  assert.equal(measurements, 0, "wheel handler must not synchronously force layout")
  await wait(20)
  assert.equal(measurements, 1, "coalesced PTY write needs only the latest point")
})

test("emulator scroll never computes a terminal cell", async (t) => {
  const dom = installDom()
  t.after(() => dom.window.close())

  const {GhosttyTerminal} = await loadHookModule()
  const hook = mountHook(GhosttyTerminal, makeTerminalEl(document))
  t.after(() => hook.destroyed())
  hook.scrollbar = {total: 100, offset: 50, len: 24}

  let measurements = 0
  hook.measure.getBoundingClientRect = () => {
    measurements += 1
    return {width: 100}
  }

  hook.el.dispatchEvent(
    new window.WheelEvent("wheel", {
      deltaY: 48,
      clientX: 40,
      clientY: 60,
      bubbles: true,
      cancelable: true,
    })
  )

  await wait(20)
  assert.equal(measurements, 0)
  assert.ok(hook.pushes.some(({event}) => event === "scroll"))
})
