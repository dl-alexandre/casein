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
 * for quick in-browser checks, `localStorage["devide:terminal-renderer"] =
 * "canvas"`. Falls back to the DOM renderer if a 2D context isn't available.
 */
import {remapColor, termVar} from "./terminal_themes"

export function canvasRendererEnabled(hook) {
  try {
    if (hook?.el?.dataset?.renderer === "canvas") return true
    if (hook?.el?.dataset?.renderer === "dom") return false
    return window.localStorage?.getItem("devide:terminal-renderer") === "canvas"
  } catch (_e) {
    return false
  }
}

// Cell flag bits (mirror DevIDE.Previews / Ghostty.Terminal.Cell).
const BOLD = 1
const ITALIC = 2
const FAINT = 4
const UNDERLINE = 8
const STRIKE = 16
const INVERSE = 32
const OVERLINE = 128

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
  const metrics = metricsFn(hook)
  const ctx = hook.__glyphCtx || (ensureCanvas(hook), hook.__glyphCtx)
  if (!ctx || !metrics || !metrics.width || !metrics.height) {
    // Can't measure yet / no 2D context: fall back to plain text only.
    return false
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
  const bg = termVar("--devide-term-bg") || "#0a0a0a"
  const fg = termVar("--devide-term-fg") || "#e4e4e7"

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
    const [, , , flags0] = row[col]
    // Group a run of cells with identical style (RLE) into one bg fill + text.
    let end = col
    const key = styleKey(row[col])
    while (end < row.length && styleKey(row[end]) === key) end += 1

    const flags = flags0 || 0
    const inverse = flags & INVERSE
    let cellFg = colorString(row[col][1], fg)
    let cellBg = row[col][2] ? colorString(row[col][2], bg) : null
    if (inverse) {
      const tmp = cellBg || bg
      cellBg = cellFg
      cellFg = tmp
    }

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
      ctx.fillText(runText, x, y + ch / 2)
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
  const [, fg, bg, flags] = cell
  return `${fg ? fg.join(",") : ""}|${bg ? bg.join(",") : ""}|${flags || 0}`
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
