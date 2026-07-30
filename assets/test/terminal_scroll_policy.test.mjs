import assert from "node:assert/strict"
import test from "node:test"

import {
  BACKEND_EMULATOR,
  BACKEND_KEYS_PAGE,
  BACKEND_SGR,
  POLICY_AGENT,
  POLICY_SHELL,
  SELECT_DEFERRED,
  SELECT_IMMEDIATE,
  SELECT_SHIFT_ONLY,
  pageKeySteps,
  plainDragSelectMode,
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

// The mode is a property of the program's requested mouse modes, NOT of the
// scroll policy. An agent pane whose program only reads clicks must not inherit
// the Shift requirement that exists for programs which read drags.
test("plainDragSelectMode keys off motion tracking, not policy", () => {
  // tmux `mouse on`, lazygit: 1002/1003 — drags belong to the program.
  assert.equal(plainDragSelectMode({tracking: true, button: true}), SELECT_SHIFT_ONLY)
  assert.equal(plainDragSelectMode({tracking: true, any: true}), SELECT_SHIFT_ONLY)

  // Claude Code: 1000 + 1006, no motion. Clicks land, drags are ours.
  assert.equal(
    plainDragSelectMode({tracking: true, normal: true, sgr: true}),
    SELECT_DEFERRED
  )
  assert.equal(plainDragSelectMode({tracking: true, x10: true}), SELECT_DEFERRED)

  // Plain shell: nothing requested, drag selects with no ceremony.
  assert.equal(plainDragSelectMode({tracking: false}), SELECT_IMMEDIATE)
  assert.equal(plainDragSelectMode(null), SELECT_IMMEDIATE)
  assert.equal(plainDragSelectMode(undefined), SELECT_IMMEDIATE)
})

test("resolveScrollBackend and pageKeySteps", () => {
  assert.equal(resolveScrollBackend(POLICY_AGENT, null), BACKEND_SGR)
  assert.equal(resolveScrollBackend(POLICY_AGENT, "keys_page"), BACKEND_KEYS_PAGE)
  assert.equal(resolveScrollBackend(POLICY_SHELL, null), BACKEND_EMULATOR)
  assert.deepEqual(pageKeySteps(-120), {key: "PageUp", count: 2})
  assert.deepEqual(pageKeySteps(40), {key: "PageDown", count: 1})
})
