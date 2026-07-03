import {
  DEAD_ZONE_PX,
  applyResize,
  axisDelta,
  cellPxFor,
  cloneGeometries,
  directionFor,
  paneStyle,
  sameLayoutStructure,
  signedCells,
} from "./tmux_pane_geometry.mjs"

function renderGeometries(geos, bounds) {
  for (const pane of geos.values()) {
    const style = paneStyle(pane, bounds)
    pane.el.style.left = `${style.left}%`
    pane.el.style.top = `${style.top}%`
    pane.el.style.width = `${style.width}%`
    pane.el.style.height = `${style.height}%`
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
      // One drag at a time, primary button/touch only — a second pointer or a
      // right-click on a handle must not hijack an in-flight drag.
      if (this._drag || e.button !== 0) return

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
        ended: false,
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
      if (!drag || drag.ended) return

      drag.raf = null
      if (!drag.latestEvent) return

      const deltaPx = this._renderPreviewFrame(drag)
      this._maybeCommitResize(drag, deltaPx)
    }

    this._onPointerUp = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      this._releaseDragPointer(drag)

      e.preventDefault()
      e.stopPropagation()

      const deltaPx = axisDelta(drag, e)
      this._maybeCommitResize(drag, deltaPx)

      if (drag.inFlight) {
        drag.finishQueued = true
      } else {
        const moved = Math.abs(deltaPx) >= DEAD_ZONE_PX
        if (moved || drag.committedCells !== 0) {
          this.pushEvent("tmux:resize_pane_finish", {})
        }
        this._endDrag(drag)
      }

      this._drag = null
    }

    this._onPointerCancel = (e) => {
      const drag = this._drag
      if (!drag || drag.pointerId !== e.pointerId) return

      this._releaseDragPointer(drag)

      if (drag.inFlight) {
        drag.finishQueued = true
      } else {
        if (drag.committedCells !== 0) {
          this.pushEvent("tmux:resize_pane_finish", {})
        }
        this._endDrag(drag)
      }

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

  // A LiveView patch re-rendered the layout mid-drag (topology broadcasts:
  // our own committed steps echoing back through the shared watcher, other
  // viewers, agents, activity polls). The patch rewrote every section's style
  // attribute with server geometry, which would snap the layout out from
  // under the drag until the next pointermove — re-apply the in-flight
  // preview in the same task so the user never sees the snap. If the layout
  // changed shape (pane added/killed, window resized or switched), the drag's
  // base geometry is meaningless: end the drag and let server truth stand.
  updated() {
    const drag = this._drag
    if (!drag || drag.ended) return

    const {bounds, geos} = collectPaneGeometries(this.el)

    if (!sameLayoutStructure(drag.baseGeometries, drag.bounds, geos, bounds)) {
      this._releaseDragPointer(drag)

      if (drag.inFlight) {
        drag.finishQueued = true
      } else {
        if (drag.committedCells !== 0) {
          this.pushEvent("tmux:resize_pane_finish", {})
        }
        this._endDrag(drag, {restore: false})
      }

      this._drag = null
      return
    }

    for (const [id, pane] of geos) {
      const base = drag.baseGeometries.get(id)
      base.el = pane.el
      pane.el.classList.add("transition-none")
    }

    this._renderPreviewFrame(drag)
  },

  _renderPreviewFrame(drag) {
    const deltaPx = drag.latestEvent ? axisDelta(drag, drag.latestEvent) : 0
    const previewGeos = cloneGeometries(drag.baseGeometries)

    if (Math.abs(deltaPx) >= DEAD_ZONE_PX) {
      const magnitude = Math.abs(deltaPx) / Math.max(drag.cellPx, 1)
      const direction = directionFor(drag.axis, deltaPx)
      applyResize(previewGeos, drag.paneId, direction, magnitude)
    }

    renderGeometries(previewGeos, drag.bounds)
    return deltaPx
  },

  _maybeCommitResize(drag, deltaPx) {
    if (drag.ended) return

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

        if (!reply?.ok) {
          // The step was rejected (mutations disabled, pane gone). Leaving the
          // drag live would re-push the same denied step on every frame —
          // end it and reconcile with the server instead.
          const active = this._drag === drag
          if (active) this._releaseDragPointer(drag)

          if (drag.finishQueued || drag.committedCells !== 0) {
            this.pushEvent("tmux:resize_pane_finish", {})
          }

          this._endDrag(drag)
          if (active) this._drag = null
          return
        }

        drag.committedCells = totalCells

        if (drag.finishQueued) {
          this.pushEvent("tmux:resize_pane_finish", {})
          this._endDrag(drag)
        }
      },
    )
  },

  _releaseDragPointer(drag) {
    drag.handle.releasePointerCapture?.(drag.pointerId)
    delete drag.handle.dataset.dragging
  },

  // Single exit point for a drag. `restore` defaults to restoring the base
  // (pre-drag) geometry only when no step was committed: in that case tmux is
  // unchanged and no topology patch will arrive to fix the preview. When steps
  // were committed, the inline preview styles are left in place — the
  // resize_pane_finish topology refresh rewrites each section's style with
  // server truth. Clearing the inline styles here (the old behavior) also
  // erased the server-rendered geometry living in the same style attribute,
  // collapsing the panes until that patch landed.
  _endDrag(drag, opts = {}) {
    if (drag.ended) return
    drag.ended = true

    if (drag.raf) {
      cancelAnimationFrame(drag.raf)
      drag.raf = null
    }

    delete this.el.dataset.layoutResizing

    for (const pane of drag.baseGeometries.values()) {
      pane.el.classList.remove("transition-none")
    }

    const restore = opts.restore ?? drag.committedCells === 0
    if (restore) renderGeometries(drag.baseGeometries, drag.bounds)
  },

  destroyed() {
    if (this._drag) {
      this._releaseDragPointer(this._drag)
      this._endDrag(this._drag, {restore: false})
      this._drag = null
    }

    this.el.removeEventListener("pointerdown", this._onPointerDown, true)
    this.el.removeEventListener("pointermove", this._onPointerMove, true)
    this.el.removeEventListener("pointerup", this._onPointerUp, true)
    this.el.removeEventListener("pointercancel", this._onPointerCancel, true)
    this.el.removeEventListener("click", this._onClick, true)
  },
}
