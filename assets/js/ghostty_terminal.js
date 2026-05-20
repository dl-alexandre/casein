/**
 * Extension layer over vendor GhosttyTerminal hook.
 *
 * This keeps local rendering/layout patches off of `assets/vendor/ghostty.js` so
 * dependency refreshes do not silently drop them.
 */
import {GhosttyTerminal as GhosttyTerminalVendor} from "../vendor/ghostty"

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function cellStyles(fg, bg, flags) {
  const styles = []
  const decorations = []

  if (fg) styles.push(`color:rgb(${fg[0]}, ${fg[1]}, ${fg[2]})`)
  if (bg) styles.push(`background:rgb(${bg[0]}, ${bg[1]}, ${bg[2]})`)

  if (flags & 1) styles.push("font-weight:bold")
  if (flags & 2) styles.push("font-style:italic")
  if (flags & 4) styles.push("opacity:0.5")
  if (flags & 8) decorations.push("underline")
  if (flags & 16) decorations.push("line-through")
  if (flags & 128) decorations.push("overline")

  if (decorations.length > 0) {
    styles.push(`text-decoration:${decorations.join(" ")}`)
  }

  return styles
}

function renderCellsRLE(pre, rows) {
  let html = ""
  for (const row of rows) {
    let currentStyle = null
    let currentText = ""

    for (const [char, fg, bg, flags] of row) {
      const styles = cellStyles(fg, bg, flags)
      const style = styles.length > 0 ? styles.join(";") : ""
      const cellChar = char || " "

      if (style === currentStyle) {
        currentText += escapeHtml(cellChar)
      } else {
        if (currentText) {
          html += currentStyle
            ? `<span style="${currentStyle}">${currentText}</span>`
            : currentText
        }

        currentStyle = style
        currentText = escapeHtml(cellChar)
      }
    }

    if (currentText) {
      html += currentStyle ? `<span style="${currentStyle}">${currentText}</span>` : currentText
    }

    html += "\n"
  }

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
    lineHeight: "17px"
  })

  if (TOUCH_DEVICE) {
    hook.pre.style.userSelect = "text"
    hook.pre.style.webkitUserSelect = "text"
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

function renderPatched(hook, payload, upstreamRender) {
  if (payload.id !== hook.el.id) return

  upstreamRender(payload)
  patchPreLayout(hook)
  renderCellsRLE(hook.pre, payload.cells || hook.rowsData)
  alignCursorPosition(hook)
}

const GhosttyTerminal = {
  ...GhosttyTerminalVendor,

  mounted() {
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

    if (originalHandleEvent) {
      this.handleEvent = originalHandleEvent
    }

    if (upstreamRender) {
      this.handleEvent("ghostty:render", (payload) => {
        renderPatched(this, payload, upstreamRender)
      })
    }

    patchPreLayout(this)
  },

  destroyed() {
    if (this.__ghosttyTerminalDestroying) return
    this.__ghosttyTerminalDestroying = true

    try {
      return GhosttyTerminalVendor.destroyed.call(this)
    } finally {
      this.__ghosttyTerminalDestroying = false
    }
  }
}

export { GhosttyTerminal }
