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
import {
  applyServerThemeBundle,
  readableTerminalColor,
  remapColor,
  terminalBackgroundRgb,
  terminalForegroundRgb,
  termVar
} from "./terminal_themes"
import {
  BOLD,
  ITALIC,
  OVERLINE,
  effectiveCellFlags,
  resolveInverseColors
} from "./terminal_cell_flags.mjs"
import {
  mouseReportPayload,
  mouseTrackingActive,
  sgrWheelSequence,
  terminalCellFromClientPoint
} from "./terminal_mouse_sgr.mjs"
import {
  BACKEND_KEYS_PAGE,
  POLICY_AGENT,
  allowPlainDragSelect,
  pageKeySteps,
  readFocusedPaneScrollAttrs,
  resolveScrollBackend,
  resolveScrollPolicy,
  scrollDebugEnabled,
  touchUsesWheelPipeline,
  wheelGoesToPty
} from "./terminal_scroll_policy.mjs"
import {
  copyOnSelectText,
  normalizeCellSelection,
  selectedTextFromRows
} from "./terminal_cell_selection.mjs"
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
import {pingWakeLock} from "./wake_lock"
import {computeTerminalLayout} from "./terminal_layout_model.mjs"
import {
  isMobileTerminalLayout,
  latchMobileAuthority,
  rowPinAnchorRow,
  viewportActiveForClient
} from "./terminal_display_layout.mjs"
import {webLinkAt, updateWebLinkStore} from "./terminal_web_links.mjs"

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

  // Ghostty keeps reverse-video as the INVERSE flag rather than pre-swapping
  // colors. Canvas already applied this; the DOM path must too or Grok/Claude
  // selection + focus highlights paint as unstyled text.
  const inverted = resolveInverseColors(
    remapColor(fg),
    remapColor(bg),
    flags || 0,
    terminalForegroundRgb(),
    terminalBackgroundRgb()
  )
  const mappedBg = inverted.bg
  const mappedFg = readableTerminalColor(inverted.fg, mappedBg || terminalBackgroundRgb())

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

// How long a mobile viewer keeps size authority after its last active signal,
// absorbing iOS's rapid hasFocus/soft-keyboard flapping. See reportViewportActive.
const AUTHORITY_LATCH_GRACE_MS = 1200
// Cadence of the level-triggered layout backstop (see reconcilePeriodically). Low
// frequency: one cheap measurement per visible authoritative terminal, only
// acting when the grid is stuck small, so a stranded fit recovers within a
// couple seconds without any per-frame cost.
const FIT_REHEAL_INTERVAL_MS = 2000

// Touch-scroll tuning. A TWO-finger drag translates into the terminal's own
// wheel routing (emulator scrollback vs tmux/alt-screen PTY bytes) so direction
// and per-program handling exactly match a trackpad. WHEEL_PX is one wheel
// "notch" of finger travel; we only emit a notch once that much has
// accumulated, which keeps slow drags proportional instead of jumping a line
// per touchmove event.
const TOUCH_SCROLL_WHEEL_PX = 48
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
        .getPropertyValue("--casein-terminal-line-height")
        .trim() || "17px",
    backgroundColor: termVar("--casein-term-bg") || "#0a0a0a",
    color: termVar("--casein-term-fg") || "#e4e4e7"
  })

  // When a viewer scales the grid to fit (mobile observer / pinch-zoom out), the
  // <pre> floats in a letterboxed frame inside hook.screen. Paint that container
  // with the terminal theme background — via the live CSS var so it tracks theme
  // changes — so the pillarbox bars match the terminal instead of reading as a
  // broken near-black gutter beside a light-theme grid.
  if (hook.screen) {
    hook.screen.style.backgroundColor = "var(--casein-term-bg, #0a0a0a)"
  }

  // Native browser text selection on the pre — desktop and touch alike. The
  // vendor disables it (user-select: none) and relies on its own cell-selection,
  // but that's suppressed whenever the program requests mouse tracking (tmux
  // `mouse on` does this globally), leaving no way to select. With tracking on
  // we use Shift+drag for local select (see mounted); plain gestures reach the
  // PTY so multi-pane TUIs can focus/scroll. Without tracking, plain drag still
  // selects and mouse events stay filtered.
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

function selectedTextFromCells(hook) {
  return selectedTextFromRows(
    hook.rowsData || [],
    hook.cols || 0,
    hook.__selectionAnchor,
    hook.__selectionFocus
  )
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
  track.className = "casein-term-scrollbar"
  track.dataset.pinned = "true"
  track.setAttribute("aria-hidden", "true")

  const thumb = document.createElement("div")
  thumb.className = "casein-term-scrollbar-thumb"
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
      // Preserve the finger cell so alt-screen multi-pane scroll hits the
      // pane under the touch, not a synthetic (0,0) origin.
      clientX: hook.__scrollLastX ?? hook.__touchXY?.x ?? 0,
      clientY: hook.__scrollLastY ?? hook.__touchXY?.y ?? 0,
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
// they bypass the mouse-drag filter above. Coordinates must be the cell under
// the pointer — multi-pane TUIs (Grok chat + side panel) route scroll by hit
// test, so a hard-coded (1,1) only ever scrolls the top-left pane.
function pushWheelToPty(hook, deltaY, point) {
  const seq = sgrWheelSequence(deltaY, point?.col ?? 0, point?.row ?? 0)
  if (seq) pushText(hook, seq)
}

function mouseModeActive(hook) {
  return mouseTrackingActive(hook.mouse)
}

// Synthesize a mouse report at a specific cell. Mirrors the vendor's
// pushMouseEvent payload shape (x/y are the cell encoded as col*10+5 /
// row*20+10) so the server's mode-aware Ghostty.input_mouse encoding is shared.
// Rides the same wrapped pushEventTo/pushEvent as real mouse events, so the
// shouldDropMouseEvent gate (forward only while mouse.tracking is on and we are
// not selecting) still applies.
function pushMouseReport(hook, action, col, row) {
  const payload = mouseReportPayload(action, col, row)
  if (hook.target) hook.pushEventTo(hook.target, "mouse", payload)
  else hook.pushEvent("mouse", payload)
}

// Forward a touch tap as a click (press then release at the tapped cell) so
// mouse-only TUI hotspots — agent login screens, lazygit, htop, menus — are
// reachable on mobile, where the browser never delivers a reliable
// synthesized mouse click. Returns false if the cell can't be resolved.
function forwardTapAsClick(hook, clientX, clientY) {
  const point = terminalCellPointFromEvent(hook, { clientX, clientY })
  if (!point) return false
  pushMouseReport(hook, "press", point.col, point.row)
  pushMouseReport(hook, "release", point.col, point.row)
  return true
}

function currentScrollContext(hook) {
  const pane = readFocusedPaneScrollAttrs(document)
  const hasHistory = hasEmulatorScrollback(hook)
  const tracking = mouseModeActive(hook)
  const policy = resolveScrollPolicy({
    serverPolicy: pane.serverPolicy,
    paneCommand: pane.paneCommand,
    paneRole: pane.paneRole,
    mouseTracking: tracking,
    hasEmulatorScrollback: hasHistory
  })
  const backend = resolveScrollBackend(policy, pane.serverBackend)
  return {
    policy,
    backend,
    hasHistory,
    tracking,
    paneId: pane.paneId
  }
}

function logScrollDebug(hook, label, extra = {}) {
  if (!scrollDebugEnabled()) return
  const ctx = currentScrollContext(hook)
  if (typeof console !== "undefined" && typeof console.debug === "function") {
    console.debug("[devide:termscroll]", label, {...ctx, ...extra})
  }
}

function pushAgentWheel(hook, deltaY, point) {
  const {backend} = currentScrollContext(hook)
  if (backend === BACKEND_KEYS_PAGE) {
    const {key, count} = pageKeySteps(deltaY)
    if (!key || count === 0) return
    for (let i = 0; i < count; i += 1) pushKey(hook, key)
    return
  }
  pushWheelToPty(hook, deltaY, point)
}

function openPaneHistory(hook) {
  const {paneId, policy} = currentScrollContext(hook)
  if (!paneId) return false
  // Dual-layer history: agent alt-screen has no usable emulator scrollback.
  // Alt+wheel opens the tmux capture history drawer for the focused pane.
  if (policy !== POLICY_AGENT) return false
  if (typeof hook.pushEvent === "function") {
    hook.pushEvent("pane:history_open", {"pane-id": paneId})
    return true
  }
  return false
}

// Coalesce trackpad wheel bursts into one PTY write and one terminal hit-test
// per animation frame. terminalCellPointFromEvent performs several computed
// style and layout reads; doing that in the wheel handler forced layout for
// every high-frequency trackpad event even though only the final point in the
// frame is used.
function schedulePtyWheel(hook, deltaY, clientPoint) {
  hook.__ptyWheelAccum = (hook.__ptyWheelAccum || 0) + deltaY
  hook.__ptyWheelClientPoint = clientPoint || hook.__ptyWheelClientPoint || null
  if (hook.__ptyWheelRaf != null) return
  hook.__ptyWheelRaf = requestAnimationFrame(() => {
    const delta = hook.__ptyWheelAccum
    const client = hook.__ptyWheelClientPoint
    hook.__ptyWheelAccum = 0
    hook.__ptyWheelClientPoint = null
    hook.__ptyWheelRaf = null
    const pt = client ? terminalCellPointFromEvent(hook, client) : null
    if (delta) pushAgentWheel(hook, delta, pt)
  })
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
  const measuredRectWidth = hook.measure?.getBoundingClientRect?.().width || 0
  const measureLayoutWidth = hook.measure?.offsetWidth || 0
  const displayScale = parseFloat(
    window.getComputedStyle(hook.el).getPropertyValue("--casein-term-display-scale")
  )
  // getBoundingClientRect includes the scale-frame transform that this layout
  // code applied on the previous pass. Feeding that transformed glyph width
  // back into fitGridForViewport makes SCALE mode self-amplifying: a 0.7
  // overflow guard reads cells as 30% narrower, requests more columns, scales
  // again, and visibly oscillates the shared PTY. Undo only our own display
  // transform here. An outer mobile-pane transform still applies equally to
  // this measurement and the terminal viewport, so it correctly cancels.
  const measureWidth =
    measuredRectWidth > 0 &&
    measureLayoutWidth > 0 &&
    Number.isFinite(displayScale) &&
    displayScale > 0
      ? measuredRectWidth / displayScale
      : measuredRectWidth
  const width = measureWidth > 0 ? measureWidth / 10 : fontSize * 0.6

  return {
    width,
    height: lineHeight,
    paddingLeft: parseFloat(styles.paddingLeft) || 0,
    paddingTop: parseFloat(styles.paddingTop) || 0,
    paddingRight: parseFloat(styles.paddingRight) || 0,
    paddingBottom: parseFloat(styles.paddingBottom) || 0
  }
}

// The <pre> the cells paint into is `inset: 0; box-sizing: border-box` with its
// own padding (vendor: 8px), so its text box is smaller than the container
// terminalViewportMetrics measures. Every cols/rows derivation must subtract
// this, and every scaled content box must add it back.
function preContentPadding(m) {
  return {
    padX: (m?.paddingLeft || 0) + (m?.paddingRight || 0),
    padY: (m?.paddingTop || 0) + (m?.paddingBottom || 0)
  }
}

function terminalCellPointFromEvent(hook, event) {
  const metrics = terminalCellMetrics(hook)
  if (!metrics || !hook.pre) return null

  const rect = hook.pre.getBoundingClientRect()
  const cols = Math.max(1, hook.cols || 1)
  const rows = Math.max(1, hook.rows || 1)
  const rawScale = parseFloat(
    window.getComputedStyle(hook.el).getPropertyValue("--casein-term-display-scale")
  )

  return terminalCellFromClientPoint({
    clientX: event.clientX,
    clientY: event.clientY,
    rectLeft: rect.left,
    rectTop: rect.top,
    cellWidth: metrics.width,
    cellHeight: metrics.height,
    paddingLeft: metrics.paddingLeft,
    paddingTop: metrics.paddingTop,
    scale: Number.isFinite(rawScale) && rawScale > 0 ? rawScale : 1,
    cols,
    rows
  })
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
    rect.style.background = termVar("--casein-term-selection") || "rgba(137, 180, 250, 0.35)"
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

  // The actual paint work, bound to whichever payload is freshest at flush time
  // (so a coalesced trailing flush repaints the NEWEST frame, not a stale one).
  const doPaint = (p) => {
    const started = typeof performance !== "undefined" ? performance.now() : 0
    upstreamRender(p)
    alignCursorPosition(hook)
    updateScrollbarChrome(hook, p.scrollbar)
    const durationMs = typeof performance !== "undefined" ? performance.now() - started : 0
    markTerminalPerf(hook, "paint", {
      duration_ms: Number(durationMs.toFixed(3)),
      renderer: hook.__terminalRenderer || "dom",
      full_frame: fullFramePayload(p),
      rows: p.cells?.length || 0,
      cols: p.cells?.[0]?.length || 0,
      changed_rows: Array.isArray(p.rows) ? p.rows.length : p.cells?.length || 0
    })
    termLatOnApply(p)

    // Agent output is arriving → keep the screen awake (mobile only; self-
    // releases after a quiet spell or when hidden). See wake_lock.js.
    pingWakeLock()

    // Only refit when the grid SHAPE changed (accepted payloads always carry the
    // full hydrated grid, so cols×rows is exact). During pure output the
    // dimensions are stable, so the previous unconditional post-paint layout ran
    // a forced reflow (getBoundingClientRect + getComputedStyle) ~13×/s for
    // nothing. Viewport changes still refit independently via the ResizeObserver.
    const shapeKey = `${p.cells?.[0]?.length || 0}x${p.cells?.length || 0}`
    if (shapeKey !== hook.__lastPaintShapeKey) {
      hook.__lastPaintShapeKey = shapeKey
      reconcileLayout(hook, "grid_shape_changed")
    } else if (rowPinNeedsFollow(hook)) {
      reconcileLayout(hook, "row_pin_follow")
    }
  }

  const delay = termLatHalfDelay()
  if (delay > 0) {
    window.setTimeout(() => doPaint(payload), delay)
    return
  }

  // rAF-coalesce the DOM full-<pre> repaint. The leading frame of an idle→active
  // burst paints immediately, so a single keystroke echo has zero added latency;
  // frames that pile up within one animation frame (bulk output / an LTE burst)
  // collapse to a single trailing repaint of the newest, instead of N full
  // innerHTML rebuilds in one frame.
  hook.__pendingPaintPayload = payload
  if (hook.__paintRaf != null) return

  const lead = hook.__pendingPaintPayload
  hook.__pendingPaintPayload = null
  doPaint(lead)

  hook.__paintRaf = requestAnimationFrame(() => {
    hook.__paintRaf = null
    const trailing = hook.__pendingPaintPayload
    hook.__pendingPaintPayload = null
    if (trailing) doPaint(trailing)
  })
}

function renderPatched(hook, payload, upstreamRender) {
  if (payload.id !== hook.el.id) return

  // Normal vs alternate screen, folded server-side out of the PTY stream
  // (Casein.Terminals.ScreenMode). The layout model branches on it: only a
  // scrolling shell may be row-pinned when the soft keyboard opens, because a
  // full-screen TUI draws to the whole grid and must be told its real size.
  // Carried on every frame, so it is read before the payload is accepted —
  // even a dropped frame reports the current mode correctly.
  if (payload.screen_mode) hook.__screenMode = payload.screen_mode

  const accepted = acceptRenderPayload(hook, payload)
  if (!accepted?.ok) return

  // Keep the link store in step with every ACCEPTED frame, even ones whose
  // paint is deferred behind an active selection — the store then converges
  // with the grid on the deferred repaint. Dropped frames force a resync,
  // whose full frame resets the store.
  updateFileLinkStore(hook.__fileLinks, accepted.payload)
  refreshFileLinkHover(hook)
  updateWebLinkStore(hook.__webLinks, accepted.payload)
  refreshWebLinkHover(hook)

  paintAcceptedPayload(hook, accepted.payload, upstreamRender)
}

// --- Terminal file links -------------------------------------------------------
//
// Server-detected file paths in terminal output (payload.file_links, scanned
// in PaneWorker). Same "web-like" interaction as web links below: the path
// underlines on plain hover, and a plain click opens it on the server's
// default surface for the file type. Drag-select is preserved — the click
// only fires on a mouseup that never dragged past the slop and released on
// the same link. Cmd/Ctrl+Click (resolved on mousedown, ahead of the
// selection handler) also opens; Cmd/Ctrl+Shift+Click forces the other
// surface.

// Shared by file- and web-link plain clicks: a mousedown-to-mouseup drift
// beyond this many pixels is a drag-select, not a click.
const LINK_DRAG_SLOP_PX = 4

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

// Underline the hovered link and show a pointer cursor. Drawn as a
// pointer-events-none overlay positioned from cell metrics (same approach as
// renderCellSelection), so it works in both the DOM and canvas renderers.
function setFileLinkHover(hook, hover) {
  // No-op fast path: clearing when already cleared. On a phone there's no hover
  // pointer, so every accepted frame asks to clear — without this guard that's a
  // per-frame layer build + innerHTML wipe + cursor recompute for nothing.
  if (!hover && !hook.__fileLinkHoverActive) return

  const layer = ensureFileLinkLayer(hook)
  if (!layer) return

  layer.innerHTML = ""
  hook.__fileLinkHoverActive = Boolean(hover)
  applyLinkCursor(hook)
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
    background: termVar("--casein-term-link") || "rgba(137, 180, 250, 0.9)"
  })
  layer.appendChild(underline)
}

function refreshFileLinkHover(hook, event) {
  if (event) hook.__fileLinkPointerEvent = event

  const pointer = hook.__fileLinkPointerEvent
  // Suppress the hover affordance mid drag-select: the user is selecting text,
  // not aiming at a link.
  if (!pointer || hook.__nativeSelecting) {
    setFileLinkHover(hook, null)
    return
  }

  setFileLinkHover(hook, fileLinkAtEvent(hook, pointer))
}

// Frame pane identity: the render stream is keyed "ghostty-<pane_id>" and the
// hook element carries that id. The server treats it as the primary anchor
// hint and falls back to {row, col} geometry mapping.
function fileLinkPaneId(hook) {
  const id = hook.el?.id || ""
  return id.startsWith("ghostty-") ? id.slice("ghostty-".length) : id
}

function openFileLink(hook, hover, mode) {
  hook.pushEvent("terminal:open_file_link", {
    path: hover.link.path,
    line: hover.link.line ?? null,
    pane_id: fileLinkPaneId(hook),
    row: hover.point.row,
    col: hover.point.col,
    mode
  })
}

function installTerminalFileLinks(hook) {
  hook.__fileLinks = new Map()
  hook.__fileLinkPointerEvent = null
  hook.__fileLinkPendingClick = null

  // Capture phase, registered before the selection mousedown handler.
  // Cmd/Ctrl+Click on a link cell is consumed here immediately (suppressing
  // selection start and the vendor's focus handling for this event only).
  // A plain mousedown on a link is only *recorded* — the native selection
  // handler still runs, so a drag that begins on a link selects text as
  // usual; the pending click resolves on mouseup (see below) and is
  // cancelled the moment the pointer drags past the slop.
  hook.__onFileLinkMouseDown = (e) => {
    if (e.button !== 0) {
      hook.__fileLinkPendingClick = null
      return
    }

    // Cmd/Ctrl+Click → open on the server's default surface for the file type.
    // Cmd/Ctrl+Shift+Click → force the other surface. Alt still falls through.
    if ((e.metaKey || e.ctrlKey) && !e.altKey) {
      hook.__fileLinkPendingClick = null
      const hover = fileLinkAtEvent(hook, e)
      if (!hover) return

      e.preventDefault()
      e.stopImmediatePropagation()
      setFileLinkHover(hook, null)
      openFileLink(hook, hover, e.shiftKey ? "flip" : "default")
      return
    }

    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) {
      hook.__fileLinkPendingClick = null
      return
    }

    const hover = fileLinkAtEvent(hook, e)
    hook.__fileLinkPendingClick = hover
      ? {path: hover.link.path, line: hover.link.line ?? null, x: e.clientX, y: e.clientY}
      : null
  }

  hook.__onFileLinkMouseMove = (e) => {
    const pending = hook.__fileLinkPendingClick
    if (
      pending &&
      Math.hypot(e.clientX - pending.x, e.clientY - pending.y) > LINK_DRAG_SLOP_PX
    ) {
      hook.__fileLinkPendingClick = null
    }
    refreshFileLinkHover(hook, e)
  }

  hook.__onFileLinkMouseLeave = () => {
    hook.__fileLinkPointerEvent = null
    setFileLinkHover(hook, null)
  }

  // Window-level (capture) so a release that drifts off the <pre> still
  // resolves the pending click. Opens only when the release lands back on the
  // same link and the pointer never dragged past the slop.
  hook.__onFileLinkMouseUp = (e) => {
    const pending = hook.__fileLinkPendingClick
    hook.__fileLinkPendingClick = null
    if (!pending || e.button !== 0) return
    if (Math.hypot(e.clientX - pending.x, e.clientY - pending.y) > LINK_DRAG_SLOP_PX) return

    const hover = fileLinkAtEvent(hook, e)
    if (!hover || hover.link.path !== pending.path) return
    if ((hover.link.line ?? null) !== pending.line) return

    openFileLink(hook, hover, "default")
  }

  hook.el.addEventListener("mousedown", hook.__onFileLinkMouseDown, true)
  hook.el.addEventListener("mousemove", hook.__onFileLinkMouseMove)
  hook.el.addEventListener("mouseleave", hook.__onFileLinkMouseLeave)
  window.addEventListener("mouseup", hook.__onFileLinkMouseUp, true)
}

function teardownTerminalFileLinks(hook) {
  if (hook.__onFileLinkMouseDown) {
    hook.el.removeEventListener("mousedown", hook.__onFileLinkMouseDown, true)
    hook.el.removeEventListener("mousemove", hook.__onFileLinkMouseMove)
    hook.el.removeEventListener("mouseleave", hook.__onFileLinkMouseLeave)
    window.removeEventListener("mouseup", hook.__onFileLinkMouseUp, true)
    hook.__onFileLinkMouseDown = null
    hook.__onFileLinkMouseMove = null
    hook.__onFileLinkMouseLeave = null
    hook.__onFileLinkMouseUp = null
  }

  hook.__fileLinkLayer?.remove()
  hook.__fileLinkLayer = null
  hook.__fileLinks = null
  hook.__fileLinkPointerEvent = null
  hook.__fileLinkPendingClick = null
  hook.__fileLinkHoverActive = false
  applyLinkCursor(hook)
}

// The <pre> cursor is shared between file-link and web-link hovers, and a cell
// is only ever one or the other. Arbitrate from both flags each refresh so a
// later refresh (web after file) can't clobber the other's pointer cursor.
function applyLinkCursor(hook) {
  if (!hook.pre) return
  hook.pre.style.cursor =
    hook.__fileLinkHoverActive || hook.__webLinkHoverActive ? "pointer" : ""
}

// --- Terminal web links --------------------------------------------------------
//
// Server-detected http(s) URLs in terminal output (payload.web_links, scanned
// in PaneWorker). Same interaction model as file links above: the URL
// underlines on plain hover and a plain click opens it in a new browser tab.
// Drag-select is preserved — the click only fires on a mouseup that never
// dragged past a few pixels from the mousedown, and the release must land on
// the same link.
//
// Cmd/Ctrl+Click opens the URL in the workspace preview pane instead
// (terminal:open_web_link_preview), resolved on mousedown like the file-link
// handler. Shift/Alt combos remain a no-op.

function ensureWebLinkLayer(hook) {
  if (hook.__webLinkLayer?.isConnected) return hook.__webLinkLayer

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
  hook.__webLinkLayer = layer
  return layer
}

function webLinkAtEvent(hook, event) {
  if (!terminalPreTarget(hook, event.target)) return null

  const point = terminalCellPointFromEvent(hook, event)
  if (!point) return null

  const link = webLinkAt(hook.__webLinks, point.row, point.col)
  return link ? {link, point} : null
}

// Underline the hovered URL and show a pointer cursor (no modifier required).
// Drawn as a pointer-events-none overlay positioned from cell metrics, same as
// setFileLinkHover.
function setWebLinkHover(hook, hover) {
  // No-op fast path: clearing when already cleared (see setFileLinkHover).
  if (!hover && !hook.__webLinkHoverActive) return

  const layer = ensureWebLinkLayer(hook)
  if (!layer) return

  layer.innerHTML = ""
  hook.__webLinkHoverActive = Boolean(hover)
  applyLinkCursor(hook)
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
    background: termVar("--casein-term-link") || "rgba(137, 180, 250, 0.9)"
  })
  layer.appendChild(underline)
}

function refreshWebLinkHover(hook, event) {
  if (event) hook.__webLinkPointerEvent = event

  const pointer = hook.__webLinkPointerEvent
  // Suppress the hover affordance mid drag-select: the user is selecting text,
  // not aiming at a link.
  if (!pointer || hook.__nativeSelecting) {
    setWebLinkHover(hook, null)
    return
  }

  setWebLinkHover(hook, webLinkAtEvent(hook, pointer))
}

// Plain click: open the URL in a new browser tab. noopener severs the opener
// reference (the new tab cannot reach window.opener).
function openWebLink(url) {
  if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return
  window.open(url, "_blank", "noopener,noreferrer")
}

// Cmd/Ctrl+Click: open the URL in the workspace preview pane instead of a new
// tab. The server (terminal:open_web_link_preview) validates the URL and drives
// the preview; whether it renders depends on the target allowing embedding.
function openWebLinkPreview(hook, url) {
  if (typeof url !== "string" || !/^https?:\/\//i.test(url)) return

  const payload = {url, pane_id: fileLinkPaneId(hook)}
  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "terminal:open_web_link_preview", payload)
  } else {
    hook.pushEvent("terminal:open_web_link_preview", payload)
  }
}

function installTerminalWebLinks(hook) {
  hook.__webLinks = new Map()
  hook.__webLinkPointerEvent = null
  hook.__webLinkPendingClick = null
  hook.__webLinkHoverActive = false

  // Plain primary mousedown over a URL records a pending click. We do NOT
  // preventDefault/stopImmediatePropagation — the native selection handler
  // (registered after this one) still starts its selection, so a drag that
  // begins on a link selects text as usual. The pending click is cancelled the
  // moment the pointer drags past the slop (see mousemove).
  hook.__onWebLinkMouseDown = (e) => {
    if (e.button !== 0) {
      hook.__webLinkPendingClick = null
      return
    }

    // Cmd/Ctrl+Click → open in the preview pane. Resolved immediately (like
    // the file-link handler): the native selection handler ignores modifier
    // mousedowns, so there is no selection to suppress and no drag to wait
    // out. Shift/Alt are excluded so odd combos fall through to no-op.
    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
      hook.__webLinkPendingClick = null
      const hover = webLinkAtEvent(hook, e)
      if (!hover) return

      e.preventDefault()
      e.stopImmediatePropagation()
      setWebLinkHover(hook, null)
      openWebLinkPreview(hook, hover.link.url)
      return
    }

    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) {
      hook.__webLinkPendingClick = null
      return
    }

    const hover = webLinkAtEvent(hook, e)
    hook.__webLinkPendingClick = hover
      ? {url: hover.link.url, x: e.clientX, y: e.clientY}
      : null
  }

  hook.__onWebLinkMouseMove = (e) => {
    const pending = hook.__webLinkPendingClick
    if (
      pending &&
      Math.hypot(e.clientX - pending.x, e.clientY - pending.y) > LINK_DRAG_SLOP_PX
    ) {
      hook.__webLinkPendingClick = null
    }
    refreshWebLinkHover(hook, e)
  }

  hook.__onWebLinkMouseLeave = () => {
    hook.__webLinkPointerEvent = null
    setWebLinkHover(hook, null)
  }

  // Window-level (capture) so a release that drifts off the <pre> still
  // resolves the pending click. Opens only when the release lands back on the
  // same link and the pointer never dragged past the slop.
  hook.__onWebLinkMouseUp = (e) => {
    const pending = hook.__webLinkPendingClick
    hook.__webLinkPendingClick = null
    if (!pending || e.button !== 0) return
    if (Math.hypot(e.clientX - pending.x, e.clientY - pending.y) > LINK_DRAG_SLOP_PX) return

    const hover = webLinkAtEvent(hook, e)
    if (!hover || hover.link.url !== pending.url) return

    openWebLink(pending.url)
  }

  hook.el.addEventListener("mousedown", hook.__onWebLinkMouseDown, true)
  hook.el.addEventListener("mousemove", hook.__onWebLinkMouseMove)
  hook.el.addEventListener("mouseleave", hook.__onWebLinkMouseLeave)
  window.addEventListener("mouseup", hook.__onWebLinkMouseUp, true)
}

function teardownTerminalWebLinks(hook) {
  if (hook.__onWebLinkMouseDown) {
    hook.el.removeEventListener("mousedown", hook.__onWebLinkMouseDown, true)
    hook.el.removeEventListener("mousemove", hook.__onWebLinkMouseMove)
    hook.el.removeEventListener("mouseleave", hook.__onWebLinkMouseLeave)
    window.removeEventListener("mouseup", hook.__onWebLinkMouseUp, true)
    hook.__onWebLinkMouseDown = null
    hook.__onWebLinkMouseMove = null
    hook.__onWebLinkMouseLeave = null
    hook.__onWebLinkMouseUp = null
  }

  hook.__webLinkLayer?.remove()
  hook.__webLinkLayer = null
  hook.__webLinks = null
  hook.__webLinkPointerEvent = null
  hook.__webLinkPendingClick = null
  hook.__webLinkHoverActive = false
  applyLinkCursor(hook)
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
// terminal (see Casein.Terminals.SessionOwner). `document.hasFocus()` is true
// for at most one window at a time, so normally exactly one viewer reports
// active. Deduped so only transitions cross the wire.
//
// Mobile/PWA: iOS often reports hasFocus()=false while the soft keyboard is up
// (or while the terminal input is focused). That used to leave the phone as a
// permanent scale-to-fit observer — the classic letterboxed "narrow column"
// with a caret stuck on the left. See terminal_display_layout.mjs.
function reportViewportActive(hook, force = false) {
  if (!hook || !hook.el) return
  const mobileLayout = isMobileTerminalLayout()
  const raw = viewportActiveForClient({
    visibilityState: document.visibilityState,
    hasFocus: typeof document.hasFocus === "function" ? document.hasFocus() : true,
    keyboardOpen: document.documentElement.classList.contains("devide-keyboard-open"),
    terminalInputFocused: isTerminalInputFocused(),
    mobileLayout
  })

  const now = performance.now()
  if (raw) hook.__lastActiveAtMs = now

  // Hysteresis: hold mobile authority through a brief hasFocus/keyboard blip so
  // it doesn't demote→observer→re-promote (each round-trip is a tmux reflow the
  // user sees as unstable resizing). See latchMobileAuthority.
  const active = latchMobileAuthority({
    raw,
    mobileLayout,
    wasActive: hook.__lastViewportActive === true,
    sinceActiveMs: now - (hook.__lastActiveAtMs ?? -Infinity),
    graceMs: AUTHORITY_LATCH_GRACE_MS
  })

  if (hook.__authorityLatchTimer) {
    clearTimeout(hook.__authorityLatchTimer)
    hook.__authorityLatchTimer = null
  }
  // While the latch is holding active despite a false raw signal, re-check once
  // the grace window elapses so authority can actually settle to observer if the
  // blip was real (this handler is otherwise only event-driven).
  if (!raw && active) {
    const wait = Math.max(60, AUTHORITY_LATCH_GRACE_MS - (now - hook.__lastActiveAtMs) + 40)
    hook.__authorityLatchTimer = setTimeout(() => {
      hook.__authorityLatchTimer = null
      const wasActive = hook.__lastViewportActive === true
      reportViewportActive(hook)
      onViewportAuthorityChanged(hook, wasActive)
    }, wait)
  }

  if (!force && hook.__lastViewportActive === active) return
  hook.__lastViewportActive = active
  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "viewport_active", { active })
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent("viewport_active", { active })
  }
}

function isTerminalInputFocused() {
  const active = document.activeElement
  return !!(active && active.matches && active.matches('[data-ghostty-input="true"]'))
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

// Scale-to-fit must move the <pre>, caret, selection layer, and hidden input
// together. The vendor places those as siblings under `hook.screen`; transforming
// only the <pre> left the caret parked on the left edge of the letterbox while
// the grid floated in the center (mobile PWA screenshot class).
function ensureScaleFrame(hook) {
  if (!hook?.screen) return null
  if (hook.__scaleFrame?.isConnected) return hook.__scaleFrame

  const frame = document.createElement("div")
  frame.dataset.terminalScaleFrame = "true"
  Object.assign(frame.style, {
    position: "absolute",
    left: "0",
    top: "0",
    width: "100%",
    height: "100%",
    transformOrigin: "top left"
  })

  // Keep scrollbar chrome as a direct child of screen (viewport-fixed, unscaled).
  const track = hook.__scrollbarTrack
  if (track && track.parentNode === hook.screen) {
    hook.screen.insertBefore(frame, track)
  } else {
    hook.screen.appendChild(frame)
  }

  hook.__scaleFrame = frame
  adoptTransformChildren(hook)
  return frame
}

// Everything that paints cells or marks a position inside the grid, in paint
// order: the glyph canvas sits behind the (transparent, in canvas mode) <pre>.
function transformSetNodes(hook) {
  return [hook.__glyphCanvas, hook.pre, hook.selectionLayer, hook.measure, hook.input, hook.cursorEl]
}

/**
 * Pull the whole transform set inside the frame.
 *
 * The frame is the transform host: anything left outside stays put while the
 * grid scales or scrolls — the "caret parked on the left edge of the letterbox"
 * class of bug. This used to be a one-shot snapshot taken when the frame was
 * built, which quietly did nothing for the glyph canvas: the frame is created
 * during the transient scale beat at mount, BEFORE the first paint creates the
 * canvas, so the canvas was always left behind. Adopt on every layout instead,
 * so a lazily-created child cannot miss the boat.
 */
function adoptTransformChildren(hook) {
  const frame = hook.__scaleFrame
  if (!frame?.isConnected) return

  for (const node of transformSetNodes(hook)) {
    if (node && node.parentNode !== frame) frame.appendChild(node)
  }
  // Restore paint order for anything that was already inside.
  const canvas = hook.__glyphCanvas
  if (canvas && frame.firstChild !== canvas) frame.insertBefore(canvas, frame.firstChild)
}

function clearDisplayScale(hook) {
  if (!hook.pre) return

  const frame = hook.__scaleFrame
  if (frame) {
    Object.assign(frame.style, {
      left: "0",
      top: "0",
      width: "100%",
      height: "100%",
      transform: "",
      transformOrigin: "top left"
    })
  }

  hook.pre.style.transform = ""
  hook.pre.style.transformOrigin = ""
  hook.el?.style.removeProperty("--casein-term-display-scale")
  hook.el?.style.removeProperty("--casein-term-display-mode")
  hook.el?.style.removeProperty("--casein-term-display-zoom")
  Object.assign(hook.pre.style, { left: "", top: "", width: "", height: "" })
  patchPreLayout(hook)
}
// ---------------------------------------------------------------------------
// Layout: gather → compute → apply.
//
// The decision lives in terminal_layout_model.mjs and NOTHING here re-derives
// it. These functions only read the DOM into plain numbers, hand them to the
// model, and write the model's answer back out.
// ---------------------------------------------------------------------------

// Row-pinning is default ON (mobile + keyboard-open gates live in the model).
// Opt out with `?rowpin=0` (persisted); `?rowpin=1` re-enables. This stays the
// runtime rollback for the whole row-pin behaviour.
function rowPinEnabled() {
  try {
    if (typeof location !== "undefined" && typeof location.search === "string") {
      const m = /(?:\?|&)rowpin=([01])(?:&|$)/.exec(location.search)
      if (m) {
        try {
          localStorage.setItem("devide:rowpin", m[1])
        } catch (_) {
          /* localStorage unavailable */
        }
        return m[1] === "1"
      }
    }
    if (typeof localStorage !== "undefined" && localStorage.getItem("devide:rowpin") === "0") {
      return false
    }
  } catch (_) {
    /* ignore */
  }
  return true
}

function keyboardOpenNow() {
  return (
    typeof document !== "undefined" &&
    document.documentElement.classList.contains("devide-keyboard-open")
  )
}

// While row-pinned, the grid is scrolled to a fixed window but the cursor keeps
// moving as output arrives. The post-paint refit only fires on a grid SHAPE
// change, which pure output never triggers — so a cursor walking past the bottom
// of the pinned window would leave the operator typing into rows they cannot
// see. Re-run the layout only when the anchor actually leaves the window.
function rowPinNeedsFollow(hook) {
  if (!hook.__rowPinnedApplied) return false
  const win = hook.__rowPinWindow
  if (!win) return false

  const anchor = rowPinAnchorRow({
    cursor: hook.cursor,
    rowsData: hook.rowsData,
    pinnedRows: win.pinnedRows
  })
  return anchor < win.firstRow || anchor > win.lastRow
}

// Read every input the layout decision needs. Returns null when the pane isn't
// measurable yet, which the model would reject anyway.
function gatherLayoutInput(hook, trigger) {
  const m = terminalCellMetrics(hook)
  const viewport = terminalViewportMetrics(hook)
  if (!m || !viewport) return null

  const {padX, padY} = preContentPadding(m)

  return {
    container: {
      availableW: viewport.availableW,
      availableH: viewport.availableH,
      padL: viewport.padL,
      padT: viewport.padT
    },
    cell: {w: m.width, h: m.height, padX, padY},
    renderedGrid: {
      cols: hook.cols || parseInt(hook.el.dataset.cols, 10) || 80,
      rows: hook.rows || parseInt(hook.el.dataset.rows, 10) || 24
    },
    lastFit:
      Number.isFinite(hook.__lastFitCols) && Number.isFinite(hook.__lastFitRows)
        ? {cols: hook.__lastFitCols, rows: hook.__lastFitRows}
        : null,
    lastAppliedUserZoom: hook.__lastAppliedUserZoom,
    pinnedRows: hook.__pinnedRows ?? null,
    cursor: hook.cursor ?? null,
    rowsData: hook.rowsData ?? null,
    authority: isSizeAuthoritative(hook),
    mobile: isMobileTerminalLayout(),
    keyboardOpen: keyboardOpenNow(),
    rowPinAllowed: rowPinEnabled(),
    screenMode: hook.__screenMode ?? "normal",
    userZoom: userDisplayZoom(hook),
    trigger
  }
}

// Write the model's answer to the DOM. The only place that mutates layout.
function applyLayoutResult(hook, result) {
  if (!result || result.noop) return

  // Leaving row-pin: undo the container clip before anything else re-lays out.
  if (hook.__rowPinnedApplied && !result.clipScreen) {
    hook.__rowPinnedApplied = false
    hook.__rowPinWindow = null
    if (hook.screen) hook.screen.style.overflow = ""
  }

  // The canvas renderer draws glyphs at unscaled cell metrics into its own
  // element, so it is only correct while the frame carries no transform. This
  // comes from the model rather than a mode list kept by hand next to the
  // painter — that list was written before row-pinning existed and never grew.
  hook.__canvasSafe = result.canvasSafe !== false

  if (result.frame) {
    const frame = ensureScaleFrame(hook)
    if (frame) {
      Object.assign(frame.style, {
        left: `${result.frame.left}px`,
        top: `${result.frame.top}px`,
        width: `${result.frame.width}px`,
        height: `${result.frame.height}px`,
        transform: result.frame.transform,
        transformOrigin: "top left"
      })
      // The pre fills the frame; cell metrics stay unscaled inside the frame box.
      Object.assign(hook.pre.style, {
        transform: "",
        transformOrigin: "",
        left: "0",
        top: "0",
        width: "100%",
        height: "100%",
        inset: "auto"
      })
    } else {
      // Fallback if screen isn't ready yet (should be rare).
      Object.assign(hook.pre.style, {
        transform: result.frame.transform,
        transformOrigin: "top left",
        left: `${result.frame.left}px`,
        top: `${result.frame.top}px`,
        width: `${result.frame.width}px`,
        height: `${result.frame.height}px`
      })
    }
  } else {
    clearDisplayScale(hook)
  }

  if (result.cssScale == null) hook.el.style.removeProperty("--casein-term-display-scale")
  else hook.el.style.setProperty("--casein-term-display-scale", String(result.cssScale))

  if (result.cssZoom == null) hook.el.style.removeProperty("--casein-term-display-zoom")
  else hook.el.style.setProperty("--casein-term-display-zoom", String(result.cssZoom))

  if (result.clipScreen) {
    if (hook.screen) hook.screen.style.overflow = "hidden"
    hook.__rowPinnedApplied = true
    hook.__rowPinWindow = result.rowPinWindow
  }

  hook.el.dataset.displayMode = result.mode
  adoptTransformChildren(hook)

  if (result.fitAnchor) {
    hook.__lastFitCols = result.fitAnchor.cols
    hook.__lastFitRows = result.fitAnchor.rows
  }
  if (result.pinnedRows != null) hook.__pinnedRows = result.pinnedRows
  if (result.appliedUserZoom != null) hook.__lastAppliedUserZoom = result.appliedUserZoom

  if (result.requestedGrid) {
    pushResizeEvent(hook, result.requestedGrid.cols, result.requestedGrid.rows)
  }

  reportLayoutChange(hook, result)
  syncDisplayZoomBadge(hook)
}

/**
 * The client half of the size-negotiation breadcrumb.
 *
 * SessionOwner already logs `terminal owner size -> WxH (reason)` at info,
 * explicitly because every recurrence of the "my terminal is a narrow column"
 * class had to be reconstructed from a screenshot. But that only records what
 * the SERVER decided; what each viewer asked for, and why, was invisible — the
 * existing client instrumentation goes to console.debug behind `?termdebug`,
 * which is never on when the bug happens.
 *
 * So push it. Only on an actual change of mode or proposed grid, which is rare
 * (a resize, a keyboard toggle, an authority flip) — steady state and the
 * row-pin follow are silent, so this cannot become per-frame chatter.
 */
function reportLayoutChange(hook, result) {
  const grid = result.requestedGrid ?? result.fitAnchor
  const signature = `${result.mode}:${grid?.cols ?? "?"}x${grid?.rows ?? "?"}`
  if (signature === hook.__lastLayoutSignature) return
  hook.__lastLayoutSignature = signature

  const detail = {
    mode: result.mode,
    cols: grid?.cols ?? null,
    rows: grid?.rows ?? null,
    reason: hook.__layoutReason || result.reason,
    authority: isSizeAuthoritative(hook),
    requested: !!result.requestedGrid
  }

  terminalFrameEvent(hook, "layout_change", detail)

  if (hook.target && typeof hook.pushEventTo === "function") {
    hook.pushEventTo(hook.target, "layout_change", detail)
  } else if (typeof hook.pushEvent === "function") {
    hook.pushEvent("layout_change", detail)
  }
}

function applyTerminalLayout(hook, trigger = "event") {
  if (!hook.fitEnabled || !hook.pre) return

  const input = gatherLayoutInput(hook, trigger)
  if (!input) return

  applyLayoutResult(hook, computeTerminalLayout(input))
}

/**
 * The single way to ask for a layout.
 *
 * Every trigger funnels through here — the ResizeObserver, a window resize, the
 * soft keyboard opening, an authority flip, a paint that changed the grid shape
 * or scrolled the cursor out of the row-pin window, a zoom step, and the
 * periodic backstop. Previously each of those reached the layout by its own
 * route (some debounced, some direct, one only via an authority-change
 * early-return that could swallow it), which is how "the keyboard opened" ended
 * up depending on a CSS padding change reaching a ResizeObserver.
 *
 * Coalesced by default: bursts collapse into one pass 75ms later. `immediate`
 * is for triggers that are already rate-limited (the periodic tick) or that
 * must not be deferred behind a pending burst.
 *
 * `reason` is carried into the layout so a size change can be traced — the
 * client half of the server's "terminal owner size -> WxH (reason)" breadcrumb.
 */
function reconcileLayout(hook, reason, {trigger = "event", immediate = false} = {}) {
  if (!hook.fitEnabled) return

  hook.__layoutReason = reason

  if (immediate) {
    if (hook.__layoutTimer !== null) {
      clearTimeout(hook.__layoutTimer)
      hook.__layoutTimer = null
    }
    applyTerminalLayout(hook, trigger)
    return
  }

  if (hook.__layoutTimer !== null) clearTimeout(hook.__layoutTimer)
  hook.__layoutTimer = setTimeout(() => {
    hook.__layoutTimer = null
    applyTerminalLayout(hook, trigger)
  }, 75)
}

// Level-triggered backstop. Every other trigger is edge-driven (ResizeObserver,
// window resize, a paint, an authority flip) and each one can silently miss:
// metrics unavailable, the container momentarily tiny, a pane mounting
// mid-transition, a growth that fires no event at all. A fit that "took" while
// the pane was narrow then reports a too-small grid that nothing re-corrects,
// because the client's own view is self-consistent — the recurring
// "narrow column in the corner" class.
//
// This used to need its own growth-only heuristic (strandedFitReheal) to decide
// whether re-running the fit was safe. It no longer does: the model is a fixed
// point (contract I4), so reconciling when nothing changed is a no-op, and the
// model itself refuses to propose a shrink on a "periodic" trigger. So the tick
// just reconciles.
function reconcilePeriodically(hook) {
  if (typeof document !== "undefined" && document.visibilityState !== "visible") return
  // Observers re-converge on every render; only the authoritative viewer can
  // strand the SHARED grid at a too-small size.
  if (!isSizeAuthoritative(hook)) return

  reconcileLayout(hook, "periodic_reconcile", {trigger: "periodic", immediate: true})
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
  badge.className = "casein-term-zoom-badge"
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
    reconcileLayout(hook, "display_zoom", {immediate: true})
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

  hook.__layoutTimer = null
  hook.onWindowResize = () => reconcileLayout(hook, "window_resize")

  if (typeof ResizeObserver !== "undefined") {
    hook.resizeObserver = new ResizeObserver(() => reconcileLayout(hook, "container_resize"))
    hook.resizeObserver.observe(hook.el)
  }

  // Level-triggered backstop for the edge-triggered fit above: recover a grid
  // stranded small when no resize/refit event landed after the container grew.
  if (hook.fitEnabled && typeof setInterval === "function") {
    if (hook.__fitRehealTimer) clearInterval(hook.__fitRehealTimer)
    hook.__fitRehealTimer = setInterval(() => reconcilePeriodically(hook), FIT_REHEAL_INTERVAL_MS)
  }
}

function onViewportAuthorityChanged(hook, wasActive) {
  const nowActive = hook.__lastViewportActive === true
  if (wasActive === nowActive) return

  reconcileLayout(hook, nowActive ? "became_authority" : "became_observer", {immediate: true})

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

  // Match agent TUIs even when the product title has scrolled off-screen
  // (Grok two-pane views often leave only conversation text in the viewport).
  // Without this, image paste falls back to a shell-quoted absolute path and
  // shows up as a raw `/…/clipboard-image.png` prompt line instead of an
  // `@path` file reference the agent can attach.
  if (/Grok(?:\s+Build)?|Claude(?:\s+Code)?|OpenCode|Codex|Composer/i.test(text)) {
    return "agent"
  }
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
    const useCanvasRenderer = canvasRendererEnabled(this)
    const useCanvasCoalesce = useCanvasRenderer && canvasCoalesceEnabled(this)
    this.__terminalRenderer = useCanvasRenderer
      ? useCanvasCoalesce
        ? "canvas_raf"
        : "canvas"
      : "dom"
    this.onRenderCells = useCanvasRenderer
      ? useCanvasCoalesce
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
    //
    // Also re-evaluate on soft-keyboard open (MobileKeyBar) and terminal input
    // focus — iOS PWA often leaves document.hasFocus() false while typing.
    this.__onViewportActive = () => {
      const wasActive = this.__lastViewportActive === true
      reportViewportActive(this)
      onViewportAuthorityChanged(this, wasActive)
    }
    document.addEventListener("visibilitychange", this.__onViewportActive)
    window.addEventListener("focus", this.__onViewportActive)
    window.addEventListener("blur", this.__onViewportActive)
    window.addEventListener("devide:keyboard-open-changed", this.__onViewportActive)
    // ...and straight to the layout. Routing it only through the authority
    // handler meant an unchanged-authority keyboard toggle never reached the
    // layout on its own, leaving row-pin engagement to depend on the keybar's
    // inset commit changing CSS padding and that reaching the ResizeObserver.
    this.__onKeyboardToggle = () => reconcileLayout(this, "keyboard_toggle", {immediate: true})
    window.addEventListener("devide:keyboard-open-changed", this.__onKeyboardToggle)
    document.addEventListener("focusin", this.__onViewportActive)
    document.addEventListener("focusout", this.__onViewportActive)
    reportViewportActive(this, true)
    reconcileLayout(this, "mount", {immediate: true})

    // Registered before the selection mousedown below so the capture-phase
    // Cmd/Ctrl+Click link handler sees the event first.
    installTerminalFileLinks(this)

    // Web links register their capture-phase mousedown before the selection
    // handler too (so it runs first), but deliberately don't suppress it — a
    // drag still selects; a plain click resolves to "open" on mouseup.
    installTerminalWebLinks(this)

    // Desktop drag-select is implemented here as an explicit terminal-cell
    // selection. Browser-native selection is unreliable inside Ghostty's managed
    // <pre>, and the vendor disables its own cell selection when tmux enables
    // mouse tracking. Drawing our own overlay gives visible feedback and copy
    // text without forwarding the drag to tmux.
    //
    // Agent TUI / mouse-tracking: plain clicks/drags reach the PTY (pane focus,
    // multi-pane scroll hit-test). Local select requires Shift (iTerm convention).
    // Shell without tracking: plain primary drag still selects.
    this.__onNativeSelectionMouseDown = (e) => {
      if (TOUCH_DEVICE || !terminalPreTarget(this, e.target)) return

      const {policy, tracking} = currentScrollContext(this)
      const allowSelect = allowPlainDragSelect(policy, tracking, e.shiftKey)

      if (!allowSelect) return
      if (!plainPrimaryMouseDown(e) && !(e.shiftKey && e.button === 0)) return
      if (e.ctrlKey || e.altKey || e.metaKey) return

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

      // Copy-on-select: desktop cell selection only (touch never sets
      // __nativeSelecting — long-press keeps the system callout). Write the
      // clipboard synchronously inside the mouseup gesture so Safari/async
      // clipboard policies still allow the write; do not defer via rAF.
      // Keep the highlight so the operator can see what was copied.
      const copyText = copyOnSelectText(selectedTextFromCells(this))
      if (copyText != null) {
        copyTextSync(copyText, this.input)
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

    // Mouse press/motion/release: while we own a local cell-selection drag,
    // drop them so tmux/Grok don't start a competing selection. When mouse
    // tracking is active and we are not selecting, forward them so multi-pane
    // TUIs receive clicks (pane focus) and drags. When tracking is off, drop
    // them — Ghostty.input_mouse returns :none anyway, and this keeps the
    // legacy select-first shell UX.
    const shouldDropMouseEvent = (payload) =>
      Boolean(
        payload &&
          (payload.action === "press" ||
            payload.action === "motion" ||
            payload.action === "release") &&
          (this.__nativeSelecting || !mouseModeActive(this))
      )

    const pushEventTo = this.pushEventTo && this.pushEventTo.bind(this)
    if (pushEventTo) {
      this.pushEventTo = (target, event, payload, onReply) => {
        if (event === "mouse" && shouldDropMouseEvent(payload)) {
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
        if (event === "mouse" && shouldDropMouseEvent(payload)) {
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

    // Wheel routing (see terminal_scroll_policy.mjs):
    //  - Ctrl/Meta: display zoom
    //  - Alt+wheel in agent mode: open pane history drawer (dual-layer history)
    //  - agent / no emulator scrollback: SGR (or keys_page) at pointer cell
    //  - shell with scrollback: Ghostty scroll/2, rAF-coalesced
    this.__wheelAccum = 0
    this.__wheelRaf = null
    this.__ptyWheelAccum = 0
    this.__ptyWheelRaf = null
    this.__ptyWheelClientPoint = null
    this.__onWheel = (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault()
        const delta = e.deltaY < 0 ? DISPLAY_ZOOM_STEP : -DISPLAY_ZOOM_STEP
        adjustUserDisplayZoom(this, {delta})
        reconcileLayout(this, "wheel_zoom", {immediate: true})
        return
      }

      e.preventDefault()

      const ctx = currentScrollContext(this)
      logScrollDebug(this, "wheel", {deltaY: e.deltaY, alt: e.altKey})

      if (e.altKey && openPaneHistory(this)) {
        return
      }

      if (wheelGoesToPty(ctx.policy, ctx.hasHistory)) {
        // Copy the scalar coordinates: retaining a browser event until the next
        // frame is unnecessary and some engines aggressively recycle them.
        schedulePtyWheel(this, e.deltaY, {clientX: e.clientX, clientY: e.clientY})
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
          this.__scrollLastX = t.clientX
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
        this.__scrollLastX = t.clientX
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
            // Latch gesture mode for its lifetime. Agent TUIs always use the
            // wheel→PTY pipeline. Shell: one finger scrolls the buffer (history
            // when present, else a harmless no-op); two fingers always scroll
            // scrollback.
            const {policy} = currentScrollContext(this)
            this.__scrollbackGesture = touchUsesWheelPipeline(
              policy,
              this.__touchFingers,
              hasEmulatorScrollback(this)
            )
            this.__scrollLastX = t.clientX
            this.__scrollLastY = t.clientY
            this.__scrollLastT = performance.now()
            logScrollDebug(this, "touch-commit", {
              fingers: this.__touchFingers,
              wheelPipeline: this.__scrollbackGesture
            })
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
        this.__scrollLastX = t.clientX
        this.__scrollLastY = t.clientY
        this.__scrollLastT = now
        if (this.__scrollbackGesture) {
          // Scroll history (or PTY wheel bytes) via the wheel pipeline.
          feedTouchScroll(this, stepDy)
        } else {
          // Shell, one finger, no scrollback: scroll the emulator buffer
          // directly — a no-op when nothing is above the fold. Never the old
          // arrow-key d-pad (an invisible modal surprise the operator couldn't
          // predict) and never PTY wheel bytes (escape-sequence garbage at a
          // bash prompt); explicit arrows live in the mobile key bar. Same sign
          // mapping as feedTouchScroll: finger-down reveals older lines.
          this.__touchWheelAccum = (this.__touchWheelAccum || 0) - stepDy
          const notches = Math.trunc(this.__touchWheelAccum / TOUCH_SCROLL_WHEEL_PX)
          if (notches !== 0) {
            this.__touchWheelAccum -= notches * TOUCH_SCROLL_WHEEL_PX
            pushScrollDelta(this, notches)
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
          this.__scrollLastX = t.clientX
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
        } else if (mouseModeActive(this) && this.__touchXY) {
          // The foreground app enabled mouse tracking (agent login, lazygit,
          // htop, menu TUIs). Forward this tap as a click at the tapped cell so
          // mouse-only hotspots work on touch — the same reports a desktop click
          // sends. Suppress the tap's keyboard-raise: the synthesized mousedown
          // that follows would otherwise pop the soft keyboard on every hotspot
          // tap, and swallowing it also keeps the vendor from emitting a
          // duplicate press (and its window mouseup then early-returns on
          // !pointerActive, so there is no stray release either).
          this.__suppressFocusUntil = Date.now() + 700
          forwardTapAsClick(this, this.__touchXY.x, this.__touchXY.y)
          hud("touchend(tap → click)")
        } else {
          // Double-tap resets display zoom to fit — a one-gesture recovery if
          // the grid ever ends up mis-scaled. Suppress this tap's keyboard-raise
          // so the reset doesn't also pop the soft keyboard.
          const nowT = Date.now()
          const startXY = this.__touchXY
          const prevXY = this.__lastTapXY
          const isDoubleTap =
            startXY &&
            prevXY &&
            nowT - (this.__lastTapAt || 0) < 320 &&
            Math.abs(startXY.x - prevXY.x) < 44 &&
            Math.abs(startXY.y - prevXY.y) < 44
          if (isDoubleTap) {
            this.__lastTapAt = 0
            this.__lastTapXY = null
            this.__suppressFocusUntil = Date.now() + 500
            adjustUserDisplayZoom(this, {reset: true})
            reconcileLayout(this, "zoom_reset", {immediate: true})
            hud("touchend(double-tap → fit)")
          } else {
            this.__lastTapAt = nowT
            this.__lastTapXY = startXY ? {x: startXY.x, y: startXY.y} : null
            hud("touchend(tap)")
          }
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
      window.removeEventListener("devide:keyboard-open-changed", this.__onViewportActive)
      window.removeEventListener("devide:keyboard-open-changed", this.__onKeyboardToggle)
      document.removeEventListener("focusin", this.__onViewportActive)
      document.removeEventListener("focusout", this.__onViewportActive)
      this.__onViewportActive = null
    }

    if (this.__wheelRaf != null) {
      cancelAnimationFrame(this.__wheelRaf)
      this.__wheelRaf = null
    }

    this.__wheelAccum = 0

    if (this.__ptyWheelRaf != null) {
      cancelAnimationFrame(this.__ptyWheelRaf)
      this.__ptyWheelRaf = null
    }

    this.__ptyWheelAccum = 0
    this.__ptyWheelClientPoint = null

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
    teardownTerminalWebLinks(this)

    this.__clipboardCleanup?.()
    this.__clipboardCleanup = null
    setDropActive(this, false)

    clearTimeout(this.__lpTimer)
    if (this.__authorityLatchTimer) {
      clearTimeout(this.__authorityLatchTimer)
      this.__authorityLatchTimer = null
    }
    if (this.__fitRehealTimer) {
      clearInterval(this.__fitRehealTimer)
      this.__fitRehealTimer = null
    }
    if (this.__paintRaf != null) {
      cancelAnimationFrame(this.__paintRaf)
      this.__paintRaf = null
    }
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
