// C-b leader key system + Space → focus terminal.
//
// Mounted on the persistent workspace container so it survives tab switches.
// Leader mode works from anywhere — including inside the terminal — by
// intercepting C-b in the capture phase before the terminal textarea sees it.
//
// Action dispatch: each bound key finds a [data-leader-action="<name>"] element
// and calls .click(). This works even on hidden elements inside closed dropdowns,
// so the server handles all the business logic through existing phx-click handlers.

const LEADER_TIMEOUT_MS = 2000

const INTERACTIVE_SELECTOR =
  'input, textarea, button, select, a[href], [contenteditable="true"], summary, [role="textbox"], [role="button"], [role="combobox"]'

function isInteractivelyFocused() {
  const el = document.activeElement
  if (!el || el === document.body || el === document.documentElement) return false
  return el.matches(INTERACTIVE_SELECTOR) || !!el.closest(INTERACTIVE_SELECTOR)
}

// Standard tmux C-b second-key → data-leader-action name
const LEADER_ACTIONS = {
  s: "session-picker",
  w: "window-picker",
  c: "new-window",
  n: "next-window",
  p: "prev-window",
  "%": "split-right",
  "|": "split-right",
  '"': "split-down",
  "-": "split-down",
  z: "zoom",
  x: "close-pane",
  ",": "rename-window",
}

export const WorkspaceLeader = {
  mounted() {
    this._leaderActive = false
    this._leaderTimer = null
    this._onKeydown = (e) => this._handleKeydown(e)
    // Capture phase: runs before terminal textarea keydown listeners,
    // letting us intercept C-b even when the terminal has focus.
    window.addEventListener("keydown", this._onKeydown, true)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeydown, true)
    this._clearLeader()
  },

  _handleKeydown(e) {
    // Space → focus terminal when nothing interactive is focused
    if (e.key === " " && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
      if (!isInteractivelyFocused()) {
        e.preventDefault()
        window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", { detail: {} }))
        return
      }
    }

    // C-b → toggle leader mode from anywhere (including inside terminal)
    if (e.key === "b" && e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
      e.preventDefault()
      if (this._leaderActive) {
        this._clearLeader() // double C-b cancels
      } else {
        this._activateLeader()
      }
      return
    }

    if (!this._leaderActive) return

    // Ignore bare modifier keydowns while waiting for the second key
    if (["Control", "Meta", "Alt", "Shift"].includes(e.key)) return

    e.preventDefault()
    const key = e.key
    this._clearLeader()

    // 1–9: select tmux window by index
    if (/^[1-9]$/.test(key)) {
      document.querySelector(`[data-tmux-window-index="${key}"]`)?.click()
      return
    }

    const action = LEADER_ACTIONS[key]
    if (action) {
      const summaryEl = document.querySelector(`[data-leader-action="${action}"]`)
      summaryEl?.click()
      // Picker dropdowns support hold-to-peek: hold the key to browse, release
      // without selecting to dismiss the dropdown and focus the terminal instead.
      if (action === "session-picker" || action === "window-picker") {
        this._startHoldWatch(key, summaryEl)
      }
    }
  },

  _startHoldWatch(key, summaryEl) {
    const detailsEl = summaryEl?.closest("details")
    if (!detailsEl) return

    let inHoldMode = false
    const holdTimer = setTimeout(() => { inHoldMode = true }, 200)

    const onKeyup = (e) => {
      if (e.key !== key) return
      clearTimeout(holdTimer)
      window.removeEventListener("keyup", onKeyup, true)
      if (inHoldMode && detailsEl.hasAttribute("open")) {
        detailsEl.removeAttribute("open")
        window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", { detail: {} }))
      }
    }
    window.addEventListener("keyup", onKeyup, true)
  },

  _activateLeader() {
    if (this._leaderTimer) clearTimeout(this._leaderTimer)
    this._leaderActive = true
    document.body.setAttribute("data-leader-active", "")
    this._leaderTimer = setTimeout(() => this._clearLeader(), LEADER_TIMEOUT_MS)
  },

  _clearLeader() {
    this._leaderActive = false
    document.body.removeAttribute("data-leader-active")
    if (this._leaderTimer) {
      clearTimeout(this._leaderTimer)
      this._leaderTimer = null
    }
  },
}
