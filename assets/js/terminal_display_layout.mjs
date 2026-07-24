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
 * row count and scrolls the fixed grid up so the rows that matter (cursor /
 * prompt / TUI input line) stay visible above the keyboard — zero reflow. The
 * hidden top rows scroll off and clip; closing the keyboard scrolls them back.
 *
 * `anchorRow` is the row that must stay visible. Scrolling blindly to the grid
 * BOTTOM (the original behaviour, still the fallback) assumes the live content
 * sits at the last row. That holds for a scrolled shell, but not for a grid
 * whose written rows stop well short of the bottom — a fresh session, or a TUI
 * that draws from the top and leaves the tail blank. There the bottom window is
 * entirely unwritten rows, so opening the keyboard blanked the terminal.
 *
 * @param {{
 *   availableH: number, cellH: number, pinnedRows: number,
 *   anchorRow?: number, minRows?: number
 * }} input
 * @returns {{visibleRows: number, hiddenRows: number, offsetY: number, pinnedRows: number} | null}
 */
export function rowPinOffsets({availableH, cellH, pinnedRows, anchorRow, minRows = 2} = {}) {
  if (!(availableH > 0) || !(cellH > 0) || !(pinnedRows > 0)) return null
  const visibleRows = Math.max(minRows, Math.floor(availableH / cellH))
  const maxHidden = Math.max(0, pinnedRows - visibleRows)
  const anchor = Number.isFinite(anchorRow)
    ? Math.max(0, Math.min(pinnedRows - 1, Math.round(anchorRow)))
    : pinnedRows - 1
  // Scroll just far enough to bring the anchor onto the last visible row, never
  // past the end of the grid.
  const hiddenRows = Math.min(maxHidden, Math.max(0, anchor - visibleRows + 1))
  return {visibleRows, hiddenRows, offsetY: hiddenRows * cellH, pinnedRows}
}

/**
 * The row row-pinning must keep on screen.
 *
 * Preference order: the live cursor (where the operator is typing), then the
 * last row with any painted content (TUIs that hide the cursor), then the grid
 * bottom (a scrolled shell — the historical assumption).
 *
 * @param {{cursor?: {x?: number, y?: number, visible?: boolean}, rowsData?: any[][], pinnedRows: number}} input
 */
export function rowPinAnchorRow({cursor, rowsData, pinnedRows} = {}) {
  const lastRow = Number.isFinite(pinnedRows) && pinnedRows > 0 ? pinnedRows - 1 : 0

  const cy = cursor?.y
  if (cursor?.visible !== false && Number.isFinite(cy) && cy >= 0) {
    return Math.min(lastRow, cy)
  }

  if (Array.isArray(rowsData)) {
    for (let row = Math.min(lastRow, rowsData.length - 1); row >= 0; row -= 1) {
      if (rowHasContent(rowsData[row])) return row
    }
  }

  return lastRow
}

function rowHasContent(row) {
  if (!Array.isArray(row)) return false
  return row.some((cell) => {
    const ch = Array.isArray(cell) ? cell[0] : null
    return typeof ch === "string" && ch.trim() !== ""
  })
}

/**
 * Cols/rows a viewport can actually show.
 *
 * `padX`/`padY` are the *inner* padding of the element the cells paint into —
 * the vendor <pre> carries its own `padding: 8px` with `box-sizing: border-box`,
 * so its text box is that much smaller than the container we measure. Deriving
 * the grid from the container alone over-reports by ceil(pad / cell) cells,
 * which tmux then paints into columns/rows that fall outside the visible box
 * and get clipped by the <pre>'s `overflow: hidden` (characters silently
 * vanishing off the right edge).
 */
export function fitGridForViewport({
  availableW,
  availableH,
  cellW,
  cellH,
  padX = 0,
  padY = 0,
  minCols = 2,
  minRows = 2
} = {}) {
  if (!(cellW > 0) || !(cellH > 0)) return null
  const textW = Math.max(0, availableW - padX)
  const textH = Math.max(0, availableH - padY)
  return {
    cols: Math.max(minCols, Math.floor(textW / cellW)),
    rows: Math.max(minRows, Math.floor(textH / cellH)),
    textW,
    textH
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
