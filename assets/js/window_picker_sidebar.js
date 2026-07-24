// Keyboard navigation for the transient window-picker sidebar rail. Mirrors
// SessionPicker's choose-tree semantics on a vertical list opened by C-b w:
// ↑/↓ move, type-to-filter, o/l/r/& shortcuts, Enter activates. Closes on
// Escape (empty filter) or window selection so the tab bar stays canonical.

import {copyPickerLink} from "./picker_link_copy"
import {
  applyTreePickerFilter,
  persistSidebarSort,
  restoreSidebarSort,
} from "./window_picker_sidebar_utils.mjs"

export const WindowPickerSidebar = {
  mounted() {
    this._filter = ""
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)
    this._onSidebarFocus = () => this.focusInitial()
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("casein:window-sidebar:focus", this._onSidebarFocus)
    this.handleEvent("sidebar:focus_windows", () => this.focusInitial())
    this.handleEvent("sidebar:persist_sort", ({col, mode}) => persistSidebarSort(col, mode))
    restoreSidebarSort(this, "windows")
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("casein:window-sidebar:focus", this._onSidebarFocus)
  },

  // See SessionsPickerSidebar: keep keyboard focus inside the rail across a
  // LiveView patch so arrow keys never fall through to the page (which would
  // scroll it) after the focused row is re-rendered.
  beforeUpdate() {
    this._refocus = this.el.contains(document.activeElement)
    this._refocusId = this._refocus
      ? document.activeElement.closest("[data-picker-item]")?.id || null
      : null
  },

  updated() {
    if (!this._refocus) return
    this._refocus = false
    if (this.el.contains(document.activeElement)) return // morphdom preserved it
    const ae = document.activeElement
    if (ae && ae !== document.body) return // focus legitimately moved (e.g. terminal)
    this._restoreFocus()
  },

  _restoreFocus() {
    const items = this.visibleItems()
    if (items.length === 0) return
    const byId = this._refocusId && items.find((el) => el.id === this._refocusId)
    const active = items.find((el) => el.hasAttribute("data-picker-active"))
    ;(byId || active || items[0]).focus({preventScroll: true})
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
      case "ArrowLeft": {
        e.preventDefault()
        // Dual-rail hop: Left always drops back into Sessions.
        this._focusSessionsRail()
        break
      }
      case "ArrowRight": {
        e.preventDefault()
        // Expand/collapse multi-pane windows; stay in the Windows column.
        const row = this.currentItem()
        const windowId = row?.getAttribute("phx-value-window-id")
        if (windowId) this.pushEvent("sidebar:toggle_window", {"window-id": windowId})
        break
      }
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
      case "Tab":
        // Cycle the Windows sort chip: Tab forward, Shift+Tab back. Overrides
        // native focus traversal inside the rail — Escape is the way out.
        e.preventDefault()
        this.pushEvent("sidebar:cycle_windows_sort", {dir: e.shiftKey ? "backward" : "forward"})
        break
      case " ":
        // Space always focuses the terminal while navigating; only extends the
        // filter mid-search (multi-word window names).
        if (this._filter === "") {
          e.preventDefault()
          window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", {detail: {}}))
        } else {
          e.preventDefault()
          this._filter += " "
          this.applyFilter()
        }
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
      requestAnimationFrame(() => {
        const items = this.visibleItems()
        if (items.length === 0) return
        if (this.currentItem() && this.el.contains(document.activeElement)) return
        const active = items.find((el) => el.hasAttribute("data-picker-active"))
        ;(active || items[0])?.focus({preventScroll: false})
      })
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

  // Drop focus into the Sessions column (Miller-style Left).
  _focusSessionsRail() {
    const rail = document.querySelector("[data-sessions-picker-sidebar]")
    if (rail) {
      rail.dispatchEvent(new CustomEvent("casein:sessions-sidebar:focus"))
      const items = Array.from(rail.querySelectorAll("[data-picker-item]")).filter(
        (el) => el.offsetParent !== null && el.style.display !== "none"
      )
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || items[0])?.focus({preventScroll: false})
      return
    }
    this.pushEvent("sidebar:reveal_sessions", {})
  },
}

function wantsBrowserNavigation(e) {
  return e.metaKey || e.ctrlKey || (e.shiftKey && e.button === 0)
}
