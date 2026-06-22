import {copyPickerLink} from "./picker_link_copy"
import {setTerminalPresetReporter, setTerminalSchemeReporter} from "./terminal_themes"

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
  y: "copy-link",
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
  q: "pane-overlay",
  ",": "rename-window",
  $: "rename-session",
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

function leaderHelpVisible() {
  const help = document.getElementById("leader-cheatsheet")
  return help && getComputedStyle(help).display !== "none"
}

function closeLeaderHelp() {
  const help = document.getElementById("leader-cheatsheet")
  if (help) help.style.display = "none"
}

export const WorkspaceLeader = {
  mounted() {
    this._leaderActive = false
    this._paneOverlayActive = false
    this._touchStart = null

    this._onKeydown = (e) => this._handleKeydown(e)
    this._onLeaderSecondKey = (e) => this._handleLeaderSecondKey(e.detail?.key)
    this._onClick = (e) => {
      const button = e.target.closest("[data-leader-prefix-button]")
      if (!button || !this.el.contains(button)) return

      e.preventDefault()
      if (this._leaderActive) {
        this._clearLeader()
      } else {
        this._activateLeader()
      }
    }
    this._onDocClick = (e) => {
      document.querySelectorAll("details[open]").forEach((el) => {
        if (!el.contains(e.target)) el.removeAttribute("open")
      })
    }
    this._onTouchStart = (e) => {
      const el = e.target
      if (el.closest('button, input, textarea, select, details, [role="button"]')) return
      if (el.closest(".workspace-main-header, .mobile-key-bar")) return
      this._touchStart = {
        x: e.touches[0].clientX,
        y: e.touches[0].clientY,
        fingers: e.touches.length,
      }
    }
    this._onTouchEnd = (e) => {
      const start = this._touchStart
      this._touchStart = null
      if (!start) return

      const dx = e.changedTouches[0].clientX - start.x
      const dy = e.changedTouches[0].clientY - start.y
      const adx = Math.abs(dx)
      const ady = Math.abs(dy)

      // Two-finger tap (little travel) → toggle the soft keyboard.
      if (start.fingers >= 2 && adx < 30 && ady < 30) {
        this._toggleSoftKeyboard()
        return
      }

      // Horizontal swipe → focus the adjacent pane. (Vertical drags over a
      // terminal are handled live, with inertia, by the GhosttyTerminal hook.)
      if (adx >= 60 && adx > ady) {
        this.pushEvent(dx < 0 ? "pane:focus_next" : "pane:focus_previous", {})
        return
      }
    }

    window.addEventListener("keydown", this._onKeydown, true)
    window.addEventListener("devide:leader-second-key", this._onLeaderSecondKey)
    this.el.addEventListener("click", this._onClick)
    document.addEventListener("click", this._onDocClick)
    document.addEventListener("touchstart", this._onTouchStart, { passive: true })
    document.addEventListener("touchend", this._onTouchEnd, { passive: true })
    this._renderLeaderButtons()

    setTerminalSchemeReporter((scheme) => {
      if (this.pushEvent) this.pushEvent("terminal:scheme", {scheme})
    })

    setTerminalPresetReporter((preset) => {
      if (this.pushEvent) this.pushEvent("terminal:set_preset", {preset})
    })

    try {
      if (
        window.matchMedia("(pointer: coarse)").matches &&
        !window.sessionStorage.getItem("devide-touch-chrome-init")
      ) {
        window.sessionStorage.setItem("devide-touch-chrome-init", "1")
        this.pushEvent("terminal:auto_hide_chrome", {})
      }
    } catch (_) {
      /* sessionStorage unavailable */
    }
  },

  destroyed() {
    setTerminalSchemeReporter(null)
    setTerminalPresetReporter(null)

    window.removeEventListener("keydown", this._onKeydown, true)
    window.removeEventListener("devide:leader-second-key", this._onLeaderSecondKey)
    this.el.removeEventListener("click", this._onClick)
    document.removeEventListener("click", this._onDocClick)
    document.removeEventListener("touchstart", this._onTouchStart)
    document.removeEventListener("touchend", this._onTouchEnd)
    document.body.removeAttribute("data-leader-active")
    this._renderLeaderButtons(false)
    this._clearPaneOverlay()
  },

  _handleKeydown(e) {
    if (e.key === "Escape" && leaderHelpVisible()) {
      e.preventDefault()
      e.stopImmediatePropagation()
      closeLeaderHelp()
      return
    }

    if (this._paneOverlayActive) {
      if (e.key === "Escape") {
        e.preventDefault()
        e.stopImmediatePropagation()
        this._clearPaneOverlay()
        return
      }

      if (/^[0-9]$/.test(e.key)) {
        e.preventDefault()
        e.stopImmediatePropagation()
        this._selectPaneByIndex(Number(e.key))
        this._clearPaneOverlay()
        return
      }

      if (e.key === "q" && !e.ctrlKey) {
        e.preventDefault()
        e.stopImmediatePropagation()
        this._clearPaneOverlay()
        return
      }
    }
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
    this._handleLeaderSecondKey(key)
  },

  _handleLeaderSecondKey(key) {
    if (!this._leaderActive || !key) return

    this._clearLeader()

    // 1–9: select tmux window by index
    if (/^[1-9]$/.test(key)) {
      document.querySelector(`[data-tmux-window-index="${key}"]`)?.click()
      return
    }

    const action = LEADER_ACTIONS[key]
    if (action) {
      if (action === "pane-overlay") {
        this._activatePaneOverlay()
        return
      }

      if (action === "copy-link") {
        const url = document.querySelector('[data-leader-action="copy-link"]')?.dataset.copySessionLink
        copyPickerLink(url, "view")
        return
      }

      // rename-window: open the window dropdown first so the form is visible,
      // then click the active window's rename button.
      if (action === "rename-window") {
        this._withLeaderDispatch(() => {
          document.querySelector('[data-leader-action="window-picker"]')?.click()
          document.querySelector('[data-leader-action="rename-window"]')?.click()
        })
        return
      }

      // rename-session: open the session dropdown first so the form is visible,
      // then click the active session's rename button.
      if (action === "rename-session") {
        this._withLeaderDispatch(() => {
          document.querySelector('[data-leader-action="session-picker"]')?.click()
          document.querySelector('[data-leader-action="rename-session"]')?.click()
        })
        return
      }

      const target = document.querySelector(`[data-leader-action="${action}"]`)

      // On touch/narrow layouts the desktop session/window dropdowns are
      // CSS-hidden (the mobile nav sheet takes over). Clicking a display:none
      // <summary> does nothing, so route the picker shortcut to the mobile
      // sheet instead — focusing sessions for C-b s, windows for C-b w. The
      // sheet renders async (a server round-trip), so there is nothing to
      // hold-navigate yet; its own MobileNavSheet hook drives the keyboard.
      if (action === "session-picker" || action === "window-picker") {
        if (!target || target.offsetParent === null) {
          this.pushEvent("mobile_nav:open", {
            focus: action === "window-picker" ? "windows" : "sessions",
          })
          return
        }

        // Desktop: hold the key to navigate with arrows, release to activate
        // the focused item. Quick tap leaves the dropdown open.
        this._dispatchLeaderAction(target)
        this._startHoldWatch(key, target)
        return
      }

      this._dispatchLeaderAction(target)
    }
  },

  // Route leader actions to LiveView. Simple phx-click handlers are pushed
  // directly (reliable for hidden dispatch targets); JS command bindings and
  // <summary> pickers still use a synthetic click.
  _dispatchLeaderAction(el) {
    if (!el) return

    // A <summary> must be clicked, not pushed: clicking it is what toggles its
    // parent <details> open. Pushing its phx-click (e.g. the window picker's
    // plain "tmux:refresh_topology") fires the refresh but leaves the dropdown
    // shut — so the synthetic-click path below handles summaries, which both
    // opens the menu and triggers the phx-click. Only non-summary dispatch
    // targets (hidden next/prev/new-window buttons) take the direct push.
    const isSummary = el.tagName === "SUMMARY"
    const phxClick = el.getAttribute("phx-click")
    if (phxClick && this.pushEvent && !phxClick.startsWith("[") && !isSummary) {
      this._withLeaderDispatch(() => this.pushEvent(phxClick, phxValuePayload(el)))
      return
    }

    this._withLeaderDispatch(() => {
      el.dispatchEvent(
        new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
      )
    })
  },

  _withLeaderDispatch(callback) {
    document.body.setAttribute("data-leader-dispatching", "")
    try {
      callback()
    } finally {
      setTimeout(() => document.body.removeAttribute("data-leader-dispatching"), 0)
    }
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
    this._renderLeaderButtons()
  },

  _clearLeader() {
    this._leaderActive = false
    document.body.removeAttribute("data-leader-active")
    this._renderLeaderButtons()
  },

  // Vertical swipe → synthetic wheel ticks on the terminal. Finger-down
  // (dy > 0) reveals earlier lines, i.e. a wheel-up (negative deltaY). Emit
  // several ticks so a full swipe pages rather than nudges; the terminal's
  // own wheel handler routes them to scrollback or tmux copy-mode.
  // Two-finger tap → raise the soft keyboard, or dismiss it if a terminal
  // input already holds focus.
  _toggleSoftKeyboard() {
    const active = document.activeElement
    if (active && active.tagName === "TEXTAREA") {
      active.blur()
    } else {
      window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", {detail: {}}))
    }
  },

  _renderLeaderButtons(forceActive) {
    const active = typeof forceActive === "boolean" ? forceActive : this._leaderActive
    this.el.querySelectorAll("[data-leader-prefix-button]").forEach((button) => {
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  },

  _activatePaneOverlay() {
    const panes = this._paneOverlayTargets()
    if (panes.length < 2) return

    this._paneOverlayActive = true
    document.body.setAttribute("data-pane-overlay-active", "")
  },

  _clearPaneOverlay() {
    this._paneOverlayActive = false
    document.body.removeAttribute("data-pane-overlay-active")
  },

  _paneOverlayTargets() {
    return Array.from(document.querySelectorAll("[data-pane-index]"))
  },

  _selectPaneByIndex(index) {
    const paneEl = document.querySelector(`[data-pane-index="${index}"]`)
    if (!paneEl) return

    const paneId = paneEl.getAttribute("data-pane-id")
    if (!paneId) return

    if (paneEl.getAttribute("data-pane-active") === "true") {
      window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", { detail: {} }))
      return
    }

    if (this.pushEvent) {
      this.pushEvent("tmux:select_pane", {"pane-id": paneId})
      return
    }

    paneEl.click()
  },
}
