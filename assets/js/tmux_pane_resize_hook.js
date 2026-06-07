const DEAD_ZONE_PX = 8
const FALLBACK_CELL_PX = 12

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function resizeAmount(deltaPx, cellPx, maxAmount) {
  const cells = Math.round(Math.abs(deltaPx) / Math.max(cellPx, 1))
  return clamp(cells, 1, maxAmount)
}

function directionFor(axis, deltaPx) {
  if (axis === "x") return deltaPx >= 0 ? "right" : "left"
  return deltaPx >= 0 ? "down" : "up"
}

export const TmuxPaneResize = {
  mounted() {
    this._drag = null

    this._onPointerDown = (e) => {
      const handle = e.target.closest("[data-tmux-resize-handle]")
      if (!handle || !this.el.contains(handle)) return

      e.preventDefault()
      e.stopPropagation()

      const paneId = handle.dataset.paneId
      const axis = handle.dataset.resizeAxis
      if (!paneId || !["x", "y"].includes(axis)) return

      this._drag = {
        pointerId: e.pointerId,
        handle,
        paneId,
        axis,
        startX: e.clientX,
        startY: e.clientY,
      }

      handle.setPointerCapture?.(e.pointerId)
      handle.dataset.dragging = "true"
    }

    this._onPointerUp = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      drag.handle.releasePointerCapture?.(e.pointerId)
      delete drag.handle.dataset.dragging

      this._drag = null
      e.preventDefault()
      e.stopPropagation()

      const deltaX = e.clientX - drag.startX
      const deltaY = e.clientY - drag.startY
      const delta = drag.axis === "x" ? deltaX : deltaY
      if (Math.abs(delta) < DEAD_ZONE_PX) return

      const rect = this.el.getBoundingClientRect()
      const boundsCols = Number.parseFloat(this.el.dataset.boundsCols || "0")
      const boundsRows = Number.parseFloat(this.el.dataset.boundsRows || "0")
      const maxAmount = Number.parseInt(this.el.dataset.resizeMax || "50", 10)
      const cellPx =
        drag.axis === "x" && boundsCols > 0
          ? rect.width / boundsCols
          : drag.axis === "y" && boundsRows > 0
            ? rect.height / boundsRows
            : FALLBACK_CELL_PX

      this.pushEvent("tmux:resize_pane", {
        "pane-id": drag.paneId,
        direction: directionFor(drag.axis, delta),
        amount: resizeAmount(delta, cellPx, maxAmount),
      })
    }

    this._onPointerCancel = (e) => {
      if (!this._drag || this._drag.pointerId !== e.pointerId) return
      this._drag.handle.releasePointerCapture?.(e.pointerId)
      delete this._drag.handle.dataset.dragging
      this._drag = null
    }

    this._onClick = (e) => {
      if (!e.target.closest("[data-tmux-resize-handle]")) return
      e.preventDefault()
      e.stopPropagation()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown, true)
    this.el.addEventListener("pointerup", this._onPointerUp, true)
    this.el.addEventListener("pointercancel", this._onPointerCancel, true)
    this.el.addEventListener("click", this._onClick, true)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown, true)
    this.el.removeEventListener("pointerup", this._onPointerUp, true)
    this.el.removeEventListener("pointercancel", this._onPointerCancel, true)
    this.el.removeEventListener("click", this._onClick, true)
  },
}
