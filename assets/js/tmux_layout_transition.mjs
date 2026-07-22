function confirmedValue(confirmed, camel, snake) {
  return confirmed?.[camel] ?? confirmed?.[snake]
}

export function normalizeConfirmedProjection(confirmed) {
  return {
    version: Number(confirmedValue(confirmed, "layoutVersion", "layout_version")),
    topologyVersion: Number(confirmedValue(confirmed, "version", "version")),
    zoomed: confirmedValue(confirmed, "zoomed", "zoomed") === true,
    activePaneId: confirmedValue(confirmed, "activePaneId", "active_pane_id") || null,
    bounds: confirmed?.bounds || {width: 1, height: 1},
    panes: confirmedValue(confirmed, "paneRects", "pane_rects") || [],
  }
}

export function waitForConfirmedLayout(layout, confirmed, signal, timeoutMs = 1000) {
  const expected = normalizeConfirmedProjection(confirmed)
  if (layoutMatches(layout, expected)) return Promise.resolve()

  if (signal?.aborted) {
    const error = new Error("Transition cancelled")
    error.name = "AbortError"
    return Promise.reject(error)
  }

  return new Promise((resolve, reject) => {
    let settled = false
    let observer = null

    const finish = (error) => {
      if (settled) return
      settled = true
      observer?.disconnect()
      clearTimeout(timer)
      signal?.removeEventListener("abort", onAbort)
      if (error) reject(error)
      else resolve()
    }

    const check = () => {
      if (layoutMatches(layout, expected)) finish()
    }

    const onAbort = () => {
      const error = new Error("Transition cancelled")
      error.name = "AbortError"
      finish(error)
    }

    const timer = setTimeout(() => finish(new Error("confirmed_layout_timeout")), timeoutMs)

    if (typeof MutationObserver !== "undefined") {
      observer = new MutationObserver(check)
      observer.observe(layout, {
        attributes: true,
        attributeFilter: ["data-layout-version", "data-window-zoomed"],
        childList: true,
      })
    }

    signal?.addEventListener("abort", onAbort, {once: true})
    check()
  })
}

function layoutMatches(layout, expected) {
  const metadataMatches =
    Number(layout?.dataset?.layoutVersion) === expected.version &&
    (layout?.dataset?.windowZoomed === "true") === expected.zoomed

  if (!metadataMatches || typeof layout?.querySelectorAll !== "function") return metadataMatches

  const actualPaneIds = Array.from(layout.querySelectorAll("section[data-pane-id]"))
    .map((pane) => pane.dataset.paneId)
    .sort()
  const expectedPaneIds = expected.panes.map((pane) => pane.id).sort()

  return (
    actualPaneIds.length === expectedPaneIds.length &&
    actualPaneIds.every((paneId, index) => paneId === expectedPaneIds[index])
  )
}
