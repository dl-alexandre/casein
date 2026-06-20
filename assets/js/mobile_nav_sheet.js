// Keyboard navigation for the mobile session/window sheet.
//
// On touch (iPad) and narrow-chrome layouts the desktop session/window
// dropdowns are CSS-hidden and this bottom sheet takes over. The Ctrl+B leader
// shortcut (assets/js/workspace_leader.js) routes here — pushing "mobile_nav:open"
// with a focus hint — so a hardware-keyboard user can drive the picker without
// tapping. The sheet renders only while open (:if={@mobile_nav_open}), so this
// hook's mounted/destroyed lifecycle IS the open/close lifecycle.
//
// Mirrors the desktop SessionPicker tree semantics over the same data-attribute
// conventions ([data-picker-item], [data-picker-active], data-picker-windows-id
// on a session row, data-picker-parent on its window rows):
//   ↓/↑    move across visible rows (shell, sessions, expanded windows)
//   →      expand the focused session's windows and step into the first one
//   ←      collapse the focused session, or step a window back to its session
//   Enter  activate the focused row (== tapping it: switch + close)
//   Esc    close the sheet
//
// Expansion clicks the same per-session toggle button the finger uses
// (#mnav-windows-toggle-<dom_id>) so chevron + display state never drift.

export const MobileNavSheet = {
  mounted() {
    this._onKeydown = (e) => this.handleKeydown(e)
    this.el.addEventListener("keydown", this._onKeydown)
    this._focusHint = this.el.dataset.mobileNavFocus || "sessions"
    this.focusInitial(this._focusHint)
  },

  updated() {
    // Re-pressing Ctrl+B S / Ctrl+B W while the sheet is open changes the focus
    // hint; re-seat the cursor on the requested section.
    const hint = this.el.dataset.mobileNavFocus || "sessions"
    if (hint !== this._focusHint) {
      this._focusHint = hint
      this.focusInitial(hint)
    }
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
  },

  handleKeydown(e) {
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
      case "Enter":
        // Let the focused button's native activation fire its phx-click.
        break
      case "Escape":
        e.preventDefault()
        this.pushEvent("mobile_nav:close", {})
        break
    }
  },

  visibleItems() {
    return Array.from(this.el.querySelectorAll("[data-picker-item]")).filter(
      (el) => el.offsetParent !== null && !el.disabled
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

  // Seat the cursor on the active row of the requested section ("sessions" or
  // "windows"), falling back to the first visible item in that section, then to
  // the first visible item overall.
  focusInitial(section) {
    requestAnimationFrame(() => {
      const items = this.visibleItems()
      if (items.length === 0) return

      const inSection = items.filter((el) => el.dataset.pickerSection === section)
      const pool = inSection.length ? inSection : items
      const active = pool.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || pool[0]).focus()
    })
  },

  expandCurrent() {
    const item = this.currentItem()
    const windowsId = item?.dataset.pickerWindowsId
    if (!windowsId) return

    const container = this.el.querySelector(`#${cssEscape(`mnav-windows-${windowsId}`)}`)
    const toggle = this.el.querySelector(`#${cssEscape(`mnav-windows-toggle-${windowsId}`)}`)
    if (!container || !toggle) return

    if (!isVisible(container)) toggle.click()

    requestAnimationFrame(() => {
      container.querySelector("[data-picker-item]")?.focus()
    })
  },

  collapseCurrent() {
    const item = this.currentItem()

    // On a window row: collapse its parent session's group and refocus the
    // session row that owns it.
    const parentId = item?.dataset.pickerParent
    if (parentId) {
      const container = this.el.querySelector(`#${cssEscape(`mnav-windows-${parentId}`)}`)
      const toggle = this.el.querySelector(`#${cssEscape(`mnav-windows-toggle-${parentId}`)}`)
      if (container && isVisible(container)) toggle?.click()
      this.el.querySelector(`[data-picker-windows-id="${cssEscape(parentId)}"]`)?.focus()
      return
    }

    // On a session row with its windows expanded: collapse them.
    const windowsId = item?.dataset.pickerWindowsId
    if (!windowsId) return
    const container = this.el.querySelector(`#${cssEscape(`mnav-windows-${windowsId}`)}`)
    const toggle = this.el.querySelector(`#${cssEscape(`mnav-windows-toggle-${windowsId}`)}`)
    if (container && isVisible(container)) toggle?.click()
  },
}

function isVisible(el) {
  return getComputedStyle(el).display !== "none"
}

function cssEscape(value) {
  return window.CSS?.escape ? CSS.escape(value) : value
}
