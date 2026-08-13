// Keyboard navigation for the summoned SESSIONS sidebar (workspace ▸ session tree).
// Mirrors WindowPickerSidebar choose-tree semantics: ↑/↓, type-filter, Enter.

import {copyPickerLink} from "./picker_link_copy"
import {
  bindPickerPreview,
  resetPickerPreview,
  schedulePickerPreview,
  unbindPickerPreview,
} from "./picker_preview.mjs"
import {
  applyTreePickerFilter,
  persistSidebarSort,
  restoreSidebarSort,
} from "./window_picker_sidebar_utils.mjs"

export const SessionsPickerSidebar = {
  mounted() {
    this._filter = ""
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)
    this._onSidebarFocus = () => this.focusInitial()
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("casein:sessions-sidebar:focus", this._onSidebarFocus)

    this.handleEvent("sidebar:focus_sessions", () => this.focusInitial())
    this.handleEvent("sidebar:persist_sort", ({col, mode}) => persistSidebarSort(col, mode))
    restoreSidebarSort(this, "sessions")
    bindPickerPreview(this)
  },

  destroyed() {
    unbindPickerPreview(this)
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("casein:sessions-sidebar:focus", this._onSidebarFocus)
  },

  // A LiveView patch (expand/collapse, sort, or a background activity update)
  // can remove the row that holds keyboard focus, dropping focus to <body> —
  // after which arrow keys scroll the page instead of moving the selection.
  // Record focus intent before the patch, restore it after if the patch
  // orphaned it. Scoped to *this* patch so background re-renders never yank
  // focus away from the terminal.
  beforeUpdate() {
    this._refocus = this.el.contains(document.activeElement)
    this._refocusId = this._refocus
      ? document.activeElement.closest("[data-picker-item]")?.id || null
      : null
  },

  updated() {
    // The filter is client-only DOM state (row `display`, the query line), so a
    // server patch — an activity tick, a session poll — reverts it within a
    // frame and the rail silently un-filters under the user. Re-apply before
    // the focus restore below, so it picks from the filtered set.
    if (this._filter !== "") this.applyFilter()

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
      case "ArrowLeft": {
        e.preventDefault()
        // Collapse an expanded branch; stay in the Sessions column.
        this._collapseIfExpanded(this.currentItem())
        break
      }
      case "ArrowRight": {
        e.preventDefault()
        // On a collapsed workspace/browse branch, Right descends (expands it) —
        // the keyboard counterpart to the chevron, since Enter now opens the
        // row's home session instead of toggling. On anything already open (or a
        // leaf), Right does the dual-rail hop into the Windows column.
        this._expandOrHopWindows(this.currentItem())
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
      case "Tab":
        // Cycle the sort chip: Tab forward, Shift+Tab back. This overrides
        // native focus traversal inside the rail — Escape is the documented
        // way out — which is the tradeoff we chose for a one-key sort toggle.
        e.preventDefault()
        this.pushEvent("sidebar:cycle_sessions_sort", {dir: e.shiftKey ? "backward" : "forward"})
        break
      case " ":
        // Space always focuses the terminal while navigating rows; it only
        // extends the filter mid-search (so multi-word session names work).
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
    schedulePickerPreview(this)
  },

  focusInitial() {
    // Force focus into this rail even when another rail currently holds it
    // (Miller hop). Double-rAF waits for any pending LiveView patch.
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
    copyPickerLink(item.href, "session")
  },

  _closeSidebar() {
    resetPickerPreview(this)
    this.pushEvent("sidebar:close", {})
    window.dispatchEvent(new CustomEvent("phx:terminal:focus_active", {detail: {}}))
  },

  _collapseIfExpanded(row) {
    if (!row) return false
    const branch = row.closest?.("[data-picker-tree-branch]")
    if (!branch || !this.el.contains(branch)) return false
    const children = branch.querySelector("[data-picker-branch-children]")
    if (!children) return false
    const collapsed =
      children.hasAttribute("data-picker-collapsed") || children.classList.contains("hidden")
    if (collapsed) return false

    const wsId = row.getAttribute("phx-value-workspace-id")
    if (wsId) {
      this.pushEvent("sidebar:toggle_workspace", {"workspace-id": wsId})
      return true
    }
    const rel = row.getAttribute("phx-value-rel")
    if (rel !== null && rel !== undefined) {
      this.pushEvent("sidebar:toggle_browse", {rel})
      return true
    }
    return false
  },

  // Right on a COLLAPSED workspace/browse branch expands it (keyboard descend);
  // otherwise hop to the Windows rail. A branch counts as already-open when its
  // children container is rendered and not collapsed — then Right hops instead
  // of re-toggling, so an expanded row never snaps shut.
  _expandOrHopWindows(row) {
    if (row && this._expandCollapsedBranch(row)) return
    this._focusWindowsRail()
  },

  _expandCollapsedBranch(row) {
    const branch = row.closest?.("[data-picker-tree-branch]")
    if (!branch || !this.el.contains(branch)) return false

    const children = branch.querySelector("[data-picker-branch-children]")
    const open =
      children &&
      !children.hasAttribute("data-picker-collapsed") &&
      !children.classList.contains("hidden")
    if (open) return false

    if (row.getAttribute("data-picker-section") === "workspaces") {
      const wsId = row.getAttribute("phx-value-workspace-id")
      if (wsId) {
        this.pushEvent("sidebar:toggle_workspace", {"workspace-id": wsId})
        return true
      }
    }

    if (row.getAttribute("data-picker-section") === "browse") {
      const rel = row.getAttribute("phx-value-rel")
      if (rel !== null && rel !== undefined) {
        this.pushEvent("sidebar:toggle_browse", {rel})
        return true
      }
    }

    return false
  },

  // Drop focus into the Windows column (Miller-style Right).
  _focusWindowsRail() {
    const rail = document.querySelector("[data-window-picker-sidebar]")
    if (rail) {
      // Prefer the LiveView hook path; also focus immediately so hop is snappy
      // even if the custom event is lost across a patch boundary.
      rail.dispatchEvent(new CustomEvent("casein:window-sidebar:focus"))
      const items = Array.from(rail.querySelectorAll("[data-picker-item]")).filter(
        (el) => el.offsetParent !== null && el.style.display !== "none"
      )
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || items[0])?.focus({preventScroll: false})
      return
    }
    // Windows rail not mounted — open both columns and ask the server to focus it.
    this.pushEvent("sidebar:open", {mode: "both", focus: "windows"})
  },
}

function wantsBrowserNavigation(e) {
  return e.metaKey || e.ctrlKey || (e.shiftKey && e.button === 0)
}