// tmux choose-tree keyboard navigation for the session and window dropdowns.
//
// Mounted on any <details> whose entries carry [data-picker-item]. Opening
// the dropdown moves the selection to the [data-picker-active] entry — the
// session/window the terminal is attached to, exactly where tmux's own
// picker would start — so the highlighted entry is always what Enter (or
// releasing a held C-b s / C-b w) navigates to. This replaces tmux's
// choose-tree; the real picker is never invoked.
//
// ↓/↑ move across visible items (shell, sessions, expanded windows, links),
// → on a session with windows expands them and enters the first window,
// ← collapses back to the session — or, when there is nothing to collapse
// and the <details> carries data-picker-hop-left="#other-picker", hops to
// that sibling picker (window picker ← back out to the session picker).
// Typing filters the visible entries (tmux choose-tree's `f`); Backspace
// edits the filter, Escape clears it first and closes on the second press.
//
// Expansion stays client-side: → / ← click the same per-session toggle button
// the mouse uses (`#session-windows-toggle-<dom_id>`), so chevron rotation and
// display state never drift from pointer-driven toggles.

export const SessionPicker = {
  mounted() {
    this._filter = ""
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onToggle = () => {
      if (this.el.open) {
        this.focusInitial()
      } else if (this._filter) {
        this._filter = ""
        this.applyFilter()
      }
    }
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("toggle", this._onToggle)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("toggle", this._onToggle)
  },

  // The `open` attribute is browser-set, so it is not in the server-rendered
  // HTML and a LiveView patch of this <details> strips it, snapping the
  // dropdown shut. That bites constantly here because opening the picker
  // itself triggers a refresh (terminal:refresh_sessions /
  // tmux:refresh_topology) whose re-render — new data-version, activity
  // dots — patches this element one round-trip after it opens. Carry the
  // pre-patch open state across the morph.
  beforeUpdate() {
    this._wasOpen = this.el.open
  },

  updated() {
    if (this._wasOpen && !this.el.open) this.el.setAttribute("open", "")
    // A patch wipes inline styles and the filter line; re-impose them.
    if (this._filter) this.applyFilter()
    // A patch can also replace or remove the focused entry (a window died,
    // the list reordered), dropping focus to <body> and leaving the open
    // picker with no selection. Re-seat it on the active entry.
    if (this.el.open && !this.currentItem()) this.focusInitial()
  },

  handleKeydown(e) {
    if (!this.el.open) return

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.moveFocus(1)
        break
      case "ArrowUp":
        e.preventDefault()
        this.moveFocus(-1)
        break
      case "ArrowRight":
        e.preventDefault()
        this.expandCurrent()
        break
      case "ArrowLeft":
        e.preventDefault()
        this.collapseCurrent()
        break
      case "Escape":
        e.preventDefault()
        if (this._filter) {
          this._filter = ""
          this.applyFilter()
          break
        }
        this.el.removeAttribute("open")
        this.el.querySelector("summary")?.focus()
        break
      case "Backspace":
        if (this._filter) {
          e.preventDefault()
          this._filter = this._filter.slice(0, -1)
          this.applyFilter()
        }
        break
      default:
        // Type-to-filter: printable keys narrow the list. A leading space is
        // left alone so it keeps activating the focused button natively.
        if (
          e.key.length === 1 &&
          !e.ctrlKey &&
          !e.metaKey &&
          !e.altKey &&
          (this._filter !== "" || e.key !== " ")
        ) {
          e.preventDefault()
          this._filter += e.key
          this.applyFilter()
        }
    }
  },

  // Hide entries that don't match the typed filter and surface the query in
  // the menu's [data-picker-filter] line. Inline styles only — LiveView
  // patches wipe them, so updated() re-applies.
  applyFilter() {
    const query = this._filter.toLowerCase()
    const display = this.el.querySelector("[data-picker-filter]")

    if (display) {
      display.textContent = this._filter ? `filter: ${this._filter}` : ""
      display.style.display = this._filter ? "block" : "none"
    }

    this.el.querySelectorAll("[data-picker-item]").forEach((el) => {
      const match = query === "" || el.textContent.toLowerCase().includes(query)
      el.style.display = match ? "" : "none"
    })

    // Keep the selection on a matching entry while narrowing.
    const current = this.currentItem()
    if (query !== "" && (!current || current.style.display === "none")) {
      this.visibleItems()[0]?.focus()
    }
  },

  visibleItems() {
    return Array.from(this.el.querySelectorAll("[data-picker-item]")).filter(
      (el) => el.offsetParent !== null
    )
  },

  currentItem() {
    return document.activeElement?.closest?.("[data-picker-item]") || null
  },

  moveFocus(delta) {
    const items = this.visibleItems()
    if (items.length === 0) return

    const index = items.indexOf(this.currentItem())
    const next =
      index === -1
        ? delta > 0
          ? 0
          : items.length - 1
        : Math.min(Math.max(index + delta, 0), items.length - 1)

    items[next].focus()
  },

  focusInitial() {
    requestAnimationFrame(() => {
      // A patch while the picker is open re-fires toggle (open is stripped and
      // restored, see beforeUpdate/updated); don't yank the selection away
      // from an entry the user already navigated to.
      if (this.currentItem() && this.el.contains(document.activeElement)) return

      const items = this.visibleItems()
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || items[0])?.focus()
    })
  },

  expandCurrent() {
    const item = this.currentItem()
    const domId = item?.dataset.pickerWindowsId
    if (!domId) return

    const container = this.el.querySelector(`#session-windows-${cssEscape(domId)}`)
    if (!container) return

    if (!isVisible(container)) {
      this.el.querySelector(`#session-windows-toggle-${cssEscape(domId)}`)?.click()
    }

    requestAnimationFrame(() => {
      container.querySelector("[data-picker-item]")?.focus()
    })
  },

  collapseCurrent() {
    const item = this.currentItem()

    // On a window row: collapse its session's window list and refocus the session.
    const parentId = item?.dataset.pickerParent
    const domId = parentId || item?.dataset.pickerWindowsId || null
    if (!domId) {
      this.hopLeft()
      return
    }

    const container = this.el.querySelector(`#session-windows-${cssEscape(domId)}`)
    if (container && isVisible(container)) {
      this.el.querySelector(`#session-windows-toggle-${cssEscape(domId)}`)?.click()
    }

    if (parentId) {
      this.el.querySelector(`[data-picker-windows-id="${cssEscape(parentId)}"]`)?.focus()
    }
  },

  // Menu hop: ← with nothing left to collapse moves to the sibling picker
  // named by data-picker-hop-left (window picker → session picker), like
  // backing out of a submenu. Opening via the attribute fires its toggle,
  // so the target picker seats its own selection on the active entry.
  hopLeft() {
    const targetSelector = this.el.dataset.pickerHopLeft
    if (!targetSelector) return

    const target = document.querySelector(targetSelector)
    if (!target) return

    this.el.removeAttribute("open")
    target.setAttribute("open", "")
  },
}

function isVisible(el) {
  return getComputedStyle(el).display !== "none"
}

function cssEscape(value) {
  return window.CSS?.escape ? CSS.escape(value) : value
}
