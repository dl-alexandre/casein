import assert from "node:assert/strict"
import test from "node:test"

import {
  BACKEND_EMULATOR,
  BACKEND_KEYS_PAGE,
  BACKEND_SGR,
  POLICY_AGENT,
  POLICY_SHELL,
  allowPlainDragSelect,
  pageKeySteps,
  resolveScrollBackend,
  resolveScrollPolicy,
  touchUsesWheelPipeline,
  wheelGoesToPty
} from "../js/terminal_scroll_policy.mjs"

test("resolveScrollPolicy prefers server agent policy", () => {
  assert.equal(
    resolveScrollPolicy({serverPolicy: "agent", hasEmulatorScrollback: true}),
    POLICY_AGENT
  )
})

test("resolveScrollPolicy uses role and command", () => {
  assert.equal(resolveScrollPolicy({paneRole: "agent"}), POLICY_AGENT)
  assert.equal(resolveScrollPolicy({paneCommand: "grok"}), POLICY_AGENT)
  assert.equal(resolveScrollPolicy({paneCommand: "bash"}), POLICY_SHELL)
})

test("resolveScrollPolicy falls back to mouse+no-scrollback", () => {
  assert.equal(
    resolveScrollPolicy({mouseTracking: true, hasEmulatorScrollback: false}),
    POLICY_AGENT
  )
  assert.equal(
    resolveScrollPolicy({mouseTracking: true, hasEmulatorScrollback: true}),
    POLICY_SHELL
  )
})

test("wheelGoesToPty is always true for agent mode", () => {
  assert.equal(wheelGoesToPty(POLICY_AGENT, true), true)
  assert.equal(wheelGoesToPty(POLICY_SHELL, true), false)
  assert.equal(wheelGoesToPty(POLICY_SHELL, false), true)
})

test("touchUsesWheelPipeline never arrows in agent mode", () => {
  assert.equal(touchUsesWheelPipeline(POLICY_AGENT, 1, false), true)
  assert.equal(touchUsesWheelPipeline(POLICY_SHELL, 1, false), false)
  assert.equal(touchUsesWheelPipeline(POLICY_SHELL, 2, false), true)
})

test("allowPlainDragSelect requires Shift under agent/tracking", () => {
  assert.equal(allowPlainDragSelect(POLICY_AGENT, true, false), false)
  assert.equal(allowPlainDragSelect(POLICY_AGENT, true, true), true)
  assert.equal(allowPlainDragSelect(POLICY_SHELL, false, false), true)
})

test("resolveScrollBackend and pageKeySteps", () => {
  assert.equal(resolveScrollBackend(POLICY_AGENT, null), BACKEND_SGR)
  assert.equal(resolveScrollBackend(POLICY_AGENT, "keys_page"), BACKEND_KEYS_PAGE)
  assert.equal(resolveScrollBackend(POLICY_SHELL, null), BACKEND_EMULATOR)
  assert.deepEqual(pageKeySteps(-120), {key: "PageUp", count: 2})
  assert.deepEqual(pageKeySteps(40), {key: "PageDown", count: 1})
})
