// Renderer-aware frozen-frame capture for tmux pane transitions.
//
// Casein currently paints one full-window Ghostty surface beneath the tmux
// pane sections. Each frozen pane is therefore a clipping wrapper containing
// a copy of that full surface offset back to the pane's original rectangle.
// Canvas pixels are copied explicitly (cloneNode does not copy a canvas bitmap);
// the default DOM renderer is cloned after interactive nodes and hook metadata
// are stripped.

function finiteNumber(value, fallback = 0) {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

export function readLayoutProjection(layout) {
  const bounds = {
    width: finiteNumber(layout?.dataset?.boundsCols, 1),
    height: finiteNumber(layout?.dataset?.boundsRows, 1),
  }

  const panes = Array.from(layout?.querySelectorAll?.("section[data-pane-id]") || []).map(
    (el) => ({
      id: el.dataset.paneId,
      left: finiteNumber(el.dataset.paneLeft),
      top: finiteNumber(el.dataset.paneTop),
      width: finiteNumber(el.dataset.paneWidth),
      height: finiteNumber(el.dataset.paneHeight),
    }),
  )

  return {
    version: finiteNumber(layout?.dataset?.layoutVersion),
    topologyVersion: finiteNumber(layout?.dataset?.topologyVersion),
    zoomed: layout?.dataset?.windowZoomed === "true",
    activePaneId: layout?.dataset?.activePaneId || null,
    bounds,
    panes,
  }
}

export function paneRectToPixels(pane, bounds, layoutRect) {
  const width = Math.max(finiteNumber(bounds?.width, 1), 1)
  const height = Math.max(finiteNumber(bounds?.height, 1), 1)

  return {
    left: (finiteNumber(pane?.left) / width) * finiteNumber(layoutRect?.width),
    top: (finiteNumber(pane?.top) / height) * finiteNumber(layoutRect?.height),
    width: (finiteNumber(pane?.width) / width) * finiteNumber(layoutRect?.width),
    height: (finiteNumber(pane?.height) / height) * finiteNumber(layoutRect?.height),
  }
}

export function captureLayoutFrame(layout, projection) {
  if (!layout || !projection) return null

  const doc = layout.ownerDocument || globalThis.document
  if (!doc?.body || typeof doc.createElement !== "function") return null

  const layoutRect = layout.getBoundingClientRect()
  const terminal = layout.querySelector("[data-terminal-surface-mount] [phx-hook='GhosttyTerminal']")
  const surfaceRect = terminal?.getBoundingClientRect?.() || layoutRect
  const priorInert = layout.inert === true
  const priorFocus = doc.activeElement && layout.contains?.(doc.activeElement) ? doc.activeElement : null

  layout.inert = true
  layout.dataset.transitioning = "true"

  const root = doc.createElement("div")
  root.dataset.tmuxTransitionOverlay = "true"
  root.setAttribute("aria-hidden", "true")

  Object.assign(root.style, {
    position: "fixed",
    left: `${layoutRect.left}px`,
    top: `${layoutRect.top}px`,
    width: `${layoutRect.width}px`,
    height: `${layoutRect.height}px`,
    overflow: "hidden",
    pointerEvents: "auto",
    zIndex: "80",
    contain: "layout paint",
    // The frozen pane wrappers provide their own opaque backing. Keeping the
    // shield transparent lets the confirmed live layout appear as those
    // wrappers move and fade away.
    background: "transparent",
  })

  const panes = new Map()

  for (const pane of projection.panes || []) {
    const rect = paneRectToPixels(pane, projection.bounds, layoutRect)
    if (!(rect.width > 0) || !(rect.height > 0)) continue

    const wrapper = doc.createElement("div")
    wrapper.dataset.frozenPaneId = pane.id
    Object.assign(wrapper.style, {
      position: "absolute",
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      overflow: "hidden",
      pointerEvents: "none",
      background: computedBackground(layout),
      border: "1px solid rgb(24 24 27 / 0.45)",
      boxSizing: "border-box",
    })

    // Keep the original pane-sized slice fixed inside the animated wrapper.
    // Expanding the wrapper therefore reveals its background, not neighboring
    // panes from the old full-window terminal frame.
    const slice = doc.createElement("div")
    Object.assign(slice.style, {
      position: "absolute",
      left: "0",
      top: "0",
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      overflow: "hidden",
      pointerEvents: "none",
    })

    if (terminal) {
      const visual = cloneTerminalVisual(terminal)
      if (visual) {
        Object.assign(visual.style, {
          position: "absolute",
          left: `${surfaceRect.left - layoutRect.left - rect.left}px`,
          top: `${surfaceRect.top - layoutRect.top - rect.top}px`,
          width: `${surfaceRect.width}px`,
          height: `${surfaceRect.height}px`,
          maxWidth: "none",
          maxHeight: "none",
          pointerEvents: "none",
        })
        slice.appendChild(visual)
      }
    }

    wrapper.appendChild(slice)
    root.appendChild(wrapper)
    panes.set(pane.id, {el: wrapper, slice, rect})
  }

  doc.body.appendChild(root)

  return {
    root,
    panes,
    layout,
    layoutRect,
    priorInert,
    priorFocus,
  }
}

export function cleanupCapturedLayoutFrame(frozen) {
  if (!frozen) return

  frozen.root?.remove?.()

  if (frozen.layout) {
    frozen.layout.inert = frozen.priorInert
    delete frozen.layout.dataset.transitioning
  }

  if (frozen.priorFocus?.isConnected && typeof frozen.priorFocus.focus === "function") {
    try {
      frozen.priorFocus.focus({preventScroll: true})
    } catch (_) {
      // Focus restoration is best effort; the confirmed layout may have
      // replaced the old input while the frozen frame was visible.
    }
  }
}

function cloneTerminalVisual(terminal) {
  const clone = terminal.cloneNode(true)
  sanitizeFrozenClone(clone)

  const originalCanvases = Array.from(terminal.querySelectorAll?.("canvas") || [])
  const clonedCanvases = Array.from(clone.querySelectorAll?.("canvas") || [])

  for (let index = 0; index < originalCanvases.length; index += 1) {
    copyCanvasBitmap(originalCanvases[index], clonedCanvases[index])
  }

  return clone
}

function sanitizeFrozenClone(clone) {
  const all = [clone, ...Array.from(clone.querySelectorAll?.("*") || [])]

  for (const el of all) {
    el.removeAttribute?.("id")
    el.removeAttribute?.("phx-hook")
    el.removeAttribute?.("phx-target")
    el.removeAttribute?.("phx-update")
    el.removeAttribute?.("autofocus")
    el.setAttribute?.("tabindex", "-1")
  }

  for (const interactive of clone.querySelectorAll?.(
    "textarea, input, button, select, iframe, [contenteditable='true']",
  ) || []) {
    interactive.remove()
  }
}

function copyCanvasBitmap(source, target) {
  if (!source || !target) return

  target.width = source.width
  target.height = source.height

  try {
    const context = target.getContext("2d")
    if (context) context.drawImage(source, 0, 0)
  } catch (_) {
    // A canvas can be unreadable after drawing cross-origin content. The DOM
    // layers and opaque background remain a safe visual fallback.
  }
}

function computedBackground(element) {
  try {
    return element.ownerDocument?.defaultView?.getComputedStyle(element)?.backgroundColor || "#09090b"
  } catch (_) {
    return "#09090b"
  }
}
