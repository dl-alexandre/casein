// C-b leader key system + Space → focus terminal.
//
// Mounted on the persistent workspace container so it survives tab switches.
// Leader mode works from anywhere — including inside the terminal — by
// intercepting C-b in the capture phase before the terminal textarea sees it.
//
// Action dispatch: each bound key finds a [data-leader-action="<name>"] element
// and calls .click(). This works even on hidden elements inside closed dropdowns,
// so the server handles all the business logic through existing phx-click handlers.
//
// Leader has no auto-timeout (mirrors tmux behaviour). It stays active until:
//   - a second key is pressed (action or unrecognised)
//   - Escape cancels it explicitly
//   - double C-b cancels it

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
    this._onKeydown = (e) => this._handleKeydown(e)
    // Capture phase: runs before terminal textarea keydown listeners,
    // letting us intercept C-b even when the terminal has focus.
    window.addEventListener("keydown", this._onKeydown, true)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeydown, true)
    document.body.removeAttribute("data-leader-active")
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

    // Escape cancels without acting
    if (e.key === "Escape") {
      e.preventDefault()
      this._clearLeader()
      return
    }

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
      // Picker dropdowns: hold the key to navigate with arrows, release to
      // activate the focused item. Quick tap leaves the dropdown open.
      if (action === "session-picker" || action === "window-picker") {
        this._startHoldWatch(key, summaryEl)
      }
    }
  },

  _startHoldWatch(key, summaryEl) {
    const detailsEl = summaryEl?.closest("details")
    if (!detailsEl) return

    let inHoldMode = false
    let navigated = false

    const getItems = () =>
      Array.from(detailsEl.querySelectorAll("button:not([disabled]), a[href]"))

    // After 150ms: enter hold mode — focus the active or first item
    const holdTimer = setTimeout(() => {
      inHoldMode = true
      const items = getItems()
      const active = items.find(el => el.className.includes("text-primary"))
      ;(active || items[0])?.focus()
    }, 150)

    const onKeydown = (e) => {
      // Suppress the held key's repeats so they don't reach the terminal
      if (e.key === key) {
        e.preventDefault()
        e.stopPropagation()
        return
      }
      if (!inHoldMode) return
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        e.stopPropagation()
        const items = getItems()
        if (!items.length) return
        const idx = items.indexOf(document.activeElement)
        const next = e.key === "ArrowDown"
          ? (idx < 0 ? 0 : Math.min(idx + 1, items.length - 1))
          : (idx < 0 ? items.length - 1 : Math.max(idx - 1, 0))
        items[next].focus()
        navigated = true
      }
    }

    const onKeyup = (e) => {
      if (e.key !== key) return
      clearTimeout(holdTimer)
      window.removeEventListener("keyup", onKeyup, true)
      window.removeEventListener("keydown", onKeydown, true)

      if (!inHoldMode) return  // quick tap — leave dropdown open for manual use

      const focused = document.activeElement
      if (navigated && detailsEl.contains(focused)) {
        // Navigated to an item — activate it
        focused.click()
      } else {
        // Held but didn't navigate — dismiss and return to terminal
        detailsEl.removeAttribute("open")
        window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", { detail: {} }))
      }
    }

    window.addEventListener("keydown", onKeydown, true)
    window.addEventListener("keyup", onKeyup, true)
  },

  _activateLeader() {
    this._leaderActive = true
    document.body.setAttribute("data-leader-active", "")
  },

  _clearLeader() {
    this._leaderActive = false
    document.body.removeAttribute("data-leader-active")
  },
}
