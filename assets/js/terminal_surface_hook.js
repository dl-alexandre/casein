function dispatchTerminalRefit(el, reason) {
  window.dispatchEvent(
    new CustomEvent("devide:terminal-refit", {
      detail: {
        surface_id: el?.id || null,
        pane_id: el?.dataset?.paneId || null,
        rect: el?.dataset?.paneRect || "",
        reason
      }
    })
  )

  // Compatibility shim for any vendor/listener path that still keys off the
  // global resize event. The Ghostty hook now listens to the scoped event above.
  window.dispatchEvent(new Event("resize"))
}

function scheduleTerminalRefit(hook, reason) {
  if (hook._refitScheduled) return
  hook._refitScheduled = true

  hook._refitRaf = requestAnimationFrame(() => {
    hook._refitScheduled = false
    hook._refitRaf = null
    dispatchTerminalRefit(hook.el, reason)
  })
}

export const TerminalSurface = {
  mounted() {
    this._lastRect = this.el.dataset.paneRect || ""
    this._observer = new ResizeObserver(() => scheduleTerminalRefit(this, "resize_observer"))
    this._observer.observe(this.el)
    scheduleTerminalRefit(this, "mounted")
  },

  updated() {
    const rect = this.el.dataset.paneRect || ""
    if (rect === this._lastRect) return

    this._lastRect = rect
    scheduleTerminalRefit(this, "pane_rect_changed")
  },

  destroyed() {
    this._observer?.disconnect()
    if (this._refitRaf != null) cancelAnimationFrame(this._refitRaf)
    this._refitRaf = null
    this._refitScheduled = false
  },
}
