// WindowTabStrip hook
//
// Keeps the window-tab strip usable when it overflows: the strip clips and
// scrolls (never spills over neighboring header controls), the active tab is
// auto-scrolled to the center of the viewport — which naturally pins it left
// when it is the first tab and right when it is the last, since the scroll
// offset is clamped to the scrollable range — and `data-clipped-left/right`
// attributes drive the CSS edge-fade masks that signal off-screen tabs.
//
// Re-centering happens only when the *active tab* changes (or on resize), not
// on every LiveView patch, so a user browsing the strip isn't yanked back.
// `data-version` on the hook element is the tmux topology structure version,
// which changes on window selection, so `updated()` fires on every switch.
//
// Desktop drag-and-drop reorders tabs via `tmux:move_window` (tmux move-window).

import {
  insertionNeighbor,
  movePayload,
  previewTabMove,
  restoreTabOrder,
} from "./window_tab_reorder.mjs"

const EDGE_SCROLL_ZONE = 44
const MAX_EDGE_SCROLL_SPEED = 14
const REORDER_ANIMATION_MS = 140

export const WindowTabStrip = {
  mounted() {
    this.scroller = this.el.querySelector("[data-tab-scroller]")
    if (!this.scroller) return
    this.lastActiveId = this.activeTab()?.id
    this.dragging = false
    this.draggedId = null
    this.draggedTab = null
    this.dropTarget = null
    this.originalOrder = null
    this.dropCommitted = false
    this.center(false)
    this.updateFades()
    this.bindScrollerEvents()
    this.bindDragDrop()
  },

  updated() {
    if (!this.scroller?.isConnected) {
      this.destroyed()
      this.mounted()
      return
    }

    if (this.dragging) {
      this.updateFades()
      return
    }

    const activeId = this.activeTab()?.id
    if (activeId && activeId !== this.lastActiveId) {
      this.lastActiveId = activeId
      this.center(true)
    }
    this.updateFades()
    this.bindDragDrop()
  },

  destroyed() {
    this.ro?.disconnect()
    if (this.scroller) {
      this.scroller.removeEventListener("scroll", this.onScroll)
      this.scroller.removeEventListener("wheel", this.onWheel)
      this.scroller.removeEventListener("dragover", this.onDragOver)
      this.scroller.removeEventListener("drop", this.onDrop)
      this.scroller.removeEventListener("dragend", this.onDragEnd)
    }
    this.clearDragState()
    this.unbindTabDrag()
  },

  bindScrollerEvents() {
    this.onScroll = () => this.updateFades()
    this.scroller.addEventListener("scroll", this.onScroll, {passive: true})

    // Non-passive on purpose: preventDefault only when the strip can actually
    // consume the wheel delta, so page/pane scrolling is untouched otherwise.
    this.onWheel = (e) => {
      const delta = e.deltaX !== 0 ? e.deltaX : e.deltaY
      if (delta === 0) return
      const s = this.scroller
      const max = s.scrollWidth - s.clientWidth
      if (max <= 0) return
      const consumable = delta < 0 ? s.scrollLeft > 0 : s.scrollLeft < max
      if (!consumable) return
      e.preventDefault()
      s.scrollLeft += delta
    }
    this.scroller.addEventListener("wheel", this.onWheel, {passive: false})

    this.ro = new ResizeObserver(() => {
      if (this.dragging) return
      this.center(false)
      this.updateFades()
    })
    this.ro.observe(this.scroller)
  },

  bindDragDrop() {
    this.unbindTabDrag()
    if (!this.dragDropEnabled()) return

    this.onDragStart = (e) => {
      const tab = e.currentTarget
      const windowId = tab.dataset.ctxWindowId
      if (!windowId) return

      this.dragging = true
      this.draggedId = windowId
      this.draggedTab = tab
      this.originalOrder = this.tabNodes().map(
        (node) => node.dataset.ctxWindowId,
      )
      this.dropCommitted = false
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", windowId)

      // Defer styling until the browser has captured its native drag image.
      requestAnimationFrame(() => {
        if (!this.dragging) return
        tab.setAttribute("data-tab-reordering", "")
        this.scroller.setAttribute("data-reordering", "")
      })
    }

    this.onDragOver = (e) => {
      if (!this.dragging) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      this.lastDragClientX = e.clientX
      const neighbor = this.insertionNeighbor(e.clientX)
      this.previewInsertion(neighbor)
      this.startEdgeScroll()
    }

    this.onDrop = (e) => {
      if (!this.dragging) return
      e.preventDefault()

      const neighbor = this.insertionNeighbor(e.clientX)
      this.previewInsertion(neighbor)
      const payload = movePayload(this.draggedId, neighbor)
      if (payload && this.orderChanged()) {
        this.dropCommitted = true
        this.pushEvent("tmux:move_window", payload)
      }

      this.clearDragState({restore: !this.dropCommitted})
    }

    this.onDragEnd = () => {
      if (this.dragging) this.clearDragState({restore: !this.dropCommitted})
    }

    this.scroller.addEventListener("dragover", this.onDragOver)
    this.scroller.addEventListener("drop", this.onDrop)
    this.scroller.addEventListener("dragend", this.onDragEnd)

    this.tabNodes().forEach((tab) => {
      tab.draggable = true
      tab.addEventListener("dragstart", this.onDragStart)
    })
  },

  unbindTabDrag() {
    if (!this.scroller) return
    this.tabNodes().forEach((tab) => {
      tab.draggable = false
      if (this.onDragStart) tab.removeEventListener("dragstart", this.onDragStart)
    })
  },

  dragDropEnabled() {
    return (
      this.el.dataset.mutationsAllowed === "true" &&
      window.matchMedia("(hover: hover) and (pointer: fine)").matches
    )
  },

  tabNodes() {
    return [...this.scroller.querySelectorAll('[id^="tmux-window-"]')]
  },

  orderChanged() {
    const current = this.tabNodes().map((tab) => tab.dataset.ctxWindowId)
    return current.some((id, index) => id !== this.originalOrder?.[index])
  },

  insertionNeighbor(clientX) {
    return insertionNeighbor(this.tabNodes(), this.draggedId, clientX)
  },

  previewInsertion(neighbor) {
    if (
      this.dropTarget?.tab === neighbor?.tab &&
      this.dropTarget?.placement === neighbor?.placement
    ) {
      return
    }

    const beforeRects = new Map(
      this.tabNodes().map((tab) => [tab, tab.getBoundingClientRect()]),
    )
    const moved = previewTabMove(this.draggedTab, neighbor)
    this.showInsertionIndicator(neighbor)
    if (moved) this.animateReorder(beforeRects)
  },

  animateReorder(beforeRects) {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    for (const tab of this.tabNodes()) {
      if (tab === this.draggedTab) continue
      const before = beforeRects.get(tab)
      const after = tab.getBoundingClientRect()
      const deltaX = before ? before.left - after.left : 0
      if (Math.abs(deltaX) < 1 || typeof tab.animate !== "function") continue

      tab.getAnimations?.().forEach((animation) => {
        if (animation.id === "window-tab-reorder") animation.cancel()
      })
      const animation = tab.animate(
        [
          {transform: `translateX(${deltaX}px)`},
          {transform: "translateX(0)"},
        ],
        {
          duration: REORDER_ANIMATION_MS,
          easing: "cubic-bezier(0.2, 0.8, 0.2, 1)",
        },
      )
      animation.id = "window-tab-reorder"
    }
  },

  showInsertionIndicator(neighbor) {
    if (
      this.dropTarget?.tab === neighbor?.tab &&
      this.dropTarget?.placement === neighbor?.placement
    ) {
      return
    }

    this.clearInsertionIndicator()
    this.dropTarget = neighbor
    neighbor?.tab?.setAttribute(
      neighbor.placement === "after"
        ? "data-tab-drop-after"
        : "data-tab-drop-before",
      "",
    )
  },

  clearInsertionIndicator() {
    if (this.dropTarget?.tab) {
      this.dropTarget.tab.removeAttribute("data-tab-drop-before")
      this.dropTarget.tab.removeAttribute("data-tab-drop-after")
    }
    this.dropTarget = null
  },

  startEdgeScroll() {
    if (this.edgeScrollFrame) return

    const tick = () => {
      this.edgeScrollFrame = null
      if (!this.dragging) return

      const rect = this.scroller.getBoundingClientRect()
      const x = this.lastDragClientX
      let speed = 0
      if (x < rect.left + EDGE_SCROLL_ZONE) {
        speed =
          -MAX_EDGE_SCROLL_SPEED *
          Math.min(1, (rect.left + EDGE_SCROLL_ZONE - x) / EDGE_SCROLL_ZONE)
      } else if (x > rect.right - EDGE_SCROLL_ZONE) {
        speed =
          MAX_EDGE_SCROLL_SPEED *
          Math.min(1, (x - (rect.right - EDGE_SCROLL_ZONE)) / EDGE_SCROLL_ZONE)
      }

      if (speed !== 0) {
        const previous = this.scroller.scrollLeft
        this.scroller.scrollLeft += speed
        if (this.scroller.scrollLeft !== previous) {
          this.previewInsertion(this.insertionNeighbor(x))
          this.updateFades()
          this.edgeScrollFrame = requestAnimationFrame(tick)
        }
      }
    }

    this.edgeScrollFrame = requestAnimationFrame(tick)
  },

  stopEdgeScroll() {
    if (this.edgeScrollFrame) cancelAnimationFrame(this.edgeScrollFrame)
    this.edgeScrollFrame = null
  },

  clearDragState({restore = false} = {}) {
    this.stopEdgeScroll()
    if (restore) restoreTabOrder(this.scroller, this.originalOrder)
    this.draggedTab?.removeAttribute("data-tab-reordering")
    this.scroller?.removeAttribute("data-reordering")
    this.dragging = false
    this.draggedId = null
    this.draggedTab = null
    this.originalOrder = null
    this.dropCommitted = false
    this.lastDragClientX = null
    this.clearInsertionIndicator()
  },

  activeTab() {
    return this.scroller?.querySelector("[data-active-window]")
  },

  center(smooth) {
    if (this.dragging) return
    const s = this.scroller
    const tab = this.activeTab()
    if (!s || !tab) return
    const max = s.scrollWidth - s.clientWidth
    if (max <= 0) return
    const target = tab.offsetLeft - (s.clientWidth - tab.offsetWidth) / 2
    const left = Math.max(0, Math.min(target, max))
    // Instant when a smooth scroll is still in flight (rapid C-b n cycling),
    // so successive switches don't queue up laggy animations.
    const behavior = smooth && !this.scrolling ? "smooth" : "instant"
    if (smooth) {
      this.scrolling = true
      clearTimeout(this.scrollTimer)
      this.scrollTimer = setTimeout(() => (this.scrolling = false), 300)
    }
    s.scrollTo({left, behavior})
  },

  updateFades() {
    const s = this.scroller
    if (!s) return
    const max = s.scrollWidth - s.clientWidth
    s.toggleAttribute("data-clipped-left", max > 0 && s.scrollLeft > 1)
    s.toggleAttribute("data-clipped-right", max > 0 && s.scrollLeft < max - 1)
  },
}
