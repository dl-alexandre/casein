// Keyboard navigation for the summoned SESSIONS sidebar (workspace ▸ session tree).
// Mirrors WindowPickerSidebar choose-tree semantics: ↑/↓, type-filter, Enter.

import {copyPickerLink} from "./picker_link_copy"
import {applyTreePickerFilter} from "./window_picker_sidebar_utils.mjs"

export const SessionsPickerSidebar = {
  mounted() {
    this._filter = ""
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)
    this._onSidebarFocus = () => this.focusInitial()
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("devide:sessions-sidebar:focus", this._onSidebarFocus)

    this.handleEvent("sidebar:focus_sessions", () => this.focusInitial())
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("devide:sessions-sidebar:focus", this._onSidebarFocus)
  },

  handleClick(e) {
    const item = e.target?.closest?.("a[data-picker-item][href][phx-click], a[data-picker-item][href][data-phx-link]")
    if (!item || !this.el.contains(item)) return
    if (wantsBrowserNavigation(e)) {
      e.stopPropagation()
      return
    }
    e.preventDefault()
  },

  handleKeydown(e) {
    switch (e.key) {
      case "ArrowDown":
      case "ArrowUp":
        e.preventDefault()
        this.moveFocus(e.key === "ArrowDown" ? 1 : -1)
        break
      case "ArrowRight": {
        e.preventDefault()
        const row = this.currentItem()
        const wsId = row?.getAttribute("phx-value-workspace-id")
        if (wsId) this.pushEvent("sidebar:toggle_workspace", {"workspace-id": wsId})
        break
      }
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
    applyTreePickerFilter(this.el, this._filter)

    const current = this.currentItem()
    if (this._filter !== "" && (!current || current.style.display === "none")) {
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
    copyPickerLink(item.href, "session")
  },

  _closeSidebar() {
    this.pushEvent("sidebar:close", {})
    window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", {detail: {}}))
  },
}

function wantsBrowserNavigation(e) {
  return e.metaKey || e.ctrlKey || (e.shiftKey && e.button === 0)
}