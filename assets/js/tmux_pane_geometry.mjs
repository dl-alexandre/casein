// Pure geometry math for the tmux split-pane drag-resize preview.
//
// Extracted from tmux_pane_resize_hook.js so it can be unit-tested with
// `node --test` (assets/test/). Everything here operates on plain data — the
// pane objects may carry an `el` reference, but no function reads the DOM.

export const DEAD_ZONE_PX = 8
export const FALLBACK_CELL_PX = 12

export function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

export function signedCells(deltaPx, cellPx, maxAmount) {
  if (Math.abs(deltaPx) < DEAD_ZONE_PX) return 0

  const cells = Math.round(Math.abs(deltaPx) / Math.max(cellPx, 1))
  return clamp(cells, 1, maxAmount) * Math.sign(deltaPx)
}

export function directionFor(axis, deltaPx) {
  if (axis === "x") return deltaPx >= 0 ? "right" : "left"
  return deltaPx >= 0 ? "down" : "up"
}

export function axisDelta(drag, e) {
  return drag.axis === "x" ? e.clientX - drag.startX : e.clientY - drag.startY
}

export function cellPxFor(drag, rect) {
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

export function neighborForResize(geos, paneId, direction) {
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

export function applyResize(geos, paneId, direction, amount) {
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

export function cloneGeometries(geos) {
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

export function paneStyle(pane, bounds) {
  const pct = (value, total) => (total > 0 ? (value / total) * 100 : 0)

  return {
    left: pct(pane.left, bounds.width),
    top: pct(pane.top, bounds.height),
    width: pct(pane.width, bounds.width),
    height: pct(pane.height, bounds.height),
  }
}

// A drag's base geometry is only meaningful while the layout keeps the same
// shape. Any structural change under the drag (pane added/killed, window
// bounds resized, window switched) invalidates it.
export function sameLayoutStructure(base, bounds, current, currentBounds) {
  if (bounds.width !== currentBounds.width || bounds.height !== currentBounds.height) return false
  if (base.size !== current.size) return false

  for (const id of base.keys()) {
    if (!current.has(id)) return false
  }

  return true
}
