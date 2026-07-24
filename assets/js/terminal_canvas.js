/**
 * Experimental canvas glyph renderer for the terminal hook.
 *
 * The default renderer (`renderCellsRLE`) rebuilds the whole `<pre>.innerHTML`
 * every frame. This paints glyphs to a `<canvas>` instead, repainting only the
 * rows that changed.
 *
 * Layering keeps every existing subsystem working without change:
 *
 *   canvas (behind)  — opaque background + styled glyphs
 *   <pre> (on top)   — transparent bg + transparent plain text; still the
 *                      selection/copy/accessibility layer. The browser's native
 *                      selection highlight (translucent) shows over the canvas,
 *                      and `selectedTextFromCells`/`nativeSelectionTextWithin`
 *                      keep reading real text.
 *   selectionLayer   — custom drag-selection highlight (translucent) over canvas
 *   cursorEl         — DOM cursor, positioned by the vendor as before
 *
 * Because the canvas shares the vendor's cell metrics (`terminalCellMetrics`),
 * glyphs line up with the cursor, selection rects, and the transparent <pre>
 * text used for native selection.
 *
 * Opt-in and default-off: enable per element with `data-renderer="canvas"` or,
 * for quick in-browser checks, `localStorage["casein:terminal-renderer"] =
 * "canvas"`. Falls back to the DOM renderer if a 2D context isn't available.
 */
import {
  readableTerminalColor,
  remapColor,
  terminalBackgroundRgb,
  terminalForegroundRgb,
  termVar
} from "./terminal_themes"
import {
  BOLD,
  FAINT,
  ITALIC,
  OVERLINE,
  STRIKE,
  UNDERLINE,
  effectiveCellFlags,
  resolveInverseColors
} from "./terminal_cell_flags.mjs"
import {preIsScaled, releaseCanvasToDom} from "./terminal_canvas_scale.mjs"

export function canvasRendererEnabled(hook) {
  try {
    if (hook?.el?.dataset?.renderer === "canvas") return true
    if (hook?.el?.dataset?.renderer === "dom") return false
    return window.localStorage?.getItem("casein:terminal-renderer") === "canvas"
  } catch (_e) {
    return false
  }
}

// rAF-coalesced painting (experimental, default-OFF). Independent of the canvas
// flag so it can be verified in isolation. Enable per element with
// `data-coalesce="raf"` or `localStorage["casein:terminal-coalesce"] = "raf"`.
// NOTE: this changes WHEN the canvas paints (next animation frame vs. inline),
// which interacts with the hook's selection-preservation and latency-HUD frame
// correlation. It is intentionally off until verified in a real browser.
export function canvasCoalesceEnabled(hook) {
  try {
    if (hook?.el?.dataset?.coalesce === "raf") return true
    if (hook?.el?.dataset?.coalesce === "off") return false
    return window.localStorage?.getItem("casein:terminal-coalesce") === "raf"
  } catch (_e) {
    return false
  }
}

const scheduleFrame =
  typeof window !== "undefined" && typeof window.requestAnimationFrame === "function"
    ? window.requestAnimationFrame.bind(window)
    : (cb) => setTimeout(cb, 16)

/**
 * rAF-coalesced wrapper around `paintCanvasCells`. A burst of `onRenderCells`
 * calls within one frame (e.g. `cat bigfile`) collapses to a single paint of the
 * LATEST rows, so heavy output cannot block the main thread with N synchronous
 * paints. Takes ownership of the frame; the caller must NOT also paint or fall
 * back. Falls back to `domFallback(pre, rows)` inside the frame only if the
 * canvas still can't draw (e.g. metrics not ready yet).
 */
export function paintCanvasCellsCoalesced(hook, pre, rows, metricsFn, domFallback) {
  hook.__canvasPending = {pre, rows, metricsFn, domFallback}
  if (hook.__canvasRaf != null) return
  hook.__canvasRaf = scheduleFrame(() => {
    hook.__canvasRaf = null
    const p = hook.__canvasPending
    hook.__canvasPending = null
    if (!p) return
    // The hook may have been torn down between schedule and frame.
    if (!hook.el || !hook.el.isConnected) return
    if (!paintCanvasCells(hook, p.pre, p.rows, p.metricsFn) && typeof p.domFallback === "function") {
      p.domFallback(p.pre, p.rows)
    }
  })
}

// Runs of ASCII printables advance exactly one cell each in a monospace font
// and can be drawn as a single string; anything else is drawn per cell.
const ASCII_RUN = /^[\x20-\x7E]*$/

function ensureCanvas(hook) {
  if (hook.__glyphCanvas) return hook.__glyphCanvas

  const canvas = document.createElement("canvas")
  Object.assign(canvas.style, {
    position: "absolute",
    inset: "0",
    width: "100%",
    height: "100%",
    pointerEvents: "none",
    zIndex: "0"
  })

  // First child of the terminal element paints behind the <pre> and overlays.
  hook.el.insertBefore(canvas, hook.el.firstChild)
  hook.__glyphCanvas = canvas
  hook.__glyphCtx = canvas.getContext("2d", {alpha: false})
  return canvas
}

// Make the <pre> a transparent selection/text layer over the canvas. Saved
// inline styles are restored by the caller when switching back to DOM mode.
function prepareTransparentPre(hook, pre) {
  if (hook.__preCanvasPrepared) return
  hook.__preCanvasPrepared = true
  hook.__preSavedColor = pre.style.color
  hook.__preSavedBg = pre.style.backgroundColor
  pre.style.color = "transparent"
  pre.style.backgroundColor = "transparent"
}

function cssFont(ctx, family, size, flags) {
  const weight = flags & BOLD ? "bold " : ""
  const style = flags & ITALIC ? "italic " : ""
  return `${style}${weight}${size}px ${family}`
}

function colorString(rgb, fallback) {
  const mapped = remapColor(rgb)
  if (!mapped) return fallback
  return `rgb(${mapped[0]}, ${mapped[1]}, ${mapped[2]})`
}

function readableColorString(fg, bg, fallback) {
  const mappedBg = remapColor(bg) || terminalBackgroundRgb()
  const mappedFg = readableTerminalColor(remapColor(fg), mappedBg)
  if (!mappedFg) return fallback
  return `rgb(${mappedFg[0]}, ${mappedFg[1]}, ${mappedFg[2]})`
}

// Reset paint caches so the next frame fully repaints (theme/resize changes).
export function resetCanvasRenderer(hook) {
  hook.__canvasRows = null
  hook.__canvasCols = null
  hook.__canvasLastCells = null
}


/**
 * `onRenderCells` replacement: paint `rows` to the canvas and mirror plain text
 * into the (transparent) <pre> for selection. `metricsFn(hook)` returns the
 * vendor cell metrics so glyphs align with cursor/selection.
 */
export function paintCanvasCells(hook, pre, rows, metricsFn) {
  // The canvas can't reproduce the pre's scale-to-fit transform (see
  // terminal_canvas_scale.mjs). Hand scaled/zoomed viewers to the DOM renderer.
  if (preIsScaled(hook)) {
    releaseCanvasToDom(hook)
    return false
  }

  const metrics = metricsFn(hook)
  const ctx = hook.__glyphCtx || (ensureCanvas(hook), hook.__glyphCtx)
  if (!ctx || !metrics || !metrics.width || !metrics.height) {
    // Can't measure yet / no 2D context: fall back to plain text only.
    return false
  }

  // Un-hide the canvas if we previously fell back to the DOM path while scaled.
  if (hook.__glyphCanvas && hook.__glyphCanvas.style.display === "none") {
    hook.__glyphCanvas.style.display = ""
  }
  prepareTransparentPre(hook, pre)

  const canvas = hook.__glyphCanvas
  const rect = pre.getBoundingClientRect()
  const dpr = window.devicePixelRatio || 1
  const cssW = Math.max(1, Math.round(rect.width))
  const cssH = Math.max(1, Math.round(rect.height))

  // Resize backing store on geometry change; that also invalidates the cache.
  if (canvas.__cssW !== cssW || canvas.__cssH !== cssH || canvas.__dpr !== dpr) {
    canvas.width = Math.round(cssW * dpr)
    canvas.height = Math.round(cssH * dpr)
    canvas.__cssW = cssW
    canvas.__cssH = cssH
    canvas.__dpr = dpr
    resetCanvasRenderer(hook)
  }

  const styles = window.getComputedStyle(pre)
  const family = styles.fontFamily || "ui-monospace, monospace"
  const fontSize = parseFloat(styles.fontSize) || 14
  const bg = termVar("--casein-term-bg") || "#0a0a0a"
  const fg = termVar("--casein-term-fg") || "#e4e4e7"

  ctx.save()
  ctx.scale(dpr, dpr)
  ctx.textBaseline = "middle"

  const {width: cw, height: ch, paddingLeft: padL, paddingTop: padT} = metrics
  const prev = hook.__canvasLastCells
  const sameShape = prev && prev.length === rows.length

  // Full clear when the grid shape changed; otherwise only changed rows repaint.
  if (!sameShape) {
    ctx.fillStyle = bg
    ctx.fillRect(0, 0, cssW, cssH)
  }

  let textChanged = false
  for (let r = 0; r < rows.length; r += 1) {
    const row = rows[r]
    if (sameShape && rowsEqual(prev[r], row)) continue
    textChanged = true
    paintRow(ctx, row, r, {cw, ch, padL, padT, family, fontSize, bg, fg})
  }

  ctx.restore()
  hook.__canvasLastCells = rows.map((row) => row.slice())

  // Mirror plain text into the transparent <pre> so native selection + copy keep
  // working. Only touch the DOM when the text actually changed.
  if (textChanged || hook.__canvasLastText === undefined) {
    const text = rows.map(rowText).join("\n")
    if (hook.__canvasLastText !== text) {
      hook.__canvasLastText = text
      pre.textContent = text
    }
  }

  return true
}

function paintRow(ctx, row, r, opts) {
  const {cw, ch, padL, padT, family, fontSize, bg, fg} = opts
  const y = padT + r * ch

  // Clear the row strip to the default background first.
  ctx.fillStyle = bg
  ctx.fillRect(0, y, ctx.canvas.width, ch)

  let col = 0
  while (col < row.length) {
    const [char0, , , flags0] = row[col]
    // Group a run of cells with identical style (RLE) into one bg fill + text.
    let end = col
    const key = styleKey(row[col])
    while (end < row.length && styleKey(row[end]) === key) end += 1

    const flags = effectiveCellFlags(char0, flags0 || 0)
    // Resolve reverse video on RGB tuples before stringifying so DOM and canvas
    // share one inverse policy. Defaults are RGB (not the CSS strings in opts).
    const inverted = resolveInverseColors(
      row[col][1],
      row[col][2],
      flags,
      terminalForegroundRgb(),
      terminalBackgroundRgb()
    )
    const cellFg = readableColorString(inverted.fg, inverted.bg, fg)
    // Inverse always produces a bg (from cell fg or the terminal default), so
    // reverse-video highlights stay opaque even when the source cell had none.
    const cellBg = inverted.bg ? colorString(inverted.bg, bg) : null

    const x = padL + col * cw
    const runW = (end - col) * cw

    if (cellBg) {
      ctx.fillStyle = cellBg
      ctx.fillRect(x, y, runW, ch)
    }

    let runText = ""
    for (let c = col; c < end; c += 1) runText += row[c][0] || " "

    if (runText.trim() !== "") {
      ctx.font = cssFont(ctx, family, fontSize, flags)
      ctx.fillStyle = cellFg
      ctx.globalAlpha = flags & FAINT ? 0.5 : 1
      if (ASCII_RUN.test(runText)) {
        ctx.fillText(runText, x, y + ch / 2)
      } else {
        // Fallback-font glyphs (⏸ ⎿ ☰ …) advance at other-than-one-cell
        // widths, so drawing the run as one string drifts every glyph after
        // them off its column (see the advance-correction comment in
        // ghostty_terminal.js). Pin each glyph to its own cell instead.
        for (let c = col; c < end; c += 1) {
          const cellChar = row[c][0]
          if (cellChar && cellChar.trim() !== "") {
            ctx.fillText(cellChar, padL + c * cw, y + ch / 2)
          }
        }
      }
      ctx.globalAlpha = 1
      paintDecorations(ctx, flags, x, y, runW, ch, cellFg)
    }

    col = end
  }
}

function paintDecorations(ctx, flags, x, y, w, h, color) {
  if (!(flags & (UNDERLINE | STRIKE | OVERLINE))) return
  ctx.strokeStyle = color
  ctx.lineWidth = Math.max(1, Math.round(h / 16))
  ctx.beginPath()
  if (flags & UNDERLINE) line(ctx, x, y + h - ctx.lineWidth, w)
  if (flags & STRIKE) line(ctx, x, y + h / 2, w)
  if (flags & OVERLINE) line(ctx, x, y + ctx.lineWidth, w)
  ctx.stroke()
}

function line(ctx, x, y, w) {
  ctx.moveTo(x, Math.round(y) + 0.5)
  ctx.lineTo(x + w, Math.round(y) + 0.5)
}

function styleKey(cell) {
  const [char, fg, bg, flags] = cell
  return `${fg ? fg.join(",") : ""}|${bg ? bg.join(",") : ""}|${effectiveCellFlags(char, flags || 0)}`
}

function rowText(row) {
  let s = ""
  for (const cell of row) s += cell[0] || " "
  return s
}

function rowsEqual(a, b) {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  for (let i = 0; i < a.length; i += 1) {
    const x = a[i]
    const y = b[i]
    if (x[0] !== y[0] || (x[3] || 0) !== (y[3] || 0)) return false
    if (!colorEqual(x[1], y[1]) || !colorEqual(x[2], y[2])) return false
  }
  return true
}

function colorEqual(a, b) {
  if (a === b) return true
  if (!a || !b) return false
  return a[0] === b[0] && a[1] === b[1] && a[2] === b[2]
}
