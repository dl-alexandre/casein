export function pickerToggleDecision(action, surfaces) {
  if (action !== "session-picker" && action !== "window-picker") return null

  if (surfaces.mobileLayout) {
    return surfaces.mobileOpen ? "close-mobile" : "open-mobile"
  }

  const requestedOpen =
    action === "session-picker" ? surfaces.sessionsOpen : surfaces.windowsOpen

  return requestedOpen ? "close-sidebar" : "open-sidebar"
}

export function visiblePickerSurfaces(root = document) {
  return {
    mobileOpen: pickerElementVisible(root.querySelector("[data-mobile-nav-sheet]")),
    sessionsOpen: pickerElementVisible(root.querySelector("[data-sessions-picker-sidebar]")),
    windowsOpen: pickerElementVisible(root.querySelector("[data-window-picker-sidebar]")),
  }
}

export function pickerCloseEvent(surfaces) {
  if (surfaces.mobileOpen) return "mobile_nav:close"
  if (surfaces.sessionsOpen || surfaces.windowsOpen) return "sidebar:close"
  return null
}

export function pickerElementVisible(element) {
  if (!element) return false

  // Fixed-position mobile chrome may have no offsetParent even while painted.
  return element.offsetParent !== null || Boolean(element.getClientRects?.().length)
}
