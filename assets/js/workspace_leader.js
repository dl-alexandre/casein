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
  C: "new-window-tab",
  n: "next-window",
  p: "prev-window",
  l: "last-window",
  d: "detach",
  o: "pane-next",
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
  ",": "rename-window",
  ArrowLeft: "pane-left",
  ArrowRight: "pane-right",
  ArrowUp: "pane-up",
  ArrowDown: "pane-down",
}

// Arrow keys report as e.code on some platforms; normalize before lookup.
function leaderSecondKey(e) {
  if (typeof e.code === "string" && e.code.startsWith("Arrow")) return e.code
  return e.key
}

function phxValuePayload(el) {
  const payload = {}
  for (const attr of el.attributes) {
    if (attr.name.startsWith("phx-value-")) {
      payload[attr.name.slice("phx-value-".length)] = attr.value
    }
  }
  return payload
}

export const WorkspaceLeader = {
  mounted() {
    this._leaderActive = false
    this._onKeydown = (e) => this._handleKeydown(e)
    this._onDocClick = (e) => {
      document.querySelectorAll("details[open]").forEach((el) => {
        if (!el.contains(e.target)) el.removeAttribute("open")
      })
    }
    // Capture phase: runs before terminal textarea keydown listeners,
    // letting us intercept C-b even when the terminal has focus.
    window.addEventListener("keydown", this._onKeydown, true)
    // Close any open <details> dropdown when clicking outside it.
    document.addEventListener("click", this._onDocClick)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeydown, true)
    document.removeEventListener("click", this._onDocClick)
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

    // C-b → toggle leader mode from anywhere (including inside terminal).
    // stopImmediatePropagation is load-bearing: without it the keydown still
    // reaches the terminal handlers (they don't check defaultPrevented), the
    // PTY gets a real C-b, and tmux arms its own prefix — so the next raw
    // keystroke becomes a tmux command (e.g. `w` draws choose-tree in-pane,
    // fighting the LiveView picker).
    if (e.key === "b" && e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey) {
      e.preventDefault()
      e.stopImmediatePropagation()
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

    // Escape cancels without acting (stopped so the terminal doesn't get a
    // stray ESC byte from cancelling leader mode)
    if (e.key === "Escape") {
      e.preventDefault()
      e.stopImmediatePropagation()
      this._clearLeader()
      return
    }

    e.preventDefault()
    e.stopImmediatePropagation()
    const key = leaderSecondKey(e)
    this._clearLeader()

    // 1–9: select tmux window by index
    if (/^[1-9]$/.test(key)) {
      document.querySelector(`[data-tmux-window-index="${key}"]`)?.click()
      return
    }

    const action = LEADER_ACTIONS[key]
    if (action) {
      // rename-window: open the window dropdown first so the form is visible,
      // then click the active window's rename button.
      if (action === "rename-window") {
        document.querySelector('[data-leader-action="window-picker"]')?.click()
        document.querySelector('[data-leader-action="rename-window"]')?.click()
        return
      }

      const target = document.querySelector(`[data-leader-action="${action}"]`)
      this._dispatchLeaderAction(target)
      // Picker dropdowns: hold the key to navigate with arrows, release to
      // activate the focused item. Quick tap leaves the dropdown open.
      if (action === "session-picker" || action === "window-picker") {
        this._startHoldWatch(key, target)
      }
    }
  },

  // Route leader actions to LiveView. Simple phx-click handlers are pushed
  // directly (reliable for hidden dispatch targets); JS command bindings and
  // <summary> pickers still use a synthetic click.
  _dispatchLeaderAction(el) {
    if (!el) return

    const phxClick = el.getAttribute("phx-click")
    if (phxClick && this.pushEvent && !phxClick.startsWith("[")) {
      this.pushEvent(phxClick, phxValuePayload(el))
      return
    }

    el.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
    )
  },

  _startHoldWatch(key, summaryEl) {
    const detailsEl = summaryEl?.closest("details")
    if (!detailsEl) return

    let inHoldMode = false
    let navigated = false

    // tmux choose-tree semantics: only real picker entries (sessions, windows,
    // links) are navigable — never window toggles, rename/kill or refresh
    // buttons. Hidden entries (collapsed window lists) are skipped.
    const getItems = () =>
      Array.from(detailsEl.querySelectorAll("[data-picker-item]")).filter(
        (el) => el.offsetParent !== null && !el.disabled
      )

    // After 150ms: enter hold mode — selection starts where tmux's picker
    // would: on the entry the terminal is currently attached to.
    const holdTimer = setTimeout(() => {
      inHoldMode = true
      const items = getItems()
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
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
      if (navigated && detailsEl.contains(focused) && focused.matches("[data-picker-item]")) {
        // Navigated to an entry — activate it
        focused.click()
      } else {
        // ArrowLeft menu hop moved focus into the sibling picker — leave it
        // open and interactive instead of dismissing.
        const hoppedTo = focused?.closest?.("details[open]")
        if (hoppedTo && hoppedTo !== detailsEl) return

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
