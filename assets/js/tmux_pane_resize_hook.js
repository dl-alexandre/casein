const DEAD_ZONE_PX = 8
const FALLBACK_CELL_PX = 12

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function signedCells(deltaPx, cellPx, maxAmount) {
  if (Math.abs(deltaPx) < DEAD_ZONE_PX) return 0

  const cells = Math.round(Math.abs(deltaPx) / Math.max(cellPx, 1))
  return clamp(cells, 1, maxAmount) * Math.sign(deltaPx)
}

function directionFor(axis, deltaPx) {
  if (axis === "x") return deltaPx >= 0 ? "right" : "left"
  return deltaPx >= 0 ? "down" : "up"
}

function axisDelta(drag, e) {
  return drag.axis === "x" ? e.clientX - drag.startX : e.clientY - drag.startY
}

function cellPxFor(drag, rect) {
  const {bounds, axis} = drag

  if (axis === "x" && bounds.width > 0) return rect.width / bounds.width
  if (axis === "y" && bounds.height > 0) return rect.height / bounds.height
  return FALLBACK_CELL_PX
}

function overlapsY(a, b) {
  return a.top < b.top + b.height && a.top + a.height > b.top
}

function overlapsX(a, b) {
  return a.left < b.left + b.width && a.left + a.width > b.left
}

function neighborForResize(geos, paneId, direction) {
  const pane = geos.get(paneId)
  if (!pane) return null

  for (const [id, other] of geos) {
    if (id === paneId) continue

    if (direction === "right" && overlapsY(pane, other) && other.left === pane.left + pane.width) {
      return id
    }

    if (direction === "left" && overlapsY(pane, other) && other.left + other.width === pane.left) {
      return id
    }

    if (direction === "down" && overlapsX(pane, other) && other.top === pane.top + pane.height) {
      return id
    }

    if (direction === "up" && overlapsX(pane, other) && other.top + other.height === pane.top) {
      return id
    }
  }

  return null
}

function applyResize(geos, paneId, direction, amount) {
  const pane = geos.get(paneId)
  if (!pane || amount === 0) return

  const neighborId = neighborForResize(geos, paneId, direction)
  const neighbor = neighborId ? geos.get(neighborId) : null

  if (direction === "right") {
    pane.width += amount
    if (neighbor) neighbor.width -= amount
  } else if (direction === "left") {
    pane.left -= amount
    pane.width += amount
    if (neighbor) neighbor.width -= amount
  } else if (direction === "down") {
    pane.height += amount
    if (neighbor) neighbor.height -= amount
  } else if (direction === "up") {
    pane.top -= amount
    pane.height += amount
    if (neighbor) neighbor.height -= amount
  }
}

function cloneGeometries(geos) {
  const next = new Map()

  for (const [id, pane] of geos) {
    next.set(id, {
      el: pane.el,
      left: pane.left,
      top: pane.top,
      width: pane.width,
      height: pane.height,
    })
  }

  return next
}

function paneStyle(pane, bounds) {
  const pct = (value, total) => (total > 0 ? (value / total) * 100 : 0)

  return {
    left: pct(pane.left, bounds.width),
    top: pct(pane.top, bounds.height),
    width: pct(pane.width, bounds.width),
    height: pct(pane.height, bounds.height),
  }
}

function renderGeometries(geos, bounds) {
  for (const pane of geos.values()) {
    const style = paneStyle(pane, bounds)
    pane.el.style.left = `${style.left}%`
    pane.el.style.top = `${style.top}%`
    pane.el.style.width = `${style.width}%`
    pane.el.style.height = `${style.height}%`
  }
}

function clearPreview(geos) {
  for (const pane of geos.values()) {
    pane.el.style.left = ""
    pane.el.style.top = ""
    pane.el.style.width = ""
    pane.el.style.height = ""
    pane.el.classList.remove("transition-none")
  }
}

function collectPaneGeometries(layout) {
  const bounds = {
    width: Number.parseFloat(layout.dataset.boundsCols || "0"),
    height: Number.parseFloat(layout.dataset.boundsRows || "0"),
  }

  const geos = new Map()

  for (const el of layout.querySelectorAll("section[data-pane-id]")) {
    geos.set(el.dataset.paneId, {
      el,
      left: Number.parseFloat(el.dataset.paneLeft || "0"),
      top: Number.parseFloat(el.dataset.paneTop || "0"),
      width: Number.parseFloat(el.dataset.paneWidth || "0"),
      height: Number.parseFloat(el.dataset.paneHeight || "0"),
    })
  }

  return {bounds, geos}
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

      const {bounds, geos} = collectPaneGeometries(this.el)
      const rect = this.el.getBoundingClientRect()

      for (const pane of geos.values()) {
        pane.el.classList.add("transition-none")
      }

      this.el.dataset.layoutResizing = "true"

      this._drag = {
        pointerId: e.pointerId,
        handle,
        paneId,
        axis,
        startX: e.clientX,
        startY: e.clientY,
        bounds,
        baseGeometries: geos,
        layoutRect: rect,
        cellPx: cellPxFor({bounds, axis}, rect),
        maxAmount: Number.parseInt(this.el.dataset.resizeMax || "50", 10),
        committedCells: 0,
        inFlight: false,
        finishQueued: false,
        raf: null,
        latestEvent: null,
      }

      handle.setPointerCapture?.(e.pointerId)
      handle.dataset.dragging = "true"
    }

    this._onPointerMove = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      e.preventDefault()
      drag.latestEvent = e

      if (!drag.raf) {
        drag.raf = requestAnimationFrame(() => this._onDragFrame())
      }
    }

    this._onDragFrame = () => {
      const drag = this._drag
      if (!drag) return

      drag.raf = null
      const e = drag.latestEvent
      if (!e) return

      const deltaPx = axisDelta(drag, e)
      const previewGeos = cloneGeometries(drag.baseGeometries)

      if (Math.abs(deltaPx) >= DEAD_ZONE_PX) {
        const magnitude = Math.abs(deltaPx) / Math.max(drag.cellPx, 1)
        const direction = directionFor(drag.axis, deltaPx)
        applyResize(previewGeos, drag.paneId, direction, magnitude)
      }

      renderGeometries(previewGeos, drag.bounds)

      this._maybeCommitResize(drag, deltaPx)
    }

    this._onPointerUp = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      drag.handle.releasePointerCapture?.(e.pointerId)
      delete drag.handle.dataset.dragging

      e.preventDefault()
      e.stopPropagation()

      const deltaPx = axisDelta(drag, e)
      this._maybeCommitResize(drag, deltaPx)
      this._finishDrag(drag, deltaPx)

      this._drag = null
    }

    this._onPointerCancel = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      drag.handle.releasePointerCapture?.(e.pointerId)
      delete drag.handle.dataset.dragging
      this._cancelDrag(drag)
      this._drag = null
    }

    this._onClick = (e) => {
      if (!e.target.closest("[data-tmux-resize-handle]")) return
      e.preventDefault()
      e.stopPropagation()
    }

    this.el.addEventListener("pointerdown", this._onPointerDown, true)
    this.el.addEventListener("pointermove", this._onPointerMove, true)
    this.el.addEventListener("pointerup", this._onPointerUp, true)
    this.el.addEventListener("pointercancel", this._onPointerCancel, true)
    this.el.addEventListener("click", this._onClick, true)
  },

  _maybeCommitResize(drag, deltaPx) {
    const totalCells = signedCells(deltaPx, drag.cellPx, drag.maxAmount)
    const pending = totalCells - drag.committedCells
    if (pending === 0 || drag.inFlight) return

    const direction = directionFor(drag.axis, pending)
    const amount = Math.abs(pending)

    drag.inFlight = true

    this.pushEvent(
      "tmux:resize_pane_step",
      {
        "pane-id": drag.paneId,
        direction,
        amount: String(amount),
      },
      (reply) => {
        drag.inFlight = false

        if (reply?.ok) {
          drag.committedCells = totalCells
        }

        if (drag.finishQueued) {
          this.pushEvent("tmux:resize_pane_finish", {})
          this._cleanupDrag(drag)
        }
      },
    )
  },

  _finishDrag(drag, deltaPx) {
    const moved = Math.abs(deltaPx) >= DEAD_ZONE_PX

    if (drag.inFlight) {
      drag.finishQueued = true
      return
    }

    if (moved || drag.committedCells !== 0) {
      this.pushEvent("tmux:resize_pane_finish", {})
    }

    this._cleanupDrag(drag)
  },

  _cancelDrag(drag) {
    if (drag.committedCells !== 0) {
      this.pushEvent("tmux:resize_pane_finish", {})
    }

    this._cleanupDrag(drag)
  },

  _cleanupDrag(drag) {
    if (drag?.raf) {
      cancelAnimationFrame(drag.raf)
    }

    delete this.el.dataset.layoutResizing
    clearPreview(drag.baseGeometries)
  },

  destroyed() {
    if (this._drag) {
      this._cancelDrag(this._drag)
      this._drag = null
    }

    this.el.removeEventListener("pointerdown", this._onPointerDown, true)
    this.el.removeEventListener("pointermove", this._onPointerMove, true)
    this.el.removeEventListener("pointerup", this._onPointerUp, true)
    this.el.removeEventListener("pointercancel", this._onPointerCancel, true)
    this.el.removeEventListener("click", this._onClick, true)
  },
}