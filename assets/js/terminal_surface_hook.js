let refitScheduled = false

function scheduleTerminalRefit() {
  if (refitScheduled) return
  refitScheduled = true

  requestAnimationFrame(() => {
    refitScheduled = false
    window.dispatchEvent(new Event("resize"))
  })
}

export const TerminalSurface = {
  mounted() {
    this._lastRect = this.el.dataset.paneRect || ""
    this._observer = new ResizeObserver(() => scheduleTerminalRefit())
    this._observer.observe(this.el)
    scheduleTerminalRefit()
  },

  updated() {
    const rect = this.el.dataset.paneRect || ""
    if (rect === this._lastRect) return

    this._lastRect = rect
    scheduleTerminalRefit()
  },

  destroyed() {
    this._observer?.disconnect()
  },
}