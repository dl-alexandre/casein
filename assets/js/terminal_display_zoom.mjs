export const DISPLAY_ZOOM_MIN = 0.5
export const DISPLAY_ZOOM_MAX = 3.0
export const DISPLAY_ZOOM_STEP = 0.1
export const DISPLAY_ZOOM_STORAGE = "devide:term-display-zoom"

export function clampDisplayZoom(zoom) {
  if (!Number.isFinite(zoom)) return 1
  return Math.max(DISPLAY_ZOOM_MIN, Math.min(DISPLAY_ZOOM_MAX, zoom))
}

export function adjustDisplayZoom(current, {delta = 0, reset = false} = {}) {
  if (reset) return 1
  return clampDisplayZoom(Math.round((current + delta) * 10) / 10)
}

export function formatDisplayZoomPercent(zoom) {
  return `${Math.round(clampDisplayZoom(zoom) * 100)}%`
}

export function displayZoomStorageKey(surfaceId, hookId) {
  const key = surfaceId || hookId || "default"
  return `${DISPLAY_ZOOM_STORAGE}:${key}`
}

export function loadStoredDisplayZoom(storageKey) {
  if (!storageKey) return 1
  try {
    const raw = localStorage.getItem(storageKey)
    if (raw == null) return 1
    return clampDisplayZoom(parseFloat(raw))
  } catch (_) {
    return 1
  }
}

export function saveStoredDisplayZoom(storageKey, zoom) {
  if (!storageKey) return
  try {
    localStorage.setItem(storageKey, String(clampDisplayZoom(zoom)))
  } catch (_) {
    /* storage disabled */
  }
}

export function activeDisplayZoomSurfaceId() {
  const focused = document.activeElement?.closest?.("[data-terminal-surface]")
  if (focused?.id) return focused.id

  const surface = document.querySelector("[data-terminal-surface]")
  return surface?.id || null
}