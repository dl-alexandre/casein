// Pure C-b leader second-key dispatch decisions.
//
// WorkspaceLeader owns DOM, timers, and LiveView pushes. This module maps a
// normalized second key + surface flags to a decision object so the branch
// table can be unit-tested without mounting the hook.

import {pickerToggleDecision} from "./workspace_picker_toggle.mjs"

// Standard tmux C-b second-key → data-leader-action name.
// The command palette shows these bindings as per-item `hint` strings
// (lib/casein/command_palette/actions.ex + palette_items.ex) — keep the
// two in sync when rebinding keys.
export const LEADER_ACTIONS = {
  s: "session-picker",
  w: "window-picker",
  "(": "prev-session",
  ")": "next-session",
  c: "new-window",
  C: "new-window-tab",
  n: "next-window",
  p: "prev-window",
  l: "last-window",
  y: "copy-link",
  d: "detach",
  o: "pane-next",
  "{": "pane-swap-previous",
  "}": "pane-swap-next",
  ";": "last-pane",
  ":": "palette",
  "?": "help",
  "&": "kill-window",
  "%": "split-right",
  "|": "split-right",
  '"': "split-down",
  "-": "split-down",
  z: "zoom",
  x: "close-pane",
  q: "pane-overlay",
  ",": "rename-window",
  $: "rename-session",
  ArrowLeft: "pane-left",
  ArrowRight: "pane-right",
  ArrowUp: "pane-up",
  ArrowDown: "pane-down",
}

// Arrow keys report as e.code on some platforms; normalize before lookup.
export function leaderSecondKey(e) {
  if (typeof e?.code === "string" && e.code.startsWith("Arrow")) return e.code
  return e?.key
}

/**
 * Decide what a leader second-key should do.
 *
 * Pure: no DOM, no `this`, no timers. Callers supply surface flags already
 * derived from the document (picker visibility, help overlay, etc.).
 *
 * @param {string|null|undefined} key normalized second key (from leaderSecondKey)
 * @param {{
 *   leaderActive?: boolean,
 *   helpVisible?: boolean,
 *   canCycleHelpTab?: boolean,
 *   mobileLayout?: boolean,
 *   mobileOpen?: boolean,
 *   sessionsOpen?: boolean,
 *   windowsOpen?: boolean,
 *   windowSidebarVisible?: boolean,
 *   sessionsSidebarVisible?: boolean,
 * }} [opts]
 * @returns {{
 *   type: string,
 *   clearLeader?: boolean,
 *   index?: string,
 *   action?: string,
 *   focus?: "windows" | "sessions",
 *   holdKey?: string,
 * }}
 */
export function leaderSecondKeyDecision(key, opts = {}) {
  const {
    leaderActive = false,
    helpVisible = false,
    canCycleHelpTab = false,
    mobileLayout = false,
    mobileOpen = false,
    sessionsOpen = false,
    windowsOpen = false,
    windowSidebarVisible = false,
    sessionsSidebarVisible = false,
  } = opts

  if (!leaderActive || key == null || key === "") {
    return {type: "noop"}
  }

  // `?` while the help overlay is open cycles its tabs instead of toggling
  // the overlay closed (Escape still closes it). Falls through when there are
  // no tabs to cycle.
  if (key === "?" && helpVisible && canCycleHelpTab) {
    return {type: "cycle-help-tab", clearLeader: true}
  }

  // 0–9: select tmux window by index
  if (/^[0-9]$/.test(key)) {
    return {type: "window-index", index: key, clearLeader: true}
  }

  const action = LEADER_ACTIONS[key]
  if (!action) {
    return {type: "unknown", clearLeader: true}
  }

  if (action === "pane-overlay") {
    return {type: "pane-overlay", clearLeader: true}
  }

  if (action === "copy-link") {
    return {type: "copy-link", clearLeader: true}
  }

  if (action === "rename-window") {
    return {type: "rename-window", clearLeader: true}
  }

  if (action === "rename-session") {
    return {type: "rename-session", clearLeader: true}
  }

  if (action === "session-picker" || action === "window-picker") {
    const toggle = pickerToggleDecision(action, {
      mobileLayout,
      mobileOpen,
      sessionsOpen,
      windowsOpen,
    })

    if (toggle === "close-mobile") {
      return {type: "close-mobile", clearLeader: true}
    }

    if (toggle === "close-sidebar") {
      return {type: "close-sidebar", clearLeader: true}
    }

    if (toggle === "open-mobile") {
      return {
        type: "open-mobile",
        clearLeader: true,
        focus: action === "window-picker" ? "windows" : "sessions",
      }
    }

    // open-sidebar: focus an already-visible rail, or open then focus.
    if (action === "window-picker") {
      if (windowSidebarVisible) {
        return {type: "focus-window-sidebar", clearLeader: true, holdKey: key}
      }
      return {type: "open-window-sidebar", clearLeader: true, holdKey: key}
    }

    if (sessionsSidebarVisible) {
      return {type: "focus-sessions-sidebar", clearLeader: true, holdKey: key}
    }
    return {type: "open-sessions-sidebar", clearLeader: true, holdKey: key}
  }

  return {type: "dispatch", action, clearLeader: true}
}
