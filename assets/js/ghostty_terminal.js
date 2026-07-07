/**
 * Extension layer over vendor GhosttyTerminal hook.
 *
 * This keeps local rendering/layout patches off of `assets/vendor/ghostty.js` so
 * dependency refreshes do not silently drop them.
 */
import {GhosttyTerminal as GhosttyTerminalVendor} from "../vendor/ghostty"
import {
  installTerminalClipboardPaste,
  pasteFromNavigatorClipboard
} from "./terminal_clipboard"
import { copyTextSync, copyTextWithFallback } from "./terminal_copy"
import {applyServerThemeBundle, remapColor, termVar} from "./terminal_themes"
import {BOLD, ITALIC, OVERLINE, effectiveCellFlags} from "./terminal_cell_flags.mjs"
import {backgroundLeadingPad} from "./terminal_bg_fill.mjs"
import {
  canvasCoalesceEnabled,
  canvasRendererEnabled,
  paintCanvasCells,
  paintCanvasCellsCoalesced,
  resetCanvasRenderer
} from "./terminal_canvas"
import {
  DISPLAY_ZOOM_STEP,
  adjustDisplayZoom,
  displayZoomStorageKey,
  formatDisplayZoomPercent,
  loadStoredDisplayZoom,
  saveStoredDisplayZoom
} from "./terminal_display_zoom.mjs"
import {fileLinkAt, updateFileLinkStore} from "./terminal_file_links.mjs"

function escapeCellChar(value) {
  switch (value) {
    case "&":
      return "&amp;"
    case "<":
      return "&lt;"
    case ">":
      return "&gt;"
    default:
      return value
  }
}

const CELL_STYLE_CACHE = new Map()

// --- Glyph advance correction ------------------------------------------------
//
// A row is one inline text flow (runs must stay inline — see the terminal
// grid rendering comment in app.css), so a cell's pixel position is the sum
// of every glyph advance before it. That only equals `col * cellWidth` when
// every glyph advances exactly one cell. Glyphs the primary monospace font
// lacks (⏸ ⎿ ☰ ⣷ …) render from fallback fonts at other advances (⎿ is ~1.67
// cells in the default Linux stack), shifting the whole rest of the row: tmux
// split seams turn ragged and the cursor — positioned at col × cellWidth —
// drifts off the text. Each glyph is therefore measured once per font
// configuration and pinned back to its cell with fractional letter-spacing.
// Letter-spacing is applied after every glyph including the last, so a run of
// N corrected glyphs spans exactly N cells, and unlike an inline-block box it
// keeps the row a single text flow (native selection, no per-box width
// rounding). Wide glyphs are followed by an empty spacer cell in the grid
// payload (rendered as a space), so pinning them to one cell keeps the pair at
// two cells while the ink overflows across its own spacer.

const ADVANCE_EPSILON_PX = 0.02
const ADVANCE_DELTAS = new Map()

let advanceMeasure = null
let advanceFontSig = ""
let advanceCellWidth = 0
// Half-leading background pad ({top, bottom} px) for the current font config;
// null when the content box already fills the line box. See terminal_bg_fill.mjs.
let bgLeadingPad = null

function advanceMeasureEl() {
  if (advanceMeasure && advanceMeasure.isConnected) return advanceMeasure

  const el = document.createElement("span")
  el.setAttribute("aria-hidden", "true")
  Object.assign(el.style, {
    position: "absolute",
    top: "-9999px",
    left: "0",
    visibility: "hidden",
    pointerEvents: "none",
    whiteSpace: "pre",
    letterSpacing: "0",
    fontFeatureSettings: "normal",
    fontVariantLigatures: "none",
    textRendering: "geometricPrecision"
  })
  document.body.appendChild(el)
  advanceMeasure = el
  return el
}

// Sync the measuring span to the pre's font and (re)measure the reference cell
// width. Returns false when no usable cell width is available (e.g. hidden
// container mid-layout); the frame then renders uncorrected rather than caching
// garbage deltas.
function syncAdvanceContext(pre) {
  const styles = window.getComputedStyle(pre)
  const sig = `${styles.fontFamily}|${styles.fontSize}|${styles.fontWeight}|${styles.fontStyle}|${styles.lineHeight}`
  if (sig === advanceFontSig) return advanceCellWidth > 0

  const el = advanceMeasureEl()
  el.style.fontFamily = styles.fontFamily
  el.style.fontSize = styles.fontSize
  el.style.fontWeight = styles.fontWeight
  el.style.fontStyle = styles.fontStyle
  el.textContent = "M".repeat(20)
  advanceCellWidth = el.getBoundingClientRect().width / 20
  bgLeadingPad = backgroundLeadingPad(
    parseFloat(styles.lineHeight),
    measureInlineContentHeight(el)
  )
  advanceFontSig = sig
  ADVANCE_DELTAS.clear()
  // Cached cell styles embed the previous font config's background pad.
  CELL_STYLE_CACHE.clear()
  return advanceCellWidth > 0
}

// Content-box height (font ascent + descent) of an inline run — exactly what
// an inline span's background paints. Measured from an inline CHILD of the
// measure host: the host is absolutely positioned, so its own rect is a line
// box sized by the page's inherited line-height (e.g. Tailwind's 1.5), which
// is unrelated to what inline backgrounds cover. An inline box's rect height
// is the font's content box regardless of line-height.
function measureInlineContentHeight(host) {
  const inner = document.createElement("span")
  inner.textContent = "Mg"
  host.textContent = ""
  host.appendChild(inner)
  const height = inner.getBoundingClientRect().height
  host.textContent = ""
  return height
}

// Per-cell letter-spacing correction in px as a style-ready string, "" when the
// glyph already advances one cell. Bold/italic variants are measured separately
// (fallback glyph advances can differ per weight).
function advanceDeltaStr(char, flags) {
  if (char.length === 1) {
    const code = char.charCodeAt(0)
    if (code >= 0x20 && code <= 0x7e) return ""
  }

  const variant = flags & (BOLD | ITALIC)
  const key = `${char}|${variant}`
  const cached = ADVANCE_DELTAS.get(key)
  if (cached !== undefined) return cached

  const el = advanceMeasureEl()
  el.style.fontWeight = variant & BOLD ? "bold" : ""
  el.style.fontStyle = variant & ITALIC ? "italic" : ""
  el.textContent = char.repeat(10)
  const advance = el.getBoundingClientRect().width / 10
  el.style.fontWeight = ""
  el.style.fontStyle = ""

  if (!(advance > 0)) return ""

  const delta = advanceCellWidth - advance
  const value = Math.abs(delta) < ADVANCE_EPSILON_PX ? "" : delta.toFixed(3)
  if (ADVANCE_DELTAS.size > 4096) ADVANCE_DELTAS.clear()
  ADVANCE_DELTAS.set(key, value)
  return value
}

function runHtml(style, spacing, text) {
  if (!text) return ""

  const full = spacing
    ? style
      ? `${style};letter-spacing:${spacing}px`
      : `letter-spacing:${spacing}px`
    : style

  return full ? `<span style="${full}">${text}</span>` : text
}

function cellStyle(fg, bg, flags) {
  if (!fg && !bg && !flags) return ""

  const key = `${fg ? fg.join(",") : ""}|${bg ? bg.join(",") : ""}|${flags || 0}`
  const cached = CELL_STYLE_CACHE.get(key)
  if (cached !== undefined) return cached

  const styles = []
  const decorations = []

  const mappedFg = remapColor(fg)
  const mappedBg = remapColor(bg)

  if (mappedFg) styles.push(`color:rgb(${mappedFg[0]}, ${mappedFg[1]}, ${mappedFg[2]})`)

  if (mappedBg) {
    styles.push(`background:rgb(${mappedBg[0]}, ${mappedBg[1]}, ${mappedBg[2]})`)

    // Fill the line-height leading so adjacent bg rows meet with no seam of
    // the <pre> background between them (see terminal_bg_fill.mjs).
    if (bgLeadingPad) {
      styles.push(`padding-block:${bgLeadingPad.top}px ${bgLeadingPad.bottom}px`)
    }
  }

  if (flags & 1) styles.push("font-weight:bold")
  if (flags & 2) styles.push("font-style:italic")
  if (flags & 4) styles.push("opacity:0.5")
  if (flags & 8) decorations.push("underline")
  if (flags & 16) decorations.push("line-through")
  if (flags & OVERLINE) decorations.push("overline")

  if (decorations.length > 0) {
    styles.push(`text-decoration:${decorations.join(" ")}`)
  }

  const style = styles.join(";")
  if (CELL_STYLE_CACHE.size > 4096) CELL_STYLE_CACHE.clear()
  CELL_STYLE_CACHE.set(key, style)
  return style
}

function renderCellsRLE(pre, rows) {
  const correct = syncAdvanceContext(pre)
  let html = ""
  for (const row of rows) {
    let currentStyle = null
    let currentSpacing = ""
    let currentText = ""

    for (const [char, fg, bg, flags] of row) {
      const style = cellStyle(fg, bg, effectiveCellFlags(char, flags))
      const glyph = char || " "
      const spacing = correct ? advanceDeltaStr(glyph, flags || 0) : ""
      const cellChar = escapeCellChar(glyph)

      if (style === currentStyle && spacing === currentSpacing) {
        currentText += cellChar
      } else {
        html += runHtml(currentStyle, currentSpacing, currentText)
        currentStyle = style
        currentSpacing = spacing
        currentText = cellChar
      }
    }

    html += runHtml(currentStyle, currentSpacing, currentText)
    html += "\n"
  }

  if (pre.__devideLastHtml === html) return
  pre.__devideLastHtml = html
  pre.innerHTML = html
}

// Touch devices (phones/tablets) can't drive the vendor's mouse-based cell
// selection — touch drags never fire mousedown/mousemove. The vendor disables
// native selection (user-select: none), so copy-out is impossible on mobile in
// raw mode. On coarse pointers we re-enable native text selection on the pre;
// the browser then handles long-press selection and the system copy menu. The
// vendor's onCopy bails when there's no *custom* selection, so native copy
// proceeds untouched. Desktop (fine pointer) keeps the custom selection — no
// regression there.
const TOUCH_DEVICE =
  typeof window !== "undefined" &&
  typeof window.matchMedia === "function" &&
  window.matchMedia("(pointer: coarse)").matches

const LONGPRESS_MS = 400

// Touch-scroll tuning. A TWO-finger drag translates into the terminal's own
// wheel routing (emulator scrollback vs tmux/alt-screen PTY bytes) so direction
// and per-program handling exactly match a trackpad. WHEEL_PX is one wheel
// "notch" of finger travel; we only emit a notch once that much has
// accumulated, which keeps slow drags proportional instead of jumping a line
// per touchmove event.
const TOUCH_SCROLL_WHEEL_PX = 48
// A SINGLE-finger vertical drag is a virtual d-pad instead: every STEP_PX of
// travel sends one ArrowUp/ArrowDown to the PTY (finger down = ArrowDown,
// matching direct manipulation of a cursor/menu highlight).
const TOUCH_ARROW_STEP_PX = 36
// Vertical travel before we commit the gesture to scrolling (and lock out the
// horizontal pane-swipe / long-press-select paths for the rest of the touch).
const TOUCH_SCROLL_START_PX = 8
// Inertia: per-frame velocity decay and the speed below which the fling stops.
const TOUCH_INERTIA_FRICTION = 0.94
const TOUCH_INERTIA_MIN_VEL = 0.02 // px/ms

function markTerminalPerf(hook, name, detail = {}) {
  const marker = window.__devideMarkPerf
  if (typeof marker !== "function") return

  marker(`terminal:${name}`, {
    id: hook?.el?.id,
    pane_id: hook?.el?.id?.replace(/^ghostty-/, ""),
    ...detail
  })
}

// --- Terminal echo-latency harness (opt-in via ?termlat) -------------------
// Measures perceived echo latency: time from a keystroke leaving the browser
// (pushText) to the frame that reflects it being painted (renderPatched).
// Optionally injects symmetric synthetic RTT so WAN feel can be reproduced on
// localhost without netem/root. Fully inert unless `?termlat` is present.
//   ?termlat       enable measurement + HUD (zero injection)
//   ?termlat=80    also inject 80ms symmetric RTT (40ms each direction)
// Console API once enabled: window.devideTermLatency.probe({count,intervalMs,char})
const TERM_LAT = (() => {
  try {
    const params = new URLSearchParams(window.location.search)
    if (!params.has("termlat")) return null
    const raw = parseInt(params.get("termlat"), 10)
    const injectMs = Number.isFinite(raw) && raw > 0 ? raw : 0
    return {injectMs, hook: null, samples: [], pending: [], frames: 0, bytes: 0, resolve: null}
  } catch (_) {
    return null
  }
})()

function termLatHalfDelay() {
  return TERM_LAT && TERM_LAT.injectMs > 0 ? TERM_LAT.injectMs / 2 : 0
}

function termLatPercentile(values, q) {
  if (!values.length) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]
}

// Does this outgoing event represent one printable keystroke that should echo
// exactly one frame? Normal typing is a "key" event (vendor onKeydown); "text"
// is only paste/IME. Skip modifiers and named keys (Enter/Backspace/ArrowUp…)
// and chords — FIFO frame attribution only holds for isolated printable chars.
function termLatIsEcho(event, payload) {
  if (!payload) return false
  if (event === "text") return typeof payload.data === "string" && payload.data.length === 1
  if (event === "key") {
    return (
      typeof payload.key === "string" &&
      [...payload.key].length === 1 &&
      !payload.ctrlKey &&
      !payload.altKey &&
      !payload.metaKey
    )
  }
  return false
}

// Wrap an outgoing key/text send: stamp t0 for echoing keystrokes and apply the
// outbound half of the synthetic RTT before the bytes leave the browser.
function termLatSend(hook, event, payload, send) {
  if (!TERM_LAT) {
    send()
    return
  }
  TERM_LAT.hook = hook
  if (termLatIsEcho(event, payload)) {
    TERM_LAT.pending.push({t0: performance.now()})
  }
  const delay = termLatHalfDelay()
  if (delay > 0) window.setTimeout(send, delay)
  else send()
}

// Record a painted frame and attribute it to the oldest pending keystroke.
function termLatOnApply(payload) {
  if (!TERM_LAT) return
  TERM_LAT.frames += 1
  try {
    TERM_LAT.bytes += JSON.stringify(payload).length
  } catch (_) {
    /* circular payloads shouldn't happen, but never let metrics throw */
  }
  const probe = TERM_LAT.pending.shift()
  if (probe) {
    const dt = performance.now() - probe.t0
    TERM_LAT.samples.push(dt)
    if (TERM_LAT.samples.length > 500) TERM_LAT.samples.shift()
    if (TERM_LAT.resolve) {
      const resolve = TERM_LAT.resolve
      TERM_LAT.resolve = null
      resolve(dt)
    }
  }
  termLatRenderHud()
}

let _termLatHud = null
function termLatRenderHud() {
  if (!TERM_LAT) return
  if (!_termLatHud) {
    _termLatHud = document.createElement("div")
    Object.assign(_termLatHud.style, {
      position: "fixed",
      bottom: "8px",
      right: "8px",
      zIndex: "99999",
      font: "11px monospace",
      background: "rgba(0,0,0,0.82)",
      color: "#39ff14",
      padding: "6px 8px",
      whiteSpace: "pre",
      pointerEvents: "none",
      borderRadius: "4px"
    })
    document.body.appendChild(_termLatHud)
  }
  const samples = TERM_LAT.samples
  const avgBytes = TERM_LAT.frames ? Math.round(TERM_LAT.bytes / TERM_LAT.frames) : 0
  _termLatHud.textContent =
    `echo ms  p50 ${termLatPercentile(samples, 0.5).toFixed(0)}  ` +
    `p95 ${termLatPercentile(samples, 0.95).toFixed(0)}  n ${samples.length}\n` +
    `inject ${TERM_LAT.injectMs}ms  frames ${TERM_LAT.frames}  avgB ${avgBytes}`
}

// Auto-probe: type a char, await its echo, send DEL to erase it, repeat.
// Never sends Enter, so it never executes a command line.
function termLatProbe(hook, opts) {
  if (!TERM_LAT) {
    console.warn("[termlat] add ?termlat to the URL to enable the harness")
    return
  }
  if (!hook) {
    console.warn("[termlat] no terminal hook yet — focus a terminal and type once")
    return
  }
  const {count = 30, intervalMs = 250, char = "x"} = opts || {}
  const results = []
  let i = 0
  const step = () => {
    if (i >= count) {
      console.info(
        `[termlat] probe done n=${results.length} ` +
          `p50=${termLatPercentile(results, 0.5).toFixed(0)}ms ` +
          `p95=${termLatPercentile(results, 0.95).toFixed(0)}ms ` +
          `inject=${TERM_LAT.injectMs}ms`
      )
      return
    }
    i += 1
    const echoed = new Promise((resolve) => {
      TERM_LAT.resolve = resolve
    })
    pushText(hook, char)
    echoed.then((dt) => {
      results.push(dt)
      pushText(hook, "\x7f")
      window.setTimeout(step, intervalMs)
    })
  }
  step()
}

if (TERM_LAT && typeof window !== "undefined") {
  window.devideTermLatency = {
    probe: (opts) => termLatProbe(TERM_LAT.hook, opts),
    stats: () => ({
      p50: termLatPercentile(TERM_LAT.samples, 0.5),
      p95: termLatPercentile(TERM_LAT.samples, 0.95),
      n: TERM_LAT.samples.length,
      injectMs: TERM_LAT.injectMs
    }),
    reset: () => {
      TERM_LAT.samples = []
      TERM_LAT.pending = []
      TERM_LAT.frames = 0
      TERM_LAT.bytes = 0
    }
  }
}

// On-screen debug HUD, enabled by adding `seldebug=1` to the workspace URL
// (e.g. ?seldebug=1). Prints touch/selection lifecycle so we can
// tune mobile long-press selection on a real device instead of guessing.
const SEL_DEBUG = (() => {
  try {
    return new URLSearchParams(window.location.search).has("seldebug")
  } catch (_) {
    return false
  }
})()

let _hudEl = null
function hud(msg) {
  if (!SEL_DEBUG) return
  if (!_hudEl) {
    _hudEl = document.createElement("div")
    Object.assign(_hudEl.style, {
      position: "fixed",
      left: "4px",
      top: "calc(env(safe-area-inset-top) + 2px)",
      zIndex: "9999",
      maxWidth: "72vw",
      maxHeight: "38vh",
      overflow: "hidden",
      background: "rgba(0,0,0,0.82)",
      color: "#22c55e",
      font: "10px ui-monospace, monospace",
      lineHeight: "1.25",
      padding: "4px 6px",
      borderRadius: "4px",
      pointerEvents: "none",
      whiteSpace: "pre-wrap"
    })
    document.body.appendChild(_hudEl)
    _hudEl.__lines = []
  }
  const t = new Date().toISOString().slice(17, 23)
  _hudEl.__lines.push(`${t} ${msg}`)
  if (_hudEl.__lines.length > 16) _hudEl.__lines.shift()
  _hudEl.textContent = _hudEl.__lines.join("\n")
}

function patchPreLayout(hook) {
  if (!hook.pre || !hook.input || !hook.cursorText) return

  Object.assign(hook.pre.style, {
    position: "absolute",
    inset: "0",
    boxSizing: "border-box",
    letterSpacing: "0",
    fontFeatureSettings: "normal",
    fontVariantLigatures: "none",
    textRendering: "geometricPrecision",
    lineHeight:
      getComputedStyle(document.documentElement)
        .getPropertyValue("--devide-terminal-line-height")
        .trim() || "17px",
    backgroundColor: termVar("--devide-term-bg") || "#0a0a0a",
    color: termVar("--devide-term-fg") || "#e4e4e7"
  })

  // Native browser text selection on the pre — desktop and touch alike. The
  // vendor disables it (user-select: none) and relies on its own cell-selection,
  // but that's suppressed whenever the program requests mouse tracking (tmux
  // `mouse on` does this globally), leaving no way to select. We instead let the
  // browser select and stop the drag from reaching tmux (see the pushEventTo
  // filter in mounted), so selection works regardless of tmux's mouse mode.
  hook.pre.style.userSelect = "text"
  hook.pre.style.webkitUserSelect = "text"
  if (TOUCH_DEVICE) {
    // iOS needs this to allow the long-press selection callout on the pre.
    hook.pre.style.webkitTouchCallout = "default"
  }

  Object.assign(hook.input.style, {
    fontVariantLigatures: "none",
    textRendering: "geometricPrecision"
  })

  if (hook.measure) {
    hook.measure.style.letterSpacing = "0"
    hook.measure.style.fontFeatureSettings = "normal"
    hook.measure.style.fontVariantLigatures = "none"
    hook.measure.style.textRendering = "geometricPrecision"
  }

  if (hook.selectionLayer) {
    Object.assign(hook.selectionLayer.style, {
      position: "absolute",
      inset: "0",
      pointerEvents: "none",
      zIndex: "0"
    })
  }
}

function alignCursorPosition(hook) {
  if (!hook.cursorEl || !hook.cursorText || !hook.cursor) return

  const left = parseFloat(hook.cursorEl.style.left)
  const top = parseFloat(hook.cursorEl.style.top)

  if (Number.isFinite(left)) {
    hook.cursorEl.style.left = `${Math.round(left)}px`
  }

  if (Number.isFinite(top)) {
    hook.cursorEl.style.top = `${Math.round(top)}px`
  }
}

function selectionActiveWithin(hook) {
  return hook.__nativeSelecting || hook.__selectionActive
}

// True when the user currently has a non-collapsed text selection inside this
// terminal's <pre>. Used to pause repaints on touch so a render (e.g. the tmux
// status-bar clock ticking every second) doesn't wipe the selection mid-copy.
function hasActiveSelectionWithin(pre) {
  if (!pre) return false
  const sel = window.getSelection && window.getSelection()
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return false
  const range = sel.getRangeAt(0)
  if (pre.contains(range.commonAncestorContainer)) return true

  try {
    return range.intersectsNode(pre)
  } catch (_) {
    return false
  }
}

function normalizeCellSelection(anchor, focus) {
  if (!anchor || !focus) return null

  if (focus.row < anchor.row || (focus.row === anchor.row && focus.col < anchor.col)) {
    return { start: focus, end: anchor }
  }

  if (anchor.row === focus.row && anchor.col === focus.col) return null

  return { start: anchor, end: focus }
}

function selectedTextFromCells(hook) {
  const selection = normalizeCellSelection(hook.__selectionAnchor, hook.__selectionFocus)
  if (!selection) return ""

  const lines = []
  const cols = hook.cols || 0
  const rowsData = hook.rowsData || []

  for (let row = selection.start.row; row <= selection.end.row; row += 1) {
    const sourceRow = rowsData[row] || []
    const startCol = row === selection.start.row ? selection.start.col : 0
    const endCol = row === selection.end.row ? selection.end.col : cols - 1
    let text = ""

    for (let col = startCol; col <= endCol; col += 1) {
      text += sourceRow[col]?.[0] || " "
    }

    lines.push(text.trimEnd())
  }

  return lines.join("\n")
}

function nativeSelectionTextWithin(pre) {
  if (!pre) return ""
  if (!hasActiveSelectionWithin(pre)) return ""
  return window.getSelection()?.toString() || ""
}

function scrollbarState(scrollbar) {
  if (!scrollbar) return null

  const total = Number(scrollbar.total ?? scrollbar["total"] ?? 0)
  const offset = Number(scrollbar.offset ?? scrollbar["offset"] ?? 0)
  const len = Number(scrollbar.len ?? scrollbar["len"] ?? 0)

  if (!Number.isFinite(total) || !Number.isFinite(offset) || !Number.isFinite(len)) return null
  return { total, offset, len }
}

function ensureScrollbarChrome(hook) {
  if (hook.__scrollbarTrack || !hook.screen) return

  const track = document.createElement("div")
  track.className = "devide-term-scrollbar"
  track.dataset.pinned = "true"
  track.setAttribute("aria-hidden", "true")

  const thumb = document.createElement("div")
  thumb.className = "devide-term-scrollbar-thumb"
  track.appendChild(thumb)

  hook.screen.appendChild(track)
  hook.__scrollbarTrack = track
  hook.__scrollbarThumb = thumb
}

function updateScrollbarChrome(hook, scrollbar) {
  ensureScrollbarChrome(hook)

  const track = hook.__scrollbarTrack
  const thumb = hook.__scrollbarThumb
  if (!track || !thumb) return

  const state = scrollbarState(scrollbar)
  if (!state || state.total <= state.len) {
    track.style.display = "none"
    hook.el.dataset.scrollPinned = "true"
    return
  }

  const maxOffset = Math.max(0, state.total - state.len)
  const pinned = state.offset >= maxOffset
  const trackHeight = hook.screen.clientHeight || hook.el.clientHeight || 0

  if (trackHeight <= 0) {
    track.style.display = "none"
    return
  }

  track.style.display = "block"
  track.dataset.pinned = pinned ? "true" : "false"
  hook.el.dataset.scrollPinned = pinned ? "true" : "false"

  const thumbHeight = Math.max(18, Math.round((state.len / state.total) * trackHeight))
  const travel = Math.max(0, trackHeight - thumbHeight)
  const ratio = maxOffset > 0 ? state.offset / maxOffset : 1
  const top = Math.round(ratio * travel)

  thumb.style.height = `${thumbHeight}px`
  thumb.style.transform = `translateY(${top}px)`
}

function pushScrollDelta(hook, delta) {
  if (!delta) return
  if (hook.target) hook.pushEventTo(hook.target, "scroll", { delta })
  else hook.pushEvent("scroll", { delta })
}

// Feed a finger-travel delta (px; positive = finger moved down) into the
// terminal's wheel pipeline. We accumulate sub-notch travel and only synthesize
// a WheelEvent once a full notch is reached, so __onWheel does all the routing
// (scrollback vs PTY) and per-frame coalescing. Finger-down scrolls into history
// to match the trackpad mapping (deltaY negative = scroll up).
function feedTouchScroll(hook, dyPx) {
  if (!dyPx) return
  hook.__touchWheelAccum = (hook.__touchWheelAccum || 0) - dyPx
  const notches = Math.trunc(hook.__touchWheelAccum / TOUCH_SCROLL_WHEEL_PX)
  if (notches === 0) return
  hook.__touchWheelAccum -= notches * TOUCH_SCROLL_WHEEL_PX
  hook.el.dispatchEvent(
    new WheelEvent("wheel", {
      deltaY: notches * TOUCH_SCROLL_WHEEL_PX,
      deltaMode: 0,
      bubbles: true,
      cancelable: true
    })
  )
}

function stopTouchInertia(hook) {
  if (hook.__inertiaRaf != null) {
    cancelAnimationFrame(hook.__inertiaRaf)
    hook.__inertiaRaf = null
  }
}

// Decay the release velocity over rAF frames, feeding each frame's travel back
// through feedTouchScroll so a flick keeps gliding after the finger lifts.
function startTouchInertia(hook, velocity) {
  stopTouchInertia(hook)
  let v = velocity // px/ms, sign follows finger direction
  if (Math.abs(v) < TOUCH_INERTIA_MIN_VEL) return
  let last = performance.now()
  const step = () => {
    const now = performance.now()
    const dt = now - last
    last = now
    v *= Math.pow(TOUCH_INERTIA_FRICTION, dt / 16)
    if (Math.abs(v) < TOUCH_INERTIA_MIN_VEL) {
      hook.__inertiaRaf = null
      return
    }
    feedTouchScroll(hook, v * dt)
    hook.__inertiaRaf = requestAnimationFrame(step)
  }
  hook.__inertiaRaf = requestAnimationFrame(step)
}

function hasEmulatorScrollback(hook) {
  const state = scrollbarState(hook.scrollbar)
  return Boolean(state && state.total > state.len)
}

// SGR mouse-wheel sequences for programs in the alternate screen (Grok,
// Claude Code, etc.) and for tmux copy-mode scroll. Written as PTY text so
// they bypass the mouse-drag filter above.
function pushWheelToPty(hook, deltaY) {
  const steps = Math.max(1, Math.min(8, Math.ceil(Math.abs(deltaY) / 40)))
  const btn = deltaY < 0 ? 64 : 65
  let seq = ""
  for (let i = 0; i < steps; i += 1) seq += `\x1b[<${btn};1;1M`
  pushText(hook, seq)
}

function afterSelectionSettles(callback) {
  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(() => requestAnimationFrame(callback))
    return
  }

  window.setTimeout(callback, 16)
}

function isCopyShortcut(event) {
  return (event.metaKey || event.ctrlKey) && !event.altKey && event.key?.toLowerCase() === "c"
}

function plainPrimaryMouseDown(event) {
  return (
    event.button === 0 &&
    !event.shiftKey &&
    !event.ctrlKey &&
    !event.altKey &&
    !event.metaKey
  )
}

function terminalPreTarget(hook, target) {
  return Boolean(hook.pre && (target === hook.pre || hook.pre.contains(target)))
}

function terminalCellMetrics(hook) {
  if (!hook.pre) return null

  const styles = window.getComputedStyle(hook.pre)
  const fontSize = parseFloat(styles.fontSize) || 16
  const lineHeight = parseFloat(styles.lineHeight) || fontSize * 1.2
  const measureWidth = hook.measure?.getBoundingClientRect?.().width || 0
  const width = measureWidth > 0 ? measureWidth / 10 : fontSize * 0.6

  return {
    width,
    height: lineHeight,
    paddingLeft: parseFloat(styles.paddingLeft) || 0,
    paddingTop: parseFloat(styles.paddingTop) || 0
  }
}

function clampCell(value, max) {
  return Math.max(0, Math.min(max, value))
}

function terminalCellPointFromEvent(hook, event) {
  const metrics = terminalCellMetrics(hook)
  if (!metrics || !hook.pre) return null

  const rect = hook.pre.getBoundingClientRect()
  const cols = Math.max(1, hook.cols || 1)
  const rows = Math.max(1, hook.rows || 1)
  const x = event.clientX - rect.left - metrics.paddingLeft
  const y = event.clientY - rect.top - metrics.paddingTop

  return {
    col: clampCell(Math.floor(x / metrics.width), cols - 1),
    row: clampCell(Math.floor(y / metrics.height), rows - 1)
  }
}

function renderCellSelection(hook) {
  const layer = hook.selectionLayer
  const metrics = terminalCellMetrics(hook)
  const selection = normalizeCellSelection(hook.__selectionAnchor, hook.__selectionFocus)

  if (!layer || !metrics) return

  layer.innerHTML = ""
  if (!selection) return

  const cols = hook.cols || 0
  for (let row = selection.start.row; row <= selection.end.row; row += 1) {
    const startCol = row === selection.start.row ? selection.start.col : 0
    const endCol = row === selection.end.row ? selection.end.col : cols - 1
    const rect = document.createElement("div")

    rect.style.position = "absolute"
    rect.style.left = `${metrics.paddingLeft + startCol * metrics.width}px`
    rect.style.top = `${metrics.paddingTop + row * metrics.height}px`
    rect.style.width = `${Math.max(1, endCol - startCol + 1) * metrics.width}px`
    rect.style.height = `${metrics.height}px`
    rect.style.background = termVar("--devide-term-selection") || "rgba(137, 180, 250, 0.35)"
    rect.style.borderRadius = "2px"
    layer.appendChild(rect)
  }
}

function clearCellSelection(hook) {
  hook.__selectionAnchor = null
  hook.__selectionFocus = null
  hook.__selectionActive = false
  if (hook.selectionLayer) hook.selectionLayer.innerHTML = ""
  replayPendingFrameIfIdle(hook)
}

function replayPendingFrameIfIdle(hook) {
  if (!hook.__pendingPayload || selectionActiveWithin(hook)) return

  const payload = hook.__pendingPayload
  hook.__pendingPayload = null
  paintAcceptedPayload(hook, payload, hook.__upstreamRender)
}

function hydrateRenderPayload(hook, payload) {
  if (Array.isArray(payload.cells)) return { ok: true, payload }
  if (!Array.isArray(payload.rows)) return { ok: true, payload }

  const cells = Array.isArray(hook.rowsData) ? hook.rowsData.map((row) => row.slice()) : []

  for (const row of payload.rows) {
    const index = row.index
    if (Number.isInteger(index) && Array.isArray(row.cells)) {
      cells[index] = row.cells
    }
  }

  return { ok: true, payload: { ...payload, cells } }
}

function fullFramePayload(payload) {
  return payload?.full_frame === true || payload?.["full_frame?"] === true
}

function frameSequence(payload) {
  const seq = payload?.frame_seq
  const epoch = payload?.frame_epoch
  if (Number.isInteger(seq) && Number.isInteger(epoch)) return { seq, epoch }
  return null
}

function resetFrameTracking(hook, keepSequenced = false) {
  hook.__termFrameBaseline = null
  hook.__termFrameLastSeq = null
  hook.__termFrameEpoch = null
  hook.__termFrameSequenced = keepSequenced && hook.__termFrameSequenced === true
}

function copyCells(rows) {
  return Array.isArray(rows) ? rows.map((row) => (Array.isArray(row) ? row.slice() : row)) : []
}

function setSequencedBaseline(hook, meta, cells) {
  hook.__termFrameSequenced = true
  hook.__termFrameEpoch = meta.epoch
  hook.__termFrameLastSeq = meta.seq
  hook.__termFrameBaseline = copyCells(cells)
}

function terminalDebugEnabled() {
  try {
    return (
      new URLSearchParams(window.location.search).has("termdebug") ||
      window.localStorage?.getItem("devide:terminal-debug") === "1"
    )
  } catch (_) {
    return false
  }
}

function terminalFrameEvent(hook, name, detail = {}) {
  markTerminalPerf(hook, name, detail)
  if (terminalDebugEnabled() && window.console?.debug) {
    console.debug("[devide:terminal]", name, { id: hook?.el?.id, ...detail })
  }
}

function pushRefresh(hook, payload) {
  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "refresh", payload)
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent("refresh", payload)
  }
}

function requestTerminalResync(hook, reason, opts = {}) {
  if (!hook?.el?.isConnected) return
  hook.__resyncReason = hook.__resyncReason || reason
  if (hook.__resyncPending) return

  hook.__resyncPending = true
  terminalFrameEvent(hook, "resync_requested", { reason })

  const fitFirst = opts.fit !== false
  requestAnimationFrame(() => {
    if (!hook.el?.isConnected) return
    if (fitFirst) hook.onWindowResize?.()

    requestAnimationFrame(() => {
      if (!hook.el?.isConnected) return
      const resyncReason = hook.__resyncReason || reason
      hook.__resyncReason = null
      hook.__resyncPending = false
      pushRefresh(hook, { force_full: true, reason: resyncReason })
    })
  })
}

function dropFrameAndResync(hook, payload, reason) {
  terminalFrameEvent(hook, "frame_dropped", {
    reason,
    frame_seq: payload?.frame_seq,
    frame_epoch: payload?.frame_epoch
  })
  requestTerminalResync(hook, reason)
  return null
}

function hydrateSequencedRows(hook, payload, meta) {
  const baseline = hook.__termFrameBaseline
  if (!Array.isArray(baseline)) return { ok: false, reason: "missing_baseline" }
  if (!Array.isArray(payload.rows)) return { ok: false, reason: "missing_rows" }

  const cells = copyCells(baseline)
  for (const row of payload.rows) {
    const index = row?.index
    const rowCells = row?.cells
    const baselineRow = Number.isInteger(index) ? cells[index] : null

    if (!Number.isInteger(index) || index < 0 || index >= cells.length) {
      return { ok: false, reason: "row_index_out_of_range" }
    }

    if (!Array.isArray(rowCells) || !Array.isArray(baselineRow)) {
      return { ok: false, reason: "invalid_row_cells" }
    }

    if (rowCells.length !== baselineRow.length) {
      return { ok: false, reason: "row_shape_mismatch" }
    }

    cells[index] = rowCells
  }

  setSequencedBaseline(hook, meta, cells)
  return { ok: true, payload: { ...payload, cells } }
}

function acceptRenderPayload(hook, payload) {
  const meta = frameSequence(payload)
  const fullFrame = fullFramePayload(payload)

  if (!meta) {
    if (hook.__termFrameSequenced) {
      return dropFrameAndResync(hook, payload, "unsequenced_after_sequenced")
    }

    return hydrateRenderPayload(hook, payload)
  }

  if (fullFrame) {
    if (!Array.isArray(payload.cells)) {
      return dropFrameAndResync(hook, payload, "full_frame_missing_cells")
    }

    setSequencedBaseline(hook, meta, payload.cells)
    terminalFrameEvent(hook, "frame_accepted", {
      kind: "full",
      frame_seq: meta.seq,
      frame_epoch: meta.epoch
    })
    return { ok: true, payload }
  }

  if (!hook.__termFrameSequenced || !Array.isArray(hook.__termFrameBaseline)) {
    return dropFrameAndResync(hook, payload, "incremental_without_baseline")
  }

  if (hook.__termFrameEpoch !== meta.epoch) {
    return dropFrameAndResync(hook, payload, "frame_epoch_mismatch")
  }

  if (meta.seq !== hook.__termFrameLastSeq + 1) {
    return dropFrameAndResync(hook, payload, "frame_seq_gap")
  }

  const hydrated = hydrateSequencedRows(hook, payload, meta)
  if (!hydrated.ok) {
    terminalFrameEvent(hook, "hydrate_failed", {
      reason: hydrated.reason,
      frame_seq: meta.seq,
      frame_epoch: meta.epoch
    })
    return dropFrameAndResync(hook, payload, hydrated.reason)
  }

  terminalFrameEvent(hook, "frame_accepted", {
    kind: "incremental",
    frame_seq: meta.seq,
    frame_epoch: meta.epoch
  })
  return hydrated
}

function paintAcceptedPayload(hook, payload, upstreamRender) {
  if (!payload?.cells) {
    if (payload?.scrollbar) {
      hook.scrollbar = payload.scrollbar
      updateScrollbarChrome(hook, payload.scrollbar)
    }
    return
  }

  if (!hook.__firstRenderMarked) {
    hook.__firstRenderMarked = true
    markTerminalPerf(hook, "first_render", {
      rows: payload.cells?.length || 0,
      cols: payload.cells?.[0]?.length || 0
    })
  }

  // Freeze repaints while the user is selecting text (desktop drag or touch
  // long-press). The vendor render and our RLE pass both rebuild
  // pre.innerHTML, which would clear the selection before the user can copy.
  // Stash the latest frame and replay it once the selection clears (see the
  // selectionchange handler in mounted).
  if (selectionActiveWithin(hook)) {
    hook.__pendingPayload = payload
    return
  }

  hook.__lastRenderPayload = payload
  const paint = () => {
    upstreamRender(payload)
    alignCursorPosition(hook)
    updateScrollbarChrome(hook, payload.scrollbar)
    termLatOnApply(payload)
  }
  const delay = termLatHalfDelay()
  if (delay > 0) {
    window.setTimeout(() => {
      paint()
      hook.__scheduleTerminalLayout?.()
    }, delay)
  } else {
    paint()
    hook.__scheduleTerminalLayout?.()
  }
}

function renderPatched(hook, payload, upstreamRender) {
  if (payload.id !== hook.el.id) return

  const accepted = acceptRenderPayload(hook, payload)
  if (!accepted?.ok) return

  // Keep the link store in step with every ACCEPTED frame, even ones whose
  // paint is deferred behind an active selection — the store then converges
  // with the grid on the deferred repaint. Dropped frames force a resync,
  // whose full frame resets the store.
  updateFileLinkStore(hook.__fileLinks, accepted.payload)
  refreshFileLinkHover(hook)

  paintAcceptedPayload(hook, accepted.payload, upstreamRender)
}

// --- Terminal file links -------------------------------------------------------
//
// Server-detected file paths in terminal output (payload.file_links, scanned
// in PaneWorker). Interaction model is selection-first: plain click and
// drag-select are untouched; only Cmd/Ctrl reveals links (pointer cursor +
// underline overlay) and Cmd/Ctrl+Click — handled in capture phase ahead of
// the selection mousedown — opens the file in a file pane.

function ensureFileLinkLayer(hook) {
  if (hook.__fileLinkLayer?.isConnected) return hook.__fileLinkLayer

  const host = hook.screen || hook.el
  if (!host) return null

  const layer = document.createElement("div")
  layer.setAttribute("aria-hidden", "true")
  Object.assign(layer.style, {
    position: "absolute",
    inset: "0",
    pointerEvents: "none",
    zIndex: "6"
  })
  host.appendChild(layer)
  hook.__fileLinkLayer = layer
  return layer
}

function fileLinkAtEvent(hook, event) {
  if (!terminalPreTarget(hook, event.target)) return null

  const point = terminalCellPointFromEvent(hook, event)
  if (!point) return null

  const link = fileLinkAt(hook.__fileLinks, point.row, point.col)
  return link ? {link, point} : null
}

// Underline the hovered link and show a pointer cursor — but only while
// Cmd/Ctrl is held. Drawn as a pointer-events-none overlay positioned from
// cell metrics (same approach as renderCellSelection), so it works in both
// the DOM and canvas renderers.
function setFileLinkHover(hook, hover) {
  const layer = ensureFileLinkLayer(hook)
  if (!layer) return

  layer.innerHTML = ""
  if (hook.pre) hook.pre.style.cursor = hover ? "pointer" : ""
  if (!hover) return

  const metrics = terminalCellMetrics(hook)
  if (!metrics) return

  const underline = document.createElement("div")
  Object.assign(underline.style, {
    position: "absolute",
    left: `${metrics.paddingLeft + hover.link.from * metrics.width}px`,
    top: `${metrics.paddingTop + (hover.point.row + 1) * metrics.height - 2}px`,
    width: `${(hover.link.to - hover.link.from + 1) * metrics.width}px`,
    height: "1px",
    background: termVar("--devide-term-link") || "rgba(137, 180, 250, 0.9)"
  })
  layer.appendChild(underline)
}

function refreshFileLinkHover(hook, event) {
  if (event) hook.__fileLinkPointerEvent = event

  const pointer = hook.__fileLinkPointerEvent
  if (!pointer || !hook.__fileLinkModifier) {
    setFileLinkHover(hook, null)
    return
  }

  setFileLinkHover(hook, fileLinkAtEvent(hook, pointer))
}

function setFileLinkModifier(hook, held) {
  if (hook.__fileLinkModifier === held) return
  hook.__fileLinkModifier = held
  refreshFileLinkHover(hook)
}

// Frame pane identity: the render stream is keyed "ghostty-<pane_id>" and the
// hook element carries that id. The server treats it as the primary anchor
// hint and falls back to {row, col} geometry mapping.
function fileLinkPaneId(hook) {
  const id = hook.el?.id || ""
  return id.startsWith("ghostty-") ? id.slice("ghostty-".length) : id
}

function installTerminalFileLinks(hook) {
  hook.__fileLinks = new Map()
  hook.__fileLinkModifier = false
  hook.__fileLinkPointerEvent = null

  // Capture phase, registered before the selection mousedown handler: a
  // Cmd/Ctrl+Click on a link cell is consumed here (suppressing selection
  // start and the vendor's focus handling for this event only). Everything
  // else falls through to the selection-first mouse model unchanged.
  hook.__onFileLinkMouseDown = (e) => {
    if (e.button !== 0 || !(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return

    const hover = fileLinkAtEvent(hook, e)
    if (!hover) return

    e.preventDefault()
    e.stopImmediatePropagation()
    setFileLinkHover(hook, null)

    hook.pushEvent("terminal:open_file_link", {
      path: hover.link.path,
      line: hover.link.line ?? null,
      pane_id: fileLinkPaneId(hook),
      row: hover.point.row,
      col: hover.point.col
    })
  }

  hook.__onFileLinkMouseMove = (e) => {
    hook.__fileLinkModifier = e.metaKey || e.ctrlKey
    refreshFileLinkHover(hook, e)
  }

  hook.__onFileLinkMouseLeave = () => {
    hook.__fileLinkPointerEvent = null
    setFileLinkHover(hook, null)
  }

  // Modifier transitions while the pointer rests on a link: reveal/hide the
  // underline without waiting for the next mousemove.
  hook.__onFileLinkModifierKey = (e) => {
    if (e.key === "Meta" || e.key === "Control") {
      setFileLinkModifier(hook, e.type === "keydown" || (e.metaKey || e.ctrlKey))
    }
  }

  hook.__onFileLinkWindowBlur = () => setFileLinkModifier(hook, false)

  hook.el.addEventListener("mousedown", hook.__onFileLinkMouseDown, true)
  hook.el.addEventListener("mousemove", hook.__onFileLinkMouseMove)
  hook.el.addEventListener("mouseleave", hook.__onFileLinkMouseLeave)
  window.addEventListener("keydown", hook.__onFileLinkModifierKey)
  window.addEventListener("keyup", hook.__onFileLinkModifierKey)
  window.addEventListener("blur", hook.__onFileLinkWindowBlur)
}

function teardownTerminalFileLinks(hook) {
  if (hook.__onFileLinkMouseDown) {
    hook.el.removeEventListener("mousedown", hook.__onFileLinkMouseDown, true)
    hook.el.removeEventListener("mousemove", hook.__onFileLinkMouseMove)
    hook.el.removeEventListener("mouseleave", hook.__onFileLinkMouseLeave)
    window.removeEventListener("keydown", hook.__onFileLinkModifierKey)
    window.removeEventListener("keyup", hook.__onFileLinkModifierKey)
    window.removeEventListener("blur", hook.__onFileLinkWindowBlur)
    hook.__onFileLinkMouseDown = null
    hook.__onFileLinkMouseMove = null
    hook.__onFileLinkMouseLeave = null
    hook.__onFileLinkModifierKey = null
    hook.__onFileLinkWindowBlur = null
  }

  hook.__fileLinkLayer?.remove()
  hook.__fileLinkLayer = null
  hook.__fileLinks = null
  hook.__fileLinkPointerEvent = null
  hook.__fileLinkModifier = false
}

function refreshHookTheme(hook) {
  CELL_STYLE_CACHE.clear()
  if (hook.pre) hook.pre.__devideLastHtml = undefined
  patchPreLayout(hook)

  // patchPreLayout re-applies opaque theme colors to the <pre>; in canvas mode
  // re-transparent it on the next paint and force a full repaint with new colors.
  if (canvasRendererEnabled(hook)) {
    hook.__preCanvasPrepared = false
    resetCanvasRenderer(hook)
  }

  if (hook.__lastRenderPayload && hook.__upstreamRender) {
    paintAcceptedPayload(hook, hook.__lastRenderPayload, hook.__upstreamRender)
    return
  }

  if (Array.isArray(hook.rowsData) && hook.rowsData.length > 0 && hook.__upstreamRender && hook.el) {
    paintAcceptedPayload(
      hook,
      {
        id: hook.el.id,
        cells: hook.rowsData,
        cursor: hook.cursor || {},
        scrollbar: hook.scrollbar
      },
      hook.__upstreamRender
    )
    return
  }

  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "refresh", {})
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent("refresh", {})
  }
}

function pendingRawKey(hook) {
  const owner = hook.el.closest("[data-workspace-id][data-session-sid]")
  const workspaceId = owner?.dataset?.workspaceId || hook.el.dataset.workspaceId
  const sessionSid = owner?.dataset?.sessionSid || hook.el.dataset.sessionSid

  if (!workspaceId || !sessionSid) return null
  return `devide:pending-raw:${workspaceId}:${sessionSid}`
}

function pushText(hook, data) {
  if (hook.target) hook.pushEventTo(hook.target, "text", { data })
  else hook.pushEvent("text", { data })
}

// Same payload shape as the vendor's onKeydown, so the server-side key→escape
// encoding (arrows in normal vs application cursor mode, etc.) is shared.
function pushKey(hook, key) {
  const payload = { key, shiftKey: false, ctrlKey: false, altKey: false, metaKey: false }
  if (hook.target) hook.pushEventTo(hook.target, "key", payload)
  else hook.pushEvent("key", payload)
}

// Report whether this viewer's tab is the active one — visible AND holding
// window focus. The server sizes the shared PTY/tmux to the focused viewer, so a
// backgrounded tab or a passive second viewer no longer shrinks the primary
// terminal (see DevIDE.Terminals.SessionOwner). `document.hasFocus()` is true
// for at most one window at a time, so normally exactly one viewer reports
// active. Deduped so only transitions cross the wire.
function reportViewportActive(hook, force = false) {
  if (!hook || !hook.el) return
  const active = document.visibilityState === "visible" && document.hasFocus()
  if (!force && hook.__lastViewportActive === active) return
  hook.__lastViewportActive = active
  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "viewport_active", { active })
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent("viewport_active", { active })
  }
}

function isSizeAuthoritative(hook) {
  return hook.__lastViewportActive === true
}

function pushResizeEvent(hook, cols, rows) {
  // The first size report doubles as the vendor "ready" (disarmed for
  // fit-managed hooks in installScaleFitLayout): the server treats both
  // events identically, but it must only ever see fitted sizes from this
  // path — the vendor's deferred sendReady reads hook.fit (false here) and
  // would report the dataset 80x24, which the SessionOwner then records as
  // the focused viewer's viewport and stamps onto the shared tmux window.
  const event = hook.__sizeReported ? "resize" : "ready"
  hook.__sizeReported = true
  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, event, { cols, rows })
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent(event, { cols, rows })
  }
}

function terminalViewportMetrics(hook) {
  if (!hook?.el) return null

  const rect = hook.el.getBoundingClientRect()
  const styles = window.getComputedStyle(hook.el)
  const padL = parseFloat(styles.paddingLeft) || 0
  const padR = parseFloat(styles.paddingRight) || 0
  const padT = parseFloat(styles.paddingTop) || 0
  const padB = parseFloat(styles.paddingBottom) || 0

  return {
    padL,
    padT,
    availableW: Math.max(0, rect.width - padL - padR),
    availableH: Math.max(0, rect.height - padT - padB)
  }
}

function userDisplayZoom(hook) {
  return hook.__userDisplayZoom ?? 1
}

function clearDisplayScale(hook) {
  if (!hook.pre) return

  hook.pre.style.transform = ""
  hook.pre.style.transformOrigin = ""
  hook.el?.style.removeProperty("--devide-term-display-scale")
  hook.el?.style.removeProperty("--devide-term-display-mode")
  hook.el?.style.removeProperty("--devide-term-display-zoom")
  Object.assign(hook.pre.style, { left: "", top: "", width: "", height: "" })
  patchPreLayout(hook)
}

function applyScaledLayout(hook, baseScale, cols, rows, displayMode) {
  if (!hook.pre || !hook.fitEnabled) return

  const m = terminalCellMetrics(hook)
  const viewport = terminalViewportMetrics(hook)
  if (!m || !viewport) return

  const userZoom = userDisplayZoom(hook)
  const scale = baseScale * userZoom
  const contentW = cols * m.width
  const contentH = rows * m.height

  if (
    viewport.availableW < m.width * 2 ||
    viewport.availableH < m.height * 2 ||
    contentW <= 0 ||
    contentH <= 0
  ) {
    return
  }

  if (Math.abs(scale - 1) < 0.001 && displayMode === "fit") {
    clearDisplayScale(hook)
    hook.el.dataset.displayMode = "fit"
    syncDisplayZoomBadge(hook)
    return
  }

  const scaledW = contentW * scale
  const scaledH = contentH * scale
  const offsetX = viewport.padL + (viewport.availableW - scaledW) / 2
  const offsetY = viewport.padT + (viewport.availableH - scaledH) / 2

  hook.el.style.setProperty("--devide-term-display-scale", String(scale))
  hook.el.style.setProperty("--devide-term-display-zoom", String(userZoom))
  hook.el.dataset.displayMode = displayMode
  hook.pre.style.transform = `scale(${scale})`
  hook.pre.style.transformOrigin = "top left"
  hook.pre.style.left = `${offsetX}px`
  hook.pre.style.top = `${offsetY}px`
  hook.pre.style.width = `${contentW}px`
  hook.pre.style.height = `${contentH}px`
  syncDisplayZoomBadge(hook)
}

function scaleToContainer(hook) {
  if (!hook.pre || !hook.fitEnabled) return

  const m = terminalCellMetrics(hook)
  if (!m) return

  const cols = Math.max(1, hook.cols || parseInt(hook.el.dataset.cols, 10) || 80)
  const rows = Math.max(1, hook.rows || parseInt(hook.el.dataset.rows, 10) || 24)
  const contentW = cols * m.width
  const contentH = rows * m.height
  const viewport = terminalViewportMetrics(hook)
  if (!viewport) return

  if (
    viewport.availableW < m.width * 2 ||
    viewport.availableH < m.height * 2 ||
    contentW <= 0 ||
    contentH <= 0
  ) {
    return
  }

  const baseScale = Math.min(viewport.availableW / contentW, viewport.availableH / contentH)
  applyScaledLayout(hook, baseScale, cols, rows, "scale")
}

function authoritativeFitToContainer(hook) {
  if (!hook.fitEnabled) return

  const m = terminalCellMetrics(hook)
  const viewport = terminalViewportMetrics(hook)
  if (!m || !viewport) return

  if (viewport.availableW < m.width * 2 || viewport.availableH < m.height * 2) return

  const cols = Math.max(2, Math.floor(viewport.availableW / m.width))
  const rows = Math.max(2, Math.floor(viewport.availableH / m.height))
  const userZoom = userDisplayZoom(hook)
  const fitUnchanged = cols === hook.__lastFitCols && rows === hook.__lastFitRows
  const zoomUnchanged = userZoom === hook.__lastAppliedUserZoom

  if (fitUnchanged && zoomUnchanged) return

  if (fitUnchanged) {
    if (userZoom === 1) clearDisplayScale(hook)
    else applyScaledLayout(hook, 1, cols, rows, "zoom")
    hook.el.dataset.displayMode = userZoom === 1 ? "fit" : "zoom"
    hook.__lastAppliedUserZoom = userZoom
    syncDisplayZoomBadge(hook)
    return
  }

  if (userZoom === 1) clearDisplayScale(hook)

  hook.__lastFitCols = cols
  hook.__lastFitRows = rows
  hook.__lastAppliedUserZoom = userZoom
  hook.el.dataset.displayMode = userZoom === 1 ? "fit" : "zoom"
  pushResizeEvent(hook, cols, rows)

  if (userZoom !== 1) applyScaledLayout(hook, 1, cols, rows, "zoom")
  else syncDisplayZoomBadge(hook)
}

function applyTerminalLayout(hook) {
  if (!hook.fitEnabled) return

  if (isSizeAuthoritative(hook)) {
    authoritativeFitToContainer(hook)
  } else {
    scaleToContainer(hook)
  }
}

function syncDisplayZoomBadge(hook) {
  const badge = hook.__displayZoomBadge
  if (!badge) return

  const zoom = userDisplayZoom(hook)
  if (Math.abs(zoom - 1) < 0.001) {
    badge.hidden = true
    badge.textContent = ""
    return
  }

  badge.hidden = false
  badge.textContent = formatDisplayZoomPercent(zoom)
}

function ensureDisplayZoomBadge(hook) {
  if (hook.__displayZoomBadge) return hook.__displayZoomBadge

  const badge = document.createElement("div")
  badge.className = "devide-term-zoom-badge"
  badge.hidden = true
  badge.setAttribute("aria-hidden", "true")
  hook.el.appendChild(badge)
  hook.__displayZoomBadge = badge
  return badge
}

function loadUserDisplayZoom(hook) {
  const surfaceId = terminalSurfaceId(hook)
  hook.__displayZoomSurfaceId = surfaceId
  const storageKey = displayZoomStorageKey(surfaceId, hook.el?.id)
  hook.__displayZoomStorageKey = storageKey
  hook.__userDisplayZoom = loadStoredDisplayZoom(storageKey)
  hook.__lastAppliedUserZoom = hook.__userDisplayZoom
}

function persistUserDisplayZoom(hook) {
  saveStoredDisplayZoom(hook.__displayZoomStorageKey, userDisplayZoom(hook))
}

function adjustUserDisplayZoom(hook, detail = {}) {
  hook.__userDisplayZoom = adjustDisplayZoom(userDisplayZoom(hook), detail)
  persistUserDisplayZoom(hook)
}

function installTerminalDisplayZoom(hook) {
  loadUserDisplayZoom(hook)
  ensureDisplayZoomBadge(hook)
  syncDisplayZoomBadge(hook)

  hook.__onDisplayZoom = (event) => {
    const detail = event?.detail || {}
    if (detail.hookId && hook.el?.id !== detail.hookId) return
    if (detail.surfaceId && hook.__displayZoomSurfaceId !== detail.surfaceId) return
    if (!detail.hookId && !detail.surfaceId && !activeTerminal(hook)) return

    adjustUserDisplayZoom(hook, detail)
    applyTerminalLayout(hook)
  }

  window.addEventListener("devide:terminal-display-zoom", hook.__onDisplayZoom)
}

function installScaleFitLayout(hook) {
  hook.fitEnabled = hook.fit
  // Disable the vendor hook's fit→resize path; we route layout here instead.
  hook.fit = false

  // Disarm the vendor's deferred sendReady (rAF / 50ms timeout / first
  // render). It fires after this function has set hook.fit = false, so its
  // non-fit branch would push "ready" with the dataset default 80x24 —
  // overwriting the fitted resize this layer already reported and condensing
  // the shared tmux window into a corner of the viewport (the recurring
  // "narrow column" bug). For fit-managed hooks the first pushResizeEvent
  // plays the "ready" role instead (see pushResizeEvent).
  if (hook.fitEnabled) hook.readySent = true

  if (hook.resizeObserver) {
    hook.resizeObserver.disconnect()
    hook.resizeObserver = null
  }

  if (hook.pendingFitTimer !== null) {
    clearTimeout(hook.pendingFitTimer)
    hook.pendingFitTimer = null
  }

  const scheduleLayout = () => {
    if (hook.__layoutTimer !== null) clearTimeout(hook.__layoutTimer)
    hook.__layoutTimer = setTimeout(() => {
      hook.__layoutTimer = null
      applyTerminalLayout(hook)
    }, 75)
  }

  hook.__scheduleTerminalLayout = scheduleLayout
  hook.__layoutTimer = null
  hook.onWindowResize = scheduleLayout

  if (typeof ResizeObserver !== "undefined") {
    hook.resizeObserver = new ResizeObserver(scheduleLayout)
    hook.resizeObserver.observe(hook.el)
  }
}

function onViewportAuthorityChanged(hook, wasActive) {
  const nowActive = hook.__lastViewportActive === true
  if (wasActive === nowActive) return

  applyTerminalLayout(hook)

  if (nowActive) {
    requestTerminalResync(hook, "became_size_authority")
  } else {
    requestTerminalResync(hook, "became_size_observer")
  }
}

function terminalSurfaceId(hook) {
  return hook?.el?.closest?.("[data-terminal-surface]")?.id || null
}

function terminalRefitMatches(hook, event) {
  const detail = event?.detail || {}
  const surfaceId = terminalSurfaceId(hook)
  return !detail.surface_id || !surfaceId || detail.surface_id === surfaceId
}

function pushLiveEvent(hook, event, payload) {
  return new Promise((resolve) => {
    hook.pushEvent(event, payload, (reply) => resolve(reply || {}))
  })
}

function activeTerminal(hook) {
  const active = document.activeElement
  if (active === hook.input || active === hook.el || hook.el.contains(active)) return true
  if (active && active !== document.body && active !== document.documentElement) return false

  const wrapper = hook.el.closest("[data-pane-id]")
  if (wrapper?.dataset?.paneActive === "true") return true

  return false
}

function detectPathFormat(hook) {
  const text = hook.pre?.textContent || ""

  if (/Grok Build|Claude Code|OpenCode|Codex|Composer/i.test(text)) return "agent"
  if (/markdown|chat/i.test(text)) return "markdown"

  return "shell"
}

function terminalToast(hook, message, kind = "info", actions = []) {
  const el = document.createElement("div")
  const border = kind === "error" ? "#ef4444" : "#3f3f46"
  const color = kind === "error" ? "#fecaca" : "#e4e4e7"

  Object.assign(el.style, {
    position: "absolute",
    right: "0.5rem",
    bottom: "0.5rem",
    zIndex: "20",
    maxWidth: "min(32rem, calc(100% - 1rem))",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    border: `1px solid ${border}`,
    borderRadius: "4px",
    background: "rgba(24,24,27,0.96)",
    color,
    font: "11px ui-monospace, SFMono-Regular, Menlo, monospace",
    padding: "0.25rem 0.45rem",
    pointerEvents: actions.length > 0 ? "auto" : "none",
    display: "flex",
    alignItems: "center",
    gap: "0.35rem"
  })

  const label = document.createElement("span")
  label.textContent = message
  label.style.overflow = "hidden"
  label.style.textOverflow = "ellipsis"
  el.appendChild(label)

  for (const action of actions) {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = action.label
    Object.assign(button.style, {
      border: "1px solid #52525b",
      borderRadius: "3px",
      background: "#09090b",
      color: "#e4e4e7",
      padding: "0.05rem 0.3rem",
      font: "inherit",
      cursor: "pointer"
    })
    button.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      action.run()
    })
    el.appendChild(button)
  }

  hook.el.appendChild(el)
  window.setTimeout(() => el.remove(), kind === "error" ? 5200 : 4500)
}

function fileToast(hook, file) {
  const rel = file.relative_path || file.path
  terminalToast(hook, `saved ${rel}`, "info", [
    {
      label: "copy",
      run: () => copyTextWithFallback(file.path, hook.input)
    },
    {
      label: "open",
      run: () => hook.pushEvent("annotation:open", { path: rel })
    }
  ])
}

function setDropActive(hook, active) {
  if (!active) {
    hook.__dropOverlay?.remove()
    hook.__dropOverlay = null
    return
  }

  if (hook.__dropOverlay) return

  const overlay = document.createElement("div")
  overlay.textContent = "Drop files to save and paste paths"
  Object.assign(overlay.style, {
    position: "absolute",
    inset: "0.5rem",
    zIndex: "18",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    border: "1px dashed #22c55e",
    borderRadius: "6px",
    background: "rgba(5, 46, 22, 0.36)",
    color: "#bbf7d0",
    font: "12px ui-monospace, SFMono-Regular, Menlo, monospace",
    pointerEvents: "none"
  })

  hook.el.appendChild(overlay)
  hook.__dropOverlay = overlay
}

function drainPendingRawCommand(hook) {
  const key = pendingRawKey(hook)
  if (!key) return

  const command = window.sessionStorage.getItem(key)
  if (!command) return

  window.sessionStorage.removeItem(key)
  window.setTimeout(() => pushText(hook, `${command}\r`), 150)
}

const GhosttyTerminal = {
  ...GhosttyTerminalVendor,

  mounted() {
    markTerminalPerf(this, "mount_start")
    this.__selectionActive = false
    resetFrameTracking(this)
    // Default DOM renderer; canvas is opt-in (see terminal_canvas.js). Canvas
    // falls back to the DOM RLE painter for any frame it can't draw (e.g. before
    // cell metrics are available).
    this.onRenderCells = canvasRendererEnabled(this)
      ? canvasCoalesceEnabled(this)
        ? // Experimental, default-OFF: collapse bursty renders to one paint/frame.
          (pre, rows) =>
            paintCanvasCellsCoalesced(this, pre, rows, terminalCellMetrics, renderCellsRLE)
        : (pre, rows) => {
            if (!paintCanvasCells(this, pre, rows, terminalCellMetrics)) {
              renderCellsRLE(pre, rows)
            }
          }
      : renderCellsRLE

    const originalHandleEvent = this.handleEvent?.bind(this)
    let upstreamRender

    if (originalHandleEvent) {
      this.handleEvent = (event, callback) => {
        if (event === "ghostty:render") {
          upstreamRender = callback
          return
        }

        originalHandleEvent(event, callback)
      }
    }

    GhosttyTerminalVendor.mounted.call(this)
    installScaleFitLayout(this)
    installTerminalDisplayZoom(this)
    markTerminalPerf(this, "mount_end")

    if (originalHandleEvent) {
      this.handleEvent = originalHandleEvent
    }

    if (upstreamRender) {
      this.__upstreamRender = upstreamRender
      this.handleEvent("ghostty:render", (payload) => {
        renderPatched(this, payload, upstreamRender)
      })
    }

    this.handleEvent("terminal:theme", (bundle) => {
      applyServerThemeBundle(bundle)
      refreshHookTheme(this)
    })

    // Background tabs and bfcache restores can leave a terminal fitted to an
    // old DOM rect while the server keeps sending incremental row diffs. On a
    // visible/focused lifecycle edge, refit first, then request a worker-owned
    // full frame after layout settles.
    this.__onLifecycleRefit = (event) => {
      reportViewportActive(this, true)
      if (document.visibilityState !== "visible") return
      terminalFrameEvent(this, "refit_after_visibility", { reason: event?.type || "lifecycle" })
      requestTerminalResync(this, `lifecycle:${event?.type || "unknown"}`)
    }
    document.addEventListener("visibilitychange", this.__onLifecycleRefit)
    window.addEventListener("focus", this.__onLifecycleRefit)
    window.addEventListener("pageshow", this.__onLifecycleRefit)

    this.__onTerminalRefit = (event) => {
      if (!terminalRefitMatches(this, event)) return
      const reason = event?.detail?.reason || "terminal_surface_refit"
      terminalFrameEvent(this, "refit_after_visibility", { reason })
      requestTerminalResync(this, reason)
    }
    window.addEventListener("devide:terminal-refit", this.__onTerminalRefit)

    // Tell the server which viewer is active so the shared PTY/tmux follows the
    // focused tab, not the smallest. Fires on tab show/hide and window
    // focus/blur; the initial forced report seeds the state for an already-
    // visible single viewer that never changes focus.
    this.__onViewportActive = () => {
      const wasActive = this.__lastViewportActive === true
      reportViewportActive(this)
      onViewportAuthorityChanged(this, wasActive)
    }
    document.addEventListener("visibilitychange", this.__onViewportActive)
    window.addEventListener("focus", this.__onViewportActive)
    window.addEventListener("blur", this.__onViewportActive)
    reportViewportActive(this, true)
    applyTerminalLayout(this)

    // Registered before the selection mousedown below so the capture-phase
    // Cmd/Ctrl+Click link handler sees the event first.
    installTerminalFileLinks(this)

    // Desktop drag-select is implemented here as an explicit terminal-cell
    // selection. Browser-native selection is unreliable inside Ghostty's managed
    // <pre>, and the vendor disables its own cell selection when tmux enables
    // mouse tracking. Drawing our own overlay gives visible feedback and copy
    // text without forwarding the drag to tmux.
    this.__onNativeSelectionMouseDown = (e) => {
      if (TOUCH_DEVICE || !plainPrimaryMouseDown(e) || !terminalPreTarget(this, e.target)) return

      const point = terminalCellPointFromEvent(this, e)
      if (!point) return

      this.__nativeSelecting = true
      this.__selectionActive = true
      this.__selectionAnchor = point
      this.__selectionFocus = point
      renderCellSelection(this)
      window.getSelection?.()?.removeAllRanges()
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.__onNativeSelectionMouseMove = (e) => {
      if (!this.__nativeSelecting) return

      const point = terminalCellPointFromEvent(this, e)
      if (!point) return

      this.__selectionFocus = point
      renderCellSelection(this)
      e.preventDefault()
      e.stopImmediatePropagation()
    }

    this.__onNativeSelectionDocumentMouseDown = (e) => {
      if (!this.__selectionActive || terminalPreTarget(this, e.target)) return
      clearCellSelection(this)
    }

    this.__onNativeSelectionMouseUp = (e) => {
      if (!this.__nativeSelecting) return

      const point = terminalCellPointFromEvent(this, e)
      if (point) {
        this.__selectionFocus = point
        renderCellSelection(this)
      }

      afterSelectionSettles(() => {
        this.__nativeSelecting = false
        this.__selectionActive = Boolean(
          normalizeCellSelection(this.__selectionAnchor, this.__selectionFocus) ||
            hasActiveSelectionWithin(this.pre)
        )

        if (!this.__selectionActive) {
          clearCellSelection(this)
          this.input?.focus({ preventScroll: true })
        }

        replayPendingFrameIfIdle(this)
      })
    }

    this.__onNativeSelectionCopy = (e) => {
      const text = selectedTextFromCells(this) || nativeSelectionTextWithin(this.pre)
      if (text === "") return

      e.preventDefault()
      e.stopImmediatePropagation()
      if (e.clipboardData) {
        e.clipboardData.setData("text/plain", text)
      } else {
        copyTextSync(text, this.input)
      }
    }

    this.__onNativeSelectionKeydown = (e) => {
      if (!isCopyShortcut(e)) {
        if (this.__selectionActive) clearCellSelection(this)
        return
      }

      const text = selectedTextFromCells(this) || nativeSelectionTextWithin(this.pre)
      if (text === "") return

      e.preventDefault()
      e.stopImmediatePropagation()
      copyTextSync(text, this.input)
    }

    this.el.addEventListener("mousedown", this.__onNativeSelectionMouseDown, true)
    document.addEventListener("mousedown", this.__onNativeSelectionDocumentMouseDown, true)
    window.addEventListener("mousemove", this.__onNativeSelectionMouseMove, true)
    window.addEventListener("mouseup", this.__onNativeSelectionMouseUp, true)
    this.el.addEventListener("keydown", this.__onNativeSelectionKeydown, true)
    this.input?.addEventListener("keydown", this.__onNativeSelectionKeydown, true)
    document.addEventListener("copy", this.__onNativeSelectionCopy, true)

    // Drag = select, not tmux. The vendor forwards mouse press/motion/release
    // to the program (tmux, in mouse mode), which both eats the drag and would
    // start a tmux-side selection. Drop those so the browser's native text
    // selection wins. We keep every other event (keys, text, wheel-as-text,
    // focus, refresh). Single clicks no longer reach tmux either — an
    // acceptable trade for reliable copy-out; focus for typing still works
    // because the vendor focuses the hidden input directly.
    const pushEventTo = this.pushEventTo && this.pushEventTo.bind(this)
    if (pushEventTo) {
      this.pushEventTo = (target, event, payload, onReply) => {
        if (
          event === "mouse" &&
          payload &&
          (payload.action === "press" ||
            payload.action === "motion" ||
            payload.action === "release")
        ) {
          return
        }
        if (event === "key" || event === "text") {
          return termLatSend(this, event, payload, () =>
            pushEventTo(target, event, payload, onReply)
          )
        }
        return pushEventTo(target, event, payload, onReply)
      }
    }

    const pushEvent = this.pushEvent && this.pushEvent.bind(this)
    if (pushEvent) {
      this.pushEvent = (event, payload, onReply) => {
        if (
          event === "mouse" &&
          payload &&
          (payload.action === "press" ||
            payload.action === "motion" ||
            payload.action === "release")
        ) {
          return
        }
        if (event === "key" || event === "text") {
          return termLatSend(this, event, payload, () =>
            pushEvent(event, payload, onReply)
          )
        }
        return pushEvent(event, payload, onReply)
      }
    }

    // Wheel: scroll Ghostty emulator scrollback when available; otherwise
    // forward SGR mouse-wheel bytes to the PTY so fullscreen TUIs (Grok in the
    // alternate screen) and tmux copy-mode can scroll. Accumulate emulator
    // scroll per-frame so trackpads don't spam the LiveView.
    this.__wheelAccum = 0
    this.__wheelRaf = null
    this.__onWheel = (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault()
        const delta = e.deltaY < 0 ? DISPLAY_ZOOM_STEP : -DISPLAY_ZOOM_STEP
        adjustUserDisplayZoom(this, {delta})
        applyTerminalLayout(this)
        return
      }

      e.preventDefault()

      if (!hasEmulatorScrollback(this)) {
        pushWheelToPty(this, e.deltaY)
        return
      }

      const step =
        e.deltaY === 0
          ? 0
          : Math.sign(e.deltaY) * Math.min(3, Math.max(1, Math.round(Math.abs(e.deltaY) / 48)))

      if (step === 0) return

      this.__wheelAccum += step

      if (this.__wheelRaf != null) return

      this.__wheelRaf = requestAnimationFrame(() => {
        const delta = this.__wheelAccum
        this.__wheelAccum = 0
        this.__wheelRaf = null
        pushScrollDelta(this, delta)
      })
    }
    this.el.addEventListener("wheel", this.__onWheel, { passive: false })

    // Inline long-press selection on touch. The terminal normally focuses its
    // hidden input on tap (to raise the keyboard) and that focus theft + the
    // periodic re-render stop a native selection from ever forming. So: detect
    // a long-press (held >LONGPRESS_MS, little movement), blur the input so iOS
    // targets the <pre>, and swallow the synthesized mousedown that follows so
    // the vendor doesn't re-grab focus. A quick tap behaves as before (focus +
    // keyboard). user-select:text + the repaint-freeze (already set) let the
    // selection survive; iOS's native Copy callout does the copy.
    if (TOUCH_DEVICE) {
      this.__onTouchStart = (e) => {
        const t = e.touches && e.touches[0]
        if (!t) return
        // A second finger joining mid-gesture upgrades it to a two-finger
        // gesture (scrollback). Don't reset the gesture state — just cancel the
        // long-press and re-baseline the tracked touch so the join doesn't emit
        // a spurious delta.
        if (e.touches.length > 1) {
          this.__touchFingers = e.touches.length
          // A second finger is an unambiguous scrollback gesture even if the
          // one-finger phase had latched the arrow d-pad (e.g. output grew past
          // the fold after the drag began).
          this.__scrollbackGesture = true
          clearTimeout(this.__lpTimer)
          this.__longPress = false
          this.__scrollLastY = t.clientY
          this.__scrollLastT = performance.now()
          return
        }
        // A new touch cancels any gliding fling and starts a fresh gesture.
        stopTouchInertia(this)
        this.__touchXY = { x: t.clientX, y: t.clientY }
        this.__touchFingers = 1
        this.__scrollActive = false
        this.__scrollbackGesture = false
        this.__touchWheelAccum = 0
        this.__arrowAccum = 0
        this.__scrollLastY = t.clientY
        this.__scrollLastT = performance.now()
        this.__scrollVel = 0
        this.__longPress = false
        // Blur the input NOW (not mid long-press): dismissing the keyboard
        // shifts layout, and doing that at 400ms cancels iOS's selection gesture
        // (which matures ~500ms). Blurring at touchstart lets the keyboard
        // settle before selection forms. A quick tap re-focuses on touchend.
        const wasFocused = this.input && document.activeElement === this.input
        if (wasFocused) this.input.blur()
        const tag = (e.target && e.target.tagName) || "?"
        hud(`touchstart tgt=${tag} kb=${wasFocused ? 1 : 0}`)
        clearTimeout(this.__lpTimer)
        this.__lpTimer = setTimeout(() => {
          this.__longPress = true
          hud(`lp@${LONGPRESS_MS}`)
        }, LONGPRESS_MS)
      }

      this.__onTouchMove = (e) => {
        const t = e.touches && e.touches[0]
        if (!t || !this.__touchXY) return
        const dx = Math.abs(t.clientX - this.__touchXY.x)
        const dy = Math.abs(t.clientY - this.__touchXY.y)
        if (!this.__longPress && (dx > 10 || dy > 10)) {
          clearTimeout(this.__lpTimer)
          hud("move-cancel")
        }
        // A matured long-press is a text selection drag — leave it alone.
        if (this.__longPress) return

        // Lock the gesture to vertical scrolling once it clearly commits that
        // way. Horizontal-dominant drags fall through to the pane-swipe handler
        // (WorkspaceLeader), so we never claim those.
        if (!this.__scrollActive) {
          if (dy > dx && dy > TOUCH_SCROLL_START_PX) {
            this.__scrollActive = true
            // Latch how this vertical gesture behaves for its lifetime. A
            // one-finger drag scrolls the scrollback (the native mobile
            // expectation) whenever the emulator actually has history to
            // scroll; with no scrollback — an alt-screen TUI like Grok or
            // Claude Code — it stays the arrow d-pad so menu/cursor navigation
            // still works. Two fingers is always a scroll. Latching at commit
            // (not per-move) keeps the gesture from flipping modes as content
            // scrolls past the fold mid-drag.
            this.__scrollbackGesture = this.__touchFingers >= 2 || hasEmulatorScrollback(this)
            this.__scrollLastY = t.clientY
            this.__scrollLastT = performance.now()
          } else {
            return
          }
        }

        const stepDy = t.clientY - this.__scrollLastY
        const now = performance.now()
        const dt = now - this.__scrollLastT
        if (dt > 0) {
          // Light smoothing so a brief mid-drag pause doesn't kill the fling.
          const inst = stepDy / dt
          this.__scrollVel = 0.7 * this.__scrollVel + 0.3 * inst
        }
        this.__scrollLastY = t.clientY
        this.__scrollLastT = now
        if (this.__scrollbackGesture) {
          // Scroll history (or PTY wheel bytes) via the wheel pipeline. Covers
          // two fingers and the one-finger-with-scrollback case latched above.
          feedTouchScroll(this, stepDy)
        } else {
          // One finger, no scrollback: virtual d-pad — a notch of travel sends
          // one arrow key.
          this.__arrowAccum = (this.__arrowAccum || 0) + stepDy
          const steps = Math.trunc(this.__arrowAccum / TOUCH_ARROW_STEP_PX)
          if (steps !== 0) {
            this.__arrowAccum -= steps * TOUCH_ARROW_STEP_PX
            const key = steps > 0 ? "ArrowDown" : "ArrowUp"
            const count = Math.min(Math.abs(steps), 8)
            for (let i = 0; i < count; i += 1) pushKey(this, key)
          }
        }
        // We own the gesture now — stop the page from rubber-band scrolling.
        if (e.cancelable) e.preventDefault()
      }

      this.__onTouchEnd = (e) => {
        // Fingers lifting one at a time: keep the gesture alive until the last
        // finger is up, re-baselining onto whichever touch remains.
        const remaining = e.touches && e.touches.length
        if (remaining > 0) {
          const t = e.touches[0]
          this.__scrollLastY = t.clientY
          this.__scrollLastT = performance.now()
          return
        }
        clearTimeout(this.__lpTimer)
        if (this.__scrollActive) {
          // A scroll is never also a tap-to-focus or a selection. Only a
          // scrollback drag (two-finger, or one-finger with history) carries
          // its release velocity into an inertial fling — a flung d-pad would
          // spray arrow keys.
          this.__scrollActive = false
          if (this.__scrollbackGesture) startTouchInertia(this, this.__scrollVel)
          this.__touchXY = null
          hud("touchend(scroll)")
          return
        }
        if (this.__longPress) {
          // The synthesized mousedown lands shortly after touchend; mark a
          // window to swallow it so focusInput doesn't run.
          this.__suppressFocusUntil = Date.now() + 700
          hud("touchend(lp) arm-md-swallow")
          setTimeout(() => {
            const sel = window.getSelection && window.getSelection()
            const len = sel && !sel.isCollapsed ? sel.toString().length : 0
            const us = this.pre
              ? getComputedStyle(this.pre).webkitUserSelect ||
                getComputedStyle(this.pre).userSelect
              : "?"
            const ae = (document.activeElement && document.activeElement.tagName) || "?"
            const anc =
              sel && sel.rangeCount
                ? (sel.getRangeAt(0).commonAncestorContainer.nodeName || "?")
                : "-"
            hud(`sel=${len} us=${us} ae=${ae} anc=${anc}`)
          }, 350)
        } else {
          hud("touchend(tap)")
        }
        this.__touchXY = null
      }

      this.__onCaptureMousedown = (e) => {
        if (this.__suppressFocusUntil && Date.now() < this.__suppressFocusUntil) {
          this.__suppressFocusUntil = 0
          // Stop the vendor's onPointerDown (focusInput) from running. Do NOT
          // preventDefault — that would cancel the native selection.
          e.stopImmediatePropagation()
          hud("md swallowed")
        }
      }

      this.el.addEventListener("touchstart", this.__onTouchStart, { passive: true })
      // Non-passive: the scroll branch calls preventDefault to suppress the
      // page's rubber-band once it owns the gesture.
      this.el.addEventListener("touchmove", this.__onTouchMove, { passive: false })
      this.el.addEventListener("touchend", this.__onTouchEnd, { passive: true })
      this.el.addEventListener("mousedown", this.__onCaptureMousedown, true)
    }

    // When a selection clears, replay the most recent frame we skipped so the
    // terminal catches up to live output.
    this.__onSelectionChange = () => {
      this.__selectionActive = Boolean(
        normalizeCellSelection(this.__selectionAnchor, this.__selectionFocus) ||
          hasActiveSelectionWithin(this.pre)
      )
      replayPendingFrameIfIdle(this)
    }
    document.addEventListener("selectionchange", this.__onSelectionChange)

    this.__clipboardOpts = {
      element: this.el,
      input: this.input,
      isActive: () => activeTerminal(this),
      sendText: (text) => pushText(this, text),
      uploadImage: (payload) => pushLiveEvent(this, "terminal:paste_image", payload),
      uploadFile: (payload) => pushLiveEvent(this, "terminal:paste_file", payload),
      bracketedPaste: true,
      pathFormat: "auto",
      detectPathFormat: () => detectPathFormat(this),
      onFileSaved: (file) => fileToast(this, file),
      onDragState: (active) => setDropActive(this, active),
      onNotice: (message) => terminalToast(this, message),
      onError: (message) => terminalToast(this, message, "error")
    }
    this.__clipboardCleanup = installTerminalClipboardPaste(this.__clipboardOpts)

    // Right-click menu: the shared ContextMenu hook owns the menu UI; this
    // hook declares the trigger, refreshes selection/pane state just before
    // the menu opens, and executes the client actions it dispatches back.
    // Long-press stays native here — touch copy-out relies on the browser's
    // long-press selection callout.
    this.el.dataset.ctxMenu = "terminal"
    this.el.dataset.ctxLongpress = "off"

    this.__onCtxBeforeOpen = () => {
      this.__ctxSelectionSnapshot =
        selectedTextFromCells(this) || nativeSelectionTextWithin(this.pre) || ""
      this.el.dataset.ctxHasSelection = this.__ctxSelectionSnapshot === "" ? "false" : "true"
      this.el.dataset.ctxTargetId = this.el.id
      const wrapper = this.el.closest("[data-pane-id]")
      if (wrapper?.dataset.paneId) this.el.dataset.ctxPaneId = wrapper.dataset.paneId
    }
    this.el.addEventListener("devide:ctx-before-open", this.__onCtxBeforeOpen)

    this.__onCtxAction = (e) => {
      switch (e?.detail?.action) {
        case "copy": {
          const text = this.__ctxSelectionSnapshot || ""
          if (text !== "") copyTextSync(text, this.input)
          break
        }
        case "paste":
          pasteFromNavigatorClipboard(this.__clipboardOpts).catch((error) =>
            terminalToast(this, error?.message || "clipboard paste failed", "error")
          )
          break
        case "clear":
          pushText(this, "\x0c")
          break
        case "select_all": {
          const sel = window.getSelection?.()
          if (sel && this.pre) {
            const range = document.createRange()
            range.selectNodeContents(this.pre)
            sel.removeAllRanges()
            sel.addRange(range)
          }
          break
        }
      }
    }
    this.el.addEventListener("devide:ctx-action", this.__onCtxAction)

    this.__onTerminalTheme = () => refreshHookTheme(this)
    window.addEventListener("devide:terminal-theme", this.__onTerminalTheme)

    patchPreLayout(this)
    drainPendingRawCommand(this)
  },

  reconnected() {
    // After a LiveView reconnect the server-side PaneWorker/owner reset their
    // view of who is active, but the deduped client reporter still thinks it
    // already sent the current state. Force a re-report so the focused viewer
    // stays authoritative instead of decaying to the largest-viewer fallback.
    resetFrameTracking(this, true)
    reportViewportActive(this, true)
    requestTerminalResync(this, "liveview_reconnected")
  },

  destroyed() {
    if (this.__ghosttyTerminalDestroying) return
    this.__ghosttyTerminalDestroying = true

    if (this.__onTerminalTheme) {
      window.removeEventListener("devide:terminal-theme", this.__onTerminalTheme)
      this.__onTerminalTheme = null
    }

    if (this.__onDisplayZoom) {
      window.removeEventListener("devide:terminal-display-zoom", this.__onDisplayZoom)
      this.__onDisplayZoom = null
    }

    this.__displayZoomBadge?.remove()
    this.__displayZoomBadge = null

    if (this.__onCtxBeforeOpen) {
      this.el.removeEventListener("devide:ctx-before-open", this.__onCtxBeforeOpen)
      this.__onCtxBeforeOpen = null
    }

    if (this.__onCtxAction) {
      this.el.removeEventListener("devide:ctx-action", this.__onCtxAction)
      this.__onCtxAction = null
    }

    if (this.__onSelectionChange) {
      document.removeEventListener("selectionchange", this.__onSelectionChange)
      this.__onSelectionChange = null
    }

    if (this.__onLifecycleRefit) {
      document.removeEventListener("visibilitychange", this.__onLifecycleRefit)
      window.removeEventListener("focus", this.__onLifecycleRefit)
      window.removeEventListener("pageshow", this.__onLifecycleRefit)
      this.__onLifecycleRefit = null
    }

    if (this.__onTerminalRefit) {
      window.removeEventListener("devide:terminal-refit", this.__onTerminalRefit)
      this.__onTerminalRefit = null
    }

    if (this.__onViewportActive) {
      document.removeEventListener("visibilitychange", this.__onViewportActive)
      window.removeEventListener("focus", this.__onViewportActive)
      window.removeEventListener("blur", this.__onViewportActive)
      this.__onViewportActive = null
    }

    if (this.__wheelRaf != null) {
      cancelAnimationFrame(this.__wheelRaf)
      this.__wheelRaf = null
    }

    this.__wheelAccum = 0

    if (this.__onWheel) {
      this.el.removeEventListener("wheel", this.__onWheel)
      this.__onWheel = null
    }

    this.__scrollbarTrack?.remove()
    this.__scrollbarTrack = null
    this.__scrollbarThumb = null

    if (this.__onNativeSelectionMouseDown) {
      this.el.removeEventListener("mousedown", this.__onNativeSelectionMouseDown, true)
      document.removeEventListener("mousedown", this.__onNativeSelectionDocumentMouseDown, true)
      window.removeEventListener("mousemove", this.__onNativeSelectionMouseMove, true)
      window.removeEventListener("mouseup", this.__onNativeSelectionMouseUp, true)
      this.el.removeEventListener("keydown", this.__onNativeSelectionKeydown, true)
      this.input?.removeEventListener("keydown", this.__onNativeSelectionKeydown, true)
      document.removeEventListener("copy", this.__onNativeSelectionCopy, true)
      this.__onNativeSelectionMouseDown = null
      this.__onNativeSelectionMouseMove = null
      this.__onNativeSelectionDocumentMouseDown = null
      this.__onNativeSelectionMouseUp = null
      this.__onNativeSelectionCopy = null
      this.__onNativeSelectionKeydown = null
      this.__nativeSelecting = false
      this.__selectionAnchor = null
      this.__selectionFocus = null
      this.__selectionActive = false
      if (this.selectionLayer) this.selectionLayer.innerHTML = ""
    }

    teardownTerminalFileLinks(this)

    this.__clipboardCleanup?.()
    this.__clipboardCleanup = null
    setDropActive(this, false)

    clearTimeout(this.__lpTimer)
    stopTouchInertia(this)
    if (this.__onTouchStart) {
      this.el.removeEventListener("touchstart", this.__onTouchStart)
      this.el.removeEventListener("touchmove", this.__onTouchMove)
      this.el.removeEventListener("touchend", this.__onTouchEnd)
      this.el.removeEventListener("mousedown", this.__onCaptureMousedown, true)
      this.__onTouchStart = null
    }

    try {
      return GhosttyTerminalVendor.destroyed.call(this)
    } finally {
      this.__ghosttyTerminalDestroying = false
    }
  }
}

export { GhosttyTerminal, renderCellsRLE }
