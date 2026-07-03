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

export const WindowTabStrip = {
  mounted() {
    this.scroller = this.el.querySelector("[data-tab-scroller]")
    if (!this.scroller) return
    this.lastActiveId = this.activeTab()?.id
    this.center(false)
    this.updateFades()

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
      this.center(false)
      this.updateFades()
    })
    this.ro.observe(this.scroller)
  },

  updated() {
    if (!this.scroller?.isConnected) {
      this.destroyed()
      this.mounted()
      return
    }
    const activeId = this.activeTab()?.id
    if (activeId && activeId !== this.lastActiveId) {
      this.lastActiveId = activeId
      this.center(true)
    }
    this.updateFades()
  },

  destroyed() {
    this.ro?.disconnect()
    if (this.scroller) {
      this.scroller.removeEventListener("scroll", this.onScroll)
      this.scroller.removeEventListener("wheel", this.onWheel)
    }
  },

  activeTab() {
    return this.scroller?.querySelector("[data-active-window]")
  },

  center(smooth) {
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
