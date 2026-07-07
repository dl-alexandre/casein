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

const INSERTION_CLASS =
  "outline outline-2 outline-primary -outline-offset-2"

export const WindowTabStrip = {
  mounted() {
    this.scroller = this.el.querySelector("[data-tab-scroller]")
    if (!this.scroller) return
    this.lastActiveId = this.activeTab()?.id
    this.dragging = false
    this.draggedId = null
    this.dropTarget = null
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
    this.clearInsertionIndicator()
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
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", windowId)
    }

    this.onDragOver = (e) => {
      if (!this.dragging) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      this.showInsertionIndicator(this.insertionNeighbor(e.clientX))
    }

    this.onDrop = (e) => {
      if (!this.dragging) return
      e.preventDefault()

      const neighbor = this.insertionNeighbor(e.clientX)
      if (neighbor && neighbor.id !== this.draggedId) {
        const payload = {
          "window-id": this.draggedId,
          "before-window-id": neighbor.id,
        }
        if (neighbor.placement === "after") payload.dir = "after"
        this.pushEvent("tmux:move_window", payload)
      }

      this.clearDragState()
    }

    this.onDragEnd = () => this.clearDragState()

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

  insertionNeighbor(clientX) {
    const tabs = this.tabNodes().filter(
      (tab) => tab.dataset.ctxWindowId && tab.dataset.ctxWindowId !== this.draggedId,
    )

    for (const tab of tabs) {
      const rect = tab.getBoundingClientRect()
      const mid = rect.left + rect.width / 2
      if (clientX < mid) {
        return {id: tab.dataset.ctxWindowId, placement: "before", tab}
      }
    }

    const last = tabs[tabs.length - 1]
    return last
      ? {id: last.dataset.ctxWindowId, placement: "after", tab: last}
      : null
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
    neighbor?.tab?.classList.add(...INSERTION_CLASS.split(" "))
  },

  clearInsertionIndicator() {
    if (this.dropTarget?.tab) {
      this.dropTarget.tab.classList.remove(...INSERTION_CLASS.split(" "))
    }
    this.dropTarget = null
  },

  clearDragState() {
    this.dragging = false
    this.draggedId = null
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
