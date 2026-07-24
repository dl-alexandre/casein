// Terminal scroll policy — shell vs agent TUI routing.
//
// Agent TUIs (Grok, Claude, Codex, …) own the alt screen + mouse tracking.
// Wheel must go to the PTY at the pointer cell; selection is Shift-only.
// Shell mode uses Ghostty emulator scrollback when present.

export const POLICY_AGENT = "agent"
export const POLICY_SHELL = "shell"

export const BACKEND_SGR = "sgr_mouse"
export const BACKEND_KEYS_PAGE = "keys_page"
export const BACKEND_EMULATOR = "emulator"

const AGENT_COMMAND_RE = /grok|claude|codex|opencode|composer/i

/**
 * Resolve scroll policy from server pane attrs + live emulator state.
 *
 * @param {{
 *   serverPolicy?: string|null,
 *   paneCommand?: string|null,
 *   paneRole?: string|null,
 *   mouseTracking?: boolean,
 *   hasEmulatorScrollback?: boolean
 * }} input
 */
export function resolveScrollPolicy(input = {}) {
  const server = String(input.serverPolicy || "").toLowerCase()
  if (server === POLICY_AGENT || server === POLICY_SHELL) return server

  const role = String(input.paneRole || "").toLowerCase()
  if (role === "agent") return POLICY_AGENT

  if (input.paneCommand && AGENT_COMMAND_RE.test(input.paneCommand)) {
    return POLICY_AGENT
  }

  // Fallback: mouse tracking + empty emulator history ≈ alt-screen TUI.
  if (input.mouseTracking && !input.hasEmulatorScrollback) {
    return POLICY_AGENT
  }

  return POLICY_SHELL
}

/**
 * @param {string} policy
 * @param {string|null|undefined} serverBackend
 */
export function resolveScrollBackend(policy, serverBackend) {
  if (policy === POLICY_AGENT) {
    const backend = String(serverBackend || BACKEND_SGR).toLowerCase()
    if (backend === BACKEND_KEYS_PAGE) return BACKEND_KEYS_PAGE
    return BACKEND_SGR
  }
  return BACKEND_EMULATOR
}

/**
 * Whether wheel/touch should write SGR/keys to the PTY instead of emulator scroll.
 */
export function wheelGoesToPty(policy, hasEmulatorScrollback) {
  if (policy === POLICY_AGENT) return true
  return !hasEmulatorScrollback
}

/**
 * Whether one-finger touch should use the wheel pipeline (not arrow d-pad).
 * Agent mode always uses wheel; shell uses wheel when history exists or two fingers.
 */
export function touchUsesWheelPipeline(policy, touchFingers, hasEmulatorScrollback) {
  if (policy === POLICY_AGENT) return true
  return touchFingers >= 2 || hasEmulatorScrollback
}

/**
 * Whether plain primary drag should start local cell selection.
 * Agent / mouse-tracking: only with Shift (iTerm convention).
 */
export function allowPlainDragSelect(policy, mouseTracking, shiftKey) {
  if (policy === POLICY_AGENT || mouseTracking) return Boolean(shiftKey)
  return true
}

/**
 * Page-key count for keys_page backend (one key per notch, capped).
 */
export function pageKeySteps(deltaY) {
  if (!Number.isFinite(deltaY) || deltaY === 0) return {key: null, count: 0}
  const notches = Math.max(1, Math.min(4, Math.ceil(Math.abs(deltaY) / 80)))
  return {key: deltaY < 0 ? "PageUp" : "PageDown", count: notches}
}

/**
 * Read focused pane interaction attrs from the workspace DOM.
 */
export function readFocusedPaneScrollAttrs(root = document) {
  if (!root || typeof root.querySelector !== "function") {
    return {serverPolicy: null, serverBackend: null, paneCommand: null, paneRole: null, paneId: null}
  }

  const active =
    root.querySelector('[data-pane-id][data-pane-active="true"]') ||
    root.querySelector("[data-pane-id][data-pane-command]")

  if (!active) {
    return {serverPolicy: null, serverBackend: null, paneCommand: null, paneRole: null, paneId: null}
  }

  return {
    serverPolicy: active.dataset.scrollPolicy || null,
    serverBackend: active.dataset.scrollBackend || null,
    paneCommand: active.dataset.paneCommand || null,
    paneRole: active.dataset.paneRole || null,
    paneId: active.dataset.paneId || null
  }
}

export function scrollDebugEnabled() {
  try {
    if (typeof localStorage !== "undefined" && localStorage.getItem("casein:termscroll") === "1") {
      return true
    }
  } catch {
    // ignore
  }
  try {
    if (typeof location !== "undefined" && /(?:\?|&)termscroll=1(?:&|$)/.test(location.search)) {
      return true
    }
  } catch {
    // ignore
  }
  return false
}
