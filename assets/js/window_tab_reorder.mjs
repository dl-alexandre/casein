export function insertionNeighbor(tabs, draggedId, clientX) {
  const candidates = tabs.filter(
    (tab) => tab.dataset.ctxWindowId && tab.dataset.ctxWindowId !== draggedId,
  )

  for (const tab of candidates) {
    const rect = tab.getBoundingClientRect()
    if (clientX < rect.left + rect.width / 2) {
      return {id: tab.dataset.ctxWindowId, placement: "before", tab}
    }
  }

  const last = candidates[candidates.length - 1]
  return last
    ? {id: last.dataset.ctxWindowId, placement: "after", tab: last}
    : null
}

export function movePayload(draggedId, neighbor) {
  if (!draggedId || !neighbor || neighbor.id === draggedId) return null

  const payload = {
    "window-id": draggedId,
    "before-window-id": neighbor.id,
  }

  if (neighbor.placement === "after") payload.dir = "after"
  return payload
}

export function previewTabMove(draggedTab, neighbor) {
  if (!draggedTab || !neighbor?.tab) return false

  const target =
    neighbor.placement === "after"
      ? neighbor.tab.nextElementSibling
      : neighbor.tab

  if (target === draggedTab || draggedTab.nextElementSibling === target) {
    return false
  }

  draggedTab.parentElement.insertBefore(draggedTab, target)
  return true
}

export function restoreTabOrder(scroller, orderedIds) {
  if (!scroller || !orderedIds?.length) return

  const tabs = new Map(
    [...scroller.querySelectorAll("[data-ctx-window-id]")].map((tab) => [
      tab.dataset.ctxWindowId,
      tab,
    ]),
  )

  for (const id of orderedIds) {
    const tab = tabs.get(id)
    if (tab) scroller.appendChild(tab)
  }
}
