import assert from "node:assert/strict"
import test from "node:test"

import {
  LEADER_ACTIONS,
  leaderSecondKey,
  leaderSecondKeyDecision,
} from "../js/workspace_leader_election.mjs"

const inactive = {leaderActive: false}
const armed = {leaderActive: true}

test("leaderSecondKey prefers e.code for Arrow keys", () => {
  assert.equal(leaderSecondKey({key: "Left", code: "ArrowLeft"}), "ArrowLeft")
  assert.equal(leaderSecondKey({key: "ArrowRight", code: "ArrowRight"}), "ArrowRight")
})

test("leaderSecondKey falls back to e.key for non-arrow keys", () => {
  assert.equal(leaderSecondKey({key: "w", code: "KeyW"}), "w")
  assert.equal(leaderSecondKey({key: "?", code: "Slash"}), "?")
  assert.equal(leaderSecondKey({key: "3"}), "3")
})

test("leaderSecondKey tolerates missing event fields", () => {
  assert.equal(leaderSecondKey(undefined), undefined)
  assert.equal(leaderSecondKey({}), undefined)
  assert.equal(leaderSecondKey({code: 12}), undefined)
})

test("noop when leader is inactive or key is empty", () => {
  assert.deepEqual(leaderSecondKeyDecision("w", inactive), {type: "noop"})
  assert.deepEqual(leaderSecondKeyDecision("", armed), {type: "noop"})
  assert.deepEqual(leaderSecondKeyDecision(null, armed), {type: "noop"})
  assert.deepEqual(leaderSecondKeyDecision(undefined, armed), {type: "noop"})
})

test("digit keys select a window by index and clear leader", () => {
  assert.deepEqual(leaderSecondKeyDecision("0", armed), {
    type: "window-index",
    index: "0",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("9", armed), {
    type: "window-index",
    index: "9",
    clearLeader: true,
  })
})

test("bound action keys dispatch the mapped leader action", () => {
  assert.deepEqual(leaderSecondKeyDecision("n", armed), {
    type: "dispatch",
    action: "next-window",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("z", armed), {
    type: "dispatch",
    action: "zoom",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("ArrowUp", armed), {
    type: "dispatch",
    action: "pane-up",
    clearLeader: true,
  })
  assert.equal(LEADER_ACTIONS.n, "next-window")
})

test("unrecognised keys only clear leader", () => {
  assert.deepEqual(leaderSecondKeyDecision("g", armed), {
    type: "unknown",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("F1", armed), {
    type: "unknown",
    clearLeader: true,
  })
})

test("special-cased actions do not go through generic dispatch", () => {
  assert.deepEqual(leaderSecondKeyDecision("q", armed), {
    type: "pane-overlay",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("y", armed), {
    type: "copy-link",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision(",", armed), {
    type: "rename-window",
    clearLeader: true,
  })
  assert.deepEqual(leaderSecondKeyDecision("$", armed), {
    type: "rename-session",
    clearLeader: true,
  })
})

test("? cycles help tabs when the overlay is open with tabs", () => {
  assert.deepEqual(
    leaderSecondKeyDecision("?", {
      ...armed,
      helpVisible: true,
      canCycleHelpTab: true,
    }),
    {type: "cycle-help-tab", clearLeader: true},
  )
})

test("? falls through to help dispatch when it cannot cycle tabs", () => {
  assert.deepEqual(
    leaderSecondKeyDecision("?", {
      ...armed,
      helpVisible: true,
      canCycleHelpTab: false,
    }),
    {type: "dispatch", action: "help", clearLeader: true},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("?", {...armed, helpVisible: false}),
    {type: "dispatch", action: "help", clearLeader: true},
  )
})

test("session/window picker shortcuts toggle mobile nav when mobile layout", () => {
  assert.deepEqual(
    leaderSecondKeyDecision("s", {
      ...armed,
      mobileLayout: true,
      mobileOpen: true,
    }),
    {type: "close-mobile", clearLeader: true},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("w", {
      ...armed,
      mobileLayout: true,
      mobileOpen: false,
    }),
    {type: "open-mobile", clearLeader: true, focus: "windows"},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("s", {
      ...armed,
      mobileLayout: true,
      mobileOpen: false,
    }),
    {type: "open-mobile", clearLeader: true, focus: "sessions"},
  )
})

test("repeating an open desktop picker closes the sidebar", () => {
  assert.deepEqual(
    leaderSecondKeyDecision("s", {
      ...armed,
      sessionsOpen: true,
      windowsOpen: true,
    }),
    {type: "close-sidebar", clearLeader: true},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("w", {
      ...armed,
      windowsOpen: true,
    }),
    {type: "close-sidebar", clearLeader: true},
  )
})

test("opening a desktop picker focuses a visible rail or opens it", () => {
  assert.deepEqual(
    leaderSecondKeyDecision("w", {
      ...armed,
      windowSidebarVisible: true,
    }),
    {type: "focus-window-sidebar", clearLeader: true, holdKey: "w"},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("w", armed),
    {type: "open-window-sidebar", clearLeader: true, holdKey: "w"},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("s", {
      ...armed,
      sessionsSidebarVisible: true,
    }),
    {type: "focus-sessions-sidebar", clearLeader: true, holdKey: "s"},
  )
  assert.deepEqual(
    leaderSecondKeyDecision("s", armed),
    {type: "open-sessions-sidebar", clearLeader: true, holdKey: "s"},
  )
})

test("a different closed desktop picker opens rather than closing", () => {
  // Session picker while only the window rail is open → open sessions path.
  assert.deepEqual(
    leaderSecondKeyDecision("s", {
      ...armed,
      windowsOpen: true,
      windowSidebarVisible: true,
    }),
    {type: "open-sessions-sidebar", clearLeader: true, holdKey: "s"},
  )
})
