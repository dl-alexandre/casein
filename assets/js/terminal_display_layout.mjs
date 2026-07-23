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

/**
 * Hysteresis latch for mobile size-authority.
 *
 * iOS/PWA flips `document.hasFocus()` (and closes the soft keyboard) for a
 * fraction of a second constantly — tapping the key bar, autocorrect, the home
 * indicator. Each demote→observer→re-promote round-trip is a full tmux reflow +
 * repaint on every viewer, which the operator sees as the terminal "resizing
 * unstably" and flashing a letterboxed narrow column mid-transition.
 *
 * Once a mobile viewer is genuinely active, keep it authoritative through a
 * brief inactive blip so a stray `hasFocus=false` can't bounce authority. The
 * raw signal always wins upward (an active viewer is active immediately);
 * downward it must stay quiet for `graceMs`. Desktop keeps the strict raw signal
 * (`mobileLayout=false`) so a backgrounded tab never pins the shared PTY.
 *
 * @param {{
 *   raw: boolean,            // viewportActiveForClient() this instant
 *   mobileLayout?: boolean,
 *   wasActive?: boolean,     // the last *latched* value we reported
 *   sinceActiveMs?: number,  // ms since raw was last true
 *   graceMs?: number
 * }} input
 */
export function latchMobileAuthority({
  raw,
  mobileLayout = false,
  wasActive = false,
  sinceActiveMs = Infinity,
  graceMs = 1200
} = {}) {
  if (raw) return true
  if (!mobileLayout) return false
  if (wasActive && Number.isFinite(sinceActiveMs) && sinceActiveMs < graceMs) return true
  return false
}

/**
 * Row-pinning geometry (trial, flag-gated by `?rowpin=1`).
 *
 * When the soft keyboard opens, the naive path recomputes rows from the smaller
 * viewport → the shared PTY resizes → tmux reflows/rewraps the whole screen (the
 * residual "flash"). Row-pinning instead keeps the PTY at its keyboard-closed
 * row count and scrolls the fixed grid up so its bottom rows (cursor / prompt /
 * TUI input line) stay visible above the keyboard — zero reflow. The hidden top
 * rows scroll off and clip; closing the keyboard scrolls them back.
 *
 * @param {{availableH: number, cellH: number, pinnedRows: number, minRows?: number}} input
 * @returns {{visibleRows: number, hiddenRows: number, offsetY: number, pinnedRows: number} | null}
 */
export function rowPinOffsets({availableH, cellH, pinnedRows, minRows = 2} = {}) {
  if (!(availableH > 0) || !(cellH > 0) || !(pinnedRows > 0)) return null
  const visibleRows = Math.max(minRows, Math.floor(availableH / cellH))
  const hiddenRows = Math.max(0, pinnedRows - visibleRows)
  return {visibleRows, hiddenRows, offsetY: hiddenRows * cellH, pinnedRows}
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
