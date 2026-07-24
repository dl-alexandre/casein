// The terminal layout decision, as one pure function.
//
// Everything about how a terminal grid is sized and transformed used to be
// spread across four DOM-mutating functions in ghostty_terminal.js
// (authoritativeFitToContainer, authoritativeOverflowGuard, scaleToContainer,
// applyRowPinLayout) plus a periodic reheal, each deriving the grid from
// "available space" on its own. That is why a single mistake — sizing from the
// container box instead of the <pre>'s text box — had to be fixed in four
// places, and why adding a new mode ("rowpin") silently missed consumers that
// kept their own list of modes.
//
// So: this module DECIDES, and nothing else does. It takes plain numbers in and
// returns a description of the layout out. No DOM, no globals, no clock. The
// hook's job is reduced to gather → compute → apply.
//
// The invariants this exists to preserve are asserted end-to-end in
// test/terminal_layout_contract.test.mjs.

import {
  fitBaseScale,
  fitGridForViewport,
  rowPinAnchorRow,
  rowPinOffsets,
  scaledContentOffsets
} from "./terminal_display_layout.mjs"

/**
 * The display modes, as one definition.
 *
 * - FIT     the grid was sized to this viewport; render untransformed.
 * - ZOOM    as FIT, but the operator applied a display zoom.
 * - SCALE   the rendered grid doesn't match our fit (an observer watching
 *           someone else's size, or our own resize hasn't landed yet) —
 *           letterbox it to fit rather than clip it.
 * - ROWPIN  mobile, keyboard open: hold the PTY at its keyboard-closed rows and
 *           scroll the fixed grid instead of reflowing tmux.
 */
export const DisplayMode = {
  FIT: "fit",
  ZOOM: "zoom",
  SCALE: "scale",
  ROWPIN: "rowpin"
}

// A mode is canvas-safe only when it leaves the frame untransformed: the glyph
// canvas draws at unscaled cell metrics, so any scale or translate would paint
// it in the wrong place. Derived from the mode itself so a new mode can never
// forget to declare itself — the failure that left "rowpin" off the old list.
export function isIdentityMode(mode) {
  return mode === DisplayMode.FIT
}

const NOOP = Object.freeze({noop: true, reason: "unmeasurable"})

/**
 * @param {object} input
 * @param {{availableW: number, availableH: number, padL: number, padT: number}} input.container
 *        Content box of the terminal element, and where its padding starts.
 * @param {{w: number, h: number, padX: number, padY: number}} input.cell
 *        Cell advance/line-height, plus the <pre>'s OWN padding on each axis.
 *        `padX`/`padY` are why the grid must not be derived from the container.
 * @param {{cols: number, rows: number}} input.renderedGrid  what the payload actually holds
 * @param {{cols: number, rows: number}|null} input.lastFit  what this viewer last reported
 * @param {number} input.lastAppliedUserZoom
 * @param {number|null} input.pinnedRows      keyboard-closed row anchor, if recorded
 * @param {{y?: number, visible?: boolean}|null} input.cursor
 * @param {any[][]|null} input.rowsData       for the last-painted-row fallback
 * @param {boolean} input.authority           this viewer owns the shared size
 * @param {boolean} input.mobile
 * @param {boolean} input.keyboardOpen
 * @param {boolean} input.rowPinAllowed       the ?rowpin= flag
 * @param {number} input.userZoom
 * @param {"event"|"periodic"} [input.trigger]
 * @returns {{
 *   noop?: true,
 *   mode?: string,
 *   reason: string,
 *   requestedGrid?: {cols: number, rows: number}|null,
 *   fitAnchor?: {cols: number, rows: number}|null,
 *   pinnedRows?: number|null,
 *   appliedUserZoom?: number|null,
 *   frame?: {left: number, top: number, width: number, height: number, transform: string}|null,
 *   cssScale?: number|null,
 *   cssZoom?: number|null,
 *   clipScreen?: boolean,
 *   canvasSafe?: boolean,
 *   rowPinWindow?: {pinnedRows: number, firstRow: number, lastRow: number}|null
 * }}
 */
export function computeTerminalLayout(input = {}) {
  const {container, cell} = input
  if (!container || !cell) return NOOP
  if (!(cell.w > 0) || !(cell.h > 0)) return NOOP

  // Below two cells in either axis the measurements are noise (a pane mounting
  // mid-transition, a collapsed split). Acting on them is how a grid gets
  // stranded at a tiny size that nothing later corrects.
  if (container.availableW < cell.w * 2 || container.availableH < cell.h * 2) return NOOP

  const grid = fitGridForViewport({
    availableW: container.availableW,
    availableH: container.availableH,
    cellW: cell.w,
    cellH: cell.h,
    padX: cell.padX,
    padY: cell.padY
  })
  if (!grid) return NOOP

  if (!input.authority) return observerLayout(input, grid)
  if (rowPinApplies(input)) return rowPinLayout(input, grid)
  return authoritativeLayout(input, grid)
}

function rowPinApplies({authority, rowPinAllowed, mobile, keyboardOpen, userZoom}) {
  return !!(authority && rowPinAllowed && mobile && keyboardOpen && userZoom === 1)
}

// A viewer that doesn't own the shared size renders whatever grid arrives,
// letterboxed to fit. It must never propose a size — see invariant I5.
function observerLayout(input, grid) {
  const {cell, container, renderedGrid, userZoom, mobile} = input
  const cols = Math.max(1, renderedGrid?.cols || 0)
  const rows = Math.max(1, renderedGrid?.rows || 0)

  const contentW = cols * cell.w + cell.padX
  const contentH = rows * cell.h + cell.padY
  if (contentW <= 0 || contentH <= 0) return NOOP

  const base = fitBaseScale(container.availableW, container.availableH, contentW, contentH)

  return {
    mode: DisplayMode.SCALE,
    reason: "observer",
    requestedGrid: null,
    fitAnchor: null,
    pinnedRows: grid.rows,
    appliedUserZoom: null,
    ...scaledFrame({container, contentW, contentH, scale: base * userZoom, mobile}),
    cssZoom: userZoom,
    clipScreen: false,
    canvasSafe: false,
    rowPinWindow: null
  }
}

/**
 * The focused viewer: size the shared grid to this viewport.
 *
 * This folds together what used to be two sequential passes — the fit, then an
 * overflow guard that could override it. Expressed as one decision: we always
 * want the fitted grid, but while the RENDERED grid is bigger than the grid we
 * asked for (our resize hasn't landed, or another writer moved it) we borrow
 * the observer's letterbox so the extra rows/columns are visible instead of
 * clipped by the <pre>'s overflow:hidden.
 */
function authoritativeLayout(input, grid) {
  const {cell, container, renderedGrid, lastFit, lastAppliedUserZoom, userZoom, mobile, trigger} = input

  const fitUnchanged =
    !!lastFit && lastFit.cols === grid.cols && lastFit.rows === grid.rows

  // Growth-only on the periodic tick. The level-triggered backstop exists to
  // rescue a grid stranded SMALL when no resize event landed; letting it also
  // shrink would let two viewers ratchet each other down with no user input —
  // the size-fight every previous fix in this area guarded against.
  const shrinking =
    !!lastFit && (grid.cols < lastFit.cols || grid.rows < lastFit.rows)
  const mayPush = !fitUnchanged && !(trigger === "periodic" && shrinking)

  const anchor = mayPush ? {cols: grid.cols, rows: grid.rows} : lastFit
  const requestedGrid = mayPush ? {cols: grid.cols, rows: grid.rows} : null

  const rendered = {
    cols: renderedGrid?.cols ?? 0,
    rows: renderedGrid?.rows ?? 0
  }
  const overflows =
    !!anchor && (rendered.cols > anchor.cols || rendered.rows > anchor.rows)

  if (overflows) {
    const contentW = rendered.cols * cell.w + cell.padX
    const contentH = rendered.rows * cell.h + cell.padY
    const base = fitBaseScale(container.availableW, container.availableH, contentW, contentH)

    return {
      mode: DisplayMode.SCALE,
      reason: "grid_overflows_fit",
      requestedGrid,
      fitAnchor: anchor,
      pinnedRows: grid.rows,
      appliedUserZoom: userZoom,
      ...scaledFrame({container, contentW, contentH, scale: base * userZoom, mobile}),
      cssZoom: userZoom,
      clipScreen: false,
      canvasSafe: false,
      rowPinWindow: null
    }
  }

  const zoomUnchanged = userZoom === lastAppliedUserZoom
  if (fitUnchanged && zoomUnchanged) {
    return {
      mode: userZoom === 1 ? DisplayMode.FIT : DisplayMode.ZOOM,
      reason: "steady",
      requestedGrid: null,
      fitAnchor: anchor,
      pinnedRows: grid.rows,
      appliedUserZoom: userZoom,
      unchanged: true,
      ...(userZoom === 1
        ? {frame: null, cssScale: null}
        : zoomFrameFor({cell, container, grid: anchor, userZoom, mobile})),
      cssZoom: userZoom === 1 ? null : userZoom,
      clipScreen: false,
      canvasSafe: userZoom === 1,
      rowPinWindow: null
    }
  }

  if (userZoom === 1) {
    return {
      mode: DisplayMode.FIT,
      reason: mayPush ? "fit" : "fit_held",
      requestedGrid,
      fitAnchor: anchor,
      pinnedRows: grid.rows,
      appliedUserZoom: 1,
      frame: null,
      cssScale: null,
      cssZoom: null,
      clipScreen: false,
      canvasSafe: true,
      rowPinWindow: null
    }
  }

  return {
    mode: DisplayMode.ZOOM,
    reason: mayPush ? "zoom" : "zoom_held",
    requestedGrid,
    fitAnchor: anchor,
    pinnedRows: grid.rows,
    appliedUserZoom: userZoom,
    ...zoomFrameFor({cell, container, grid: anchor, userZoom, mobile}),
    cssZoom: userZoom,
    clipScreen: false,
    canvasSafe: false,
    rowPinWindow: null
  }
}

/**
 * Mobile, keyboard up: keep the PTY at its keyboard-closed row count and scroll
 * the fixed grid so the anchor row stays on screen — zero tmux reflow.
 *
 * The anchor is the cursor, then the last painted row, then the grid bottom.
 * Scrolling blindly to the bottom (the original behaviour) assumes the live
 * content sits on the last row; on a grid whose written rows stop short of the
 * bottom that parked the visible window in unwritten rows and the terminal went
 * blank the moment the keyboard opened.
 */
function rowPinLayout(input, grid) {
  const {cell, container, lastFit, cursor, rowsData} = input

  const cols = grid.cols
  const pinnedRows = Math.max(2, input.pinnedRows || grid.rows)

  const pin = rowPinOffsets({
    availableH: grid.textH,
    cellH: cell.h,
    pinnedRows,
    anchorRow: rowPinAnchorRow({cursor, rowsData, pinnedRows})
  })
  if (!pin) return NOOP

  // Only propose a size when the SHAPE genuinely changed (rotation, font), so
  // opening and closing the keyboard never costs a reflow.
  const shapeChanged = !lastFit || cols !== lastFit.cols || pinnedRows !== lastFit.rows

  return {
    mode: DisplayMode.ROWPIN,
    reason: "row_pin",
    requestedGrid: shapeChanged ? {cols, rows: pinnedRows} : null,
    fitAnchor: {cols, rows: pinnedRows},
    pinnedRows,
    appliedUserZoom: 1,
    frame: {
      left: container.padL,
      top: container.padT,
      width: cols * cell.w + cell.padX,
      height: pinnedRows * cell.h + cell.padY,
      transform: `translateY(-${pin.offsetY}px)`
    },
    cssScale: 1,
    cssZoom: null,
    clipScreen: true,
    canvasSafe: false,
    rowPinWindow: {
      pinnedRows,
      firstRow: pin.hiddenRows,
      lastRow: pin.hiddenRows + pin.visibleRows - 1
    }
  }
}

function zoomFrameFor({cell, container, grid, userZoom, mobile}) {
  const contentW = grid.cols * cell.w + cell.padX
  const contentH = grid.rows * cell.h + cell.padY
  return scaledFrame({container, contentW, contentH, scale: userZoom, mobile})
}

// TUIs read top-down, and on mobile a floating vertical letterbox wastes the
// strip the keyboard already took, so pin to the top there.
function scaledFrame({container, contentW, contentH, scale, mobile}) {
  const {offsetX, offsetY} = scaledContentOffsets({
    availableW: container.availableW,
    availableH: container.availableH,
    padL: container.padL,
    padT: container.padT,
    contentW,
    contentH,
    scale,
    align: mobile ? "top-center" : "center"
  })

  return {
    frame: {
      left: offsetX,
      top: offsetY,
      width: contentW,
      height: contentH,
      transform: `scale(${scale})`
    },
    cssScale: scale
  }
}
