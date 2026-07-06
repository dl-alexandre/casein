// Keep preview/file pane overlays aligned with tmux pane sections.
//
// Preview overlays use phx-update="ignore" so LiveView never patches their
// data-pane-rect; during a drag-resize only the section elements' inline
// geometry changes until resize_pane_finish. Reading the section's live
// style keeps overlays glued to the pane tile in both cases.

export function parsePaneRectJson(raw) {
  if (!raw) return null

  try {
    const rect = JSON.parse(raw)
    if (
      typeof rect.left === "number" &&
      typeof rect.top === "number" &&
      typeof rect.width === "number" &&
      typeof rect.height === "number"
    ) {
      return rect
    }
  } catch (_) {
    return null
  }

  return null
}

export function rectFromSectionElement(section) {
  if (!section) return null

  const left = Number.parseFloat(section.style.left)
  const top = Number.parseFloat(section.style.top)
  const width = Number.parseFloat(section.style.width)
  const height = Number.parseFloat(section.style.height)

  if ([left, top, width, height].some((value) => Number.isNaN(value))) return null

  return {left, top, width, height}
}

export function paneSectionForOverlay(overlayEl) {
  const paneId = overlayEl?.dataset?.paneId
  const layout = overlayEl?.parentElement
  if (!paneId || !layout) return null

  const escaped =
    typeof CSS !== "undefined" && typeof CSS.escape === "function"
      ? CSS.escape(paneId)
      : paneId.replace(/\\/g, "\\\\").replace(/"/g, '\\"')

  return layout.querySelector(`section[data-pane-id="${escaped}"]`)
}

export function resolveOverlayRect(overlayEl) {
  return (
    rectFromSectionElement(paneSectionForOverlay(overlayEl)) ||
    parsePaneRectJson(overlayEl?.dataset?.paneRect)
  )
}

export function applyOverlayRect(el, rect, opts = {}) {
  if (!rect || !el) return

  const {zIndex = "25", enteredZIndex = "40", entered = false} = opts

  Object.assign(el.style, {
    position: "absolute",
    left: `${rect.left}%`,
    top: `${rect.top}%`,
    width: `${rect.width}%`,
    height: `${rect.height}%`,
    zIndex: entered ? enteredZIndex : zIndex,
    pointerEvents: "auto",
    contain: "layout",
  })
}

export function bindPaneSectionGeometryObserver(overlayEl, onChange) {
  const section = paneSectionForOverlay(overlayEl)
  if (!section || typeof MutationObserver === "undefined") {
    return {disconnect() {}}
  }

  const observer = new MutationObserver(() => onChange())
  observer.observe(section, {attributes: true, attributeFilter: ["style"]})

  return observer
}