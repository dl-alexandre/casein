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
// ← collapses back to the session, Escape closes the dropdown.
//
// Expansion stays client-side: → / ← click the same per-session toggle button
// the mouse uses (`#session-windows-toggle-<dom_id>`), so chevron rotation and
// display state never drift from pointer-driven toggles.

export const SessionPicker = {
  mounted() {
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onToggle = () => {
      if (this.el.open) this.focusInitial()
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
        this.el.removeAttribute("open")
        this.el.querySelector("summary")?.focus()
        break
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
    if (!item) return

    // On a window row: collapse its session's window list and refocus the session.
    const parentId = item.dataset.pickerParent
    const domId = parentId || (item.dataset.pickerWindowsId ?? null)
    if (!domId) return

    const container = this.el.querySelector(`#session-windows-${cssEscape(domId)}`)
    if (container && isVisible(container)) {
      this.el.querySelector(`#session-windows-toggle-${cssEscape(domId)}`)?.click()
    }

    if (parentId) {
      this.el.querySelector(`[data-picker-windows-id="${cssEscape(parentId)}"]`)?.focus()
    }
  },
}

function isVisible(el) {
  return getComputedStyle(el).display !== "none"
}

function cssEscape(value) {
  return window.CSS?.escape ? CSS.escape(value) : value
}
