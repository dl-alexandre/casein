// Pure helpers for terminal display scaling / mobile authority.
//
// The scale-to-fit path must keep the cursor, selection layer, and <pre> in the
// same transform space — otherwise observers (and overflow-scale on mobile)
// paint the grid in a letterboxed center while the caret stays on the left
// edge of the container (the classic "narrow column with floating cursor"
// screenshot).

/**
 * Whether this client should prefer a mobile terminal layout (touch, installed
 * PWA, or a phone-narrow viewport). Used for alignment and for size-authority
 * heuristics that document.hasFocus() alone gets wrong on iOS.
 */
export function isMobileTerminalLayout(matchMedia = defaultMatchMedia) {
  if (typeof matchMedia !== "function") return false
  return (
    !!matchMedia("(pointer: coarse)")?.matches ||
    !!matchMedia("(display-mode: standalone)")?.matches ||
    !!matchMedia("(max-width: 639px)")?.matches
  )
}

/**
 * Size-authority signal for the focused-viewer contract.
 *
 * Desktop keeps the strict `document.hasFocus()` rule so a backgrounded tab
 * never shrinks the shared PTY. On mobile/PWA, iOS often reports hasFocus()
 * false while the operator is actively typing (soft keyboard / home indicator),
 * which used to stick the client in permanent scale-to-fit letterboxing.
 */
export function viewportActiveForClient({
  visibilityState = "visible",
  hasFocus = false,
  keyboardOpen = false,
  terminalInputFocused = false,
  mobileLayout = false
} = {}) {
  if (visibilityState !== "visible") return false
  if (hasFocus) return true
  // Mobile-only relaxations: soft keyboard or the terminal input itself is a
  // strong signal this device is driving the session.
  if (!mobileLayout) return false
  return keyboardOpen || terminalInputFocused
}

/**
 * Offsets for a scaled content box inside a padded viewport.
 *
 * - `center` — letterbox both axes (desktop observers).
 * - `top-center` — pin to the top, center horizontally (mobile): TUIs read
 *   top-down and a floating vertical letterbox wastes the keyboard-open strip.
 */
export function scaledContentOffsets({
  availableW,
  availableH,
  padL = 0,
  padT = 0,
  contentW,
  contentH,
  scale,
  align = "center"
} = {}) {
  const safeScale = Number.isFinite(scale) && scale > 0 ? scale : 1
  const scaledW = contentW * safeScale
  const scaledH = contentH * safeScale
  const freeX = Math.max(0, availableW - scaledW)
  const freeY = Math.max(0, availableH - scaledH)

  const offsetX = padL + freeX / 2
  const offsetY =
    align === "top-center" || align === "top-start" ? padT : padT + freeY / 2

  return {
    scale: safeScale,
    scaledW,
    scaledH,
    offsetX,
    offsetY
  }
}

export function fitBaseScale(availableW, availableH, contentW, contentH) {
  if (!(contentW > 0) || !(contentH > 0) || !(availableW > 0) || !(availableH > 0)) {
    return 1
  }
  return Math.min(availableW / contentW, availableH / contentH)
}

function defaultMatchMedia(query) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return { matches: false }
  }
  return window.matchMedia(query)
}
