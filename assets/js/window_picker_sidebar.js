// Keyboard navigation for the transient window-picker sidebar rail. Mirrors
// SessionPicker's choose-tree semantics on a vertical list opened by C-b w:
// ↑/↓ move, type-to-filter, o/l/r/& shortcuts, Enter activates. Closes on
// Escape (empty filter) or window selection so the tab bar stays canonical.

import {copyPickerLink} from "./picker_link_copy"
import {matchesPickerFilter} from "./window_picker_sidebar_utils.mjs"

export const WindowPickerSidebar = {
  mounted() {
    this._filter = ""
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)
    this._onSidebarFocus = () => this.focusInitial()
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("devide:window-sidebar:focus", this._onSidebarFocus)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("devide:window-sidebar:focus", this._onSidebarFocus)
  },

  handleClick(e) {
    const item = e.target?.closest?.("a[data-picker-item][href][phx-click]")
    if (!item || !this.el.contains(item)) return
    if (wantsBrowserNavigation(e)) {
      e.stopPropagation()
      return
    }
    e.preventDefault()
    this._closeSidebar()
  },

  handleKeydown(e) {
    switch (e.key) {
      case "ArrowDown":
      case "ArrowUp":
        e.preventDefault()
        this.moveFocus(e.key === "ArrowDown" ? 1 : -1)
        break
      case "Enter":
        e.preventDefault()
        this.currentItem()?.click()
        break
      case "Escape":
        e.preventDefault()
        if (this._filter) {
          this._filter = ""
          this.applyFilter()
          break
        }
        this._closeSidebar()
        break
      case "Backspace":
        if (this._filter) {
          e.preventDefault()
          this._filter = this._filter.slice(0, -1)
          this.applyFilter()
        }
        break
      case "o":
      case "l":
        e.preventDefault()
        if (e.key === "o") this.openCurrentInNewTab()
        else this.copyCurrentLink()
        break
      case "r":
        e.preventDefault()
        this.renameCurrentItem()
        break
      case "&":
        e.preventDefault()
        this.killCurrentWindow()
        break
      default:
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

  applyFilter() {
    const query = this._filter.toLowerCase()
    const display = this.el.querySelector("[data-picker-filter]")

    if (display) {
      display.textContent = this._filter ? `filter: ${this._filter}` : ""
      display.style.display = this._filter ? "block" : "none"
    }

    this.el.querySelectorAll("[data-picker-item]").forEach((el) => {
      const match = matchesPickerFilter(el, query)
      el.style.display = match ? "" : "none"
    })

    const current = this.currentItem()
    if (query !== "" && (!current || current.style.display === "none")) {
      this.visibleItems()[0]?.focus()
    }
  },

  visibleItems() {
    return Array.from(this.el.querySelectorAll("[data-picker-item]")).filter(
      (el) => el.offsetParent !== null && el.style.display !== "none"
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
      if (this.currentItem() && this.el.contains(document.activeElement)) return
      const items = this.visibleItems()
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || items[0])?.focus()
    })
  },

  openCurrentInNewTab() {
    const item = this.currentItem()
    const url = item?.href
    if (!url) return
    window.open(url, "_blank", "noopener,noreferrer")
  },

  copyCurrentLink() {
    const item = this.currentItem()
    if (!item?.href) return
    copyPickerLink(item.href, "window")
  },

  renameCurrentItem() {
    const item = this.currentItem()
    const windowId = item?.getAttribute("phx-value-window-id")
    if (!windowId) return
    this.pushEvent("tmux:rename_start", {window_id: windowId})
  },

  killCurrentWindow() {
    const item = this.currentItem()
    const windowId = item?.getAttribute("phx-value-window-id")
    if (!windowId) return
    if (!window.confirm("Kill this tmux window and everything running in it?")) return
    this.pushEvent("tmux:kill_window", {window_id: windowId})
  },

  _closeSidebar() {
    this.pushEvent("sidebar:close", {})
    window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", {detail: {}}))
  },
}

function wantsBrowserNavigation(e) {
  return e.metaKey || e.ctrlKey || e.shiftKey && e.button === 0
}
