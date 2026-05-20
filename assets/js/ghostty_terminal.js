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

// True when the user currently has a non-collapsed text selection inside this
// terminal's <pre>. Used to pause repaints on touch so a render (e.g. the tmux
// status-bar clock ticking every second) doesn't wipe the selection mid-copy.
function hasActiveSelectionWithin(pre) {
  if (!pre) return false
  const sel = window.getSelection && window.getSelection()
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return false
  const range = sel.getRangeAt(0)
  return pre.contains(range.commonAncestorContainer)
}

function renderPatched(hook, payload, upstreamRender) {
  if (payload.id !== hook.el.id) return

  // Freeze repaints while the user is selecting text (desktop drag or touch
  // long-press). The vendor render and our RLE pass both rebuild
  // pre.innerHTML, which would clear the selection before the user can copy.
  // Stash the latest frame and replay it once the selection clears (see the
  // selectionchange handler in mounted).
  if (hasActiveSelectionWithin(hook.pre)) {
    hook.__pendingPayload = payload
    return
  }

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
        return pushEventTo(target, event, payload, onReply)
      }
    }

    // Wheel = scroll tmux scrollback. The vendor has no wheel handler, so we
    // translate wheel ticks into SGR mouse-wheel sequences and write them to
    // the PTY as text; tmux (mouse on) interprets them as scroll-up/down. Sent
    // via "text" so it bypasses the mouse-drag filter above.
    this.__onWheel = (e) => {
      e.preventDefault()
      const steps = Math.max(1, Math.min(8, Math.ceil(Math.abs(e.deltaY) / 40)))
      const btn = e.deltaY < 0 ? 64 : 65 // 64 = wheel up, 65 = wheel down
      let seq = ""
      for (let i = 0; i < steps; i += 1) seq += `\x1b[<${btn};1;1M`
      if (this.target) this.pushEventTo(this.target, "text", { data: seq })
      else this.pushEvent("text", { data: seq })
    }
    this.el.addEventListener("wheel", this.__onWheel, { passive: false })

    // When a selection clears, replay the most recent frame we skipped so the
    // terminal catches up to live output.
    this.__onSelectionChange = () => {
      if (this.__pendingPayload && !hasActiveSelectionWithin(this.pre)) {
        const payload = this.__pendingPayload
        this.__pendingPayload = null
        renderPatched(this, payload, upstreamRender)
      }
    }
    document.addEventListener("selectionchange", this.__onSelectionChange)

    patchPreLayout(this)
  },

  destroyed() {
    if (this.__ghosttyTerminalDestroying) return
    this.__ghosttyTerminalDestroying = true

    if (this.__onSelectionChange) {
      document.removeEventListener("selectionchange", this.__onSelectionChange)
      this.__onSelectionChange = null
    }

    if (this.__onWheel) {
      this.el.removeEventListener("wheel", this.__onWheel)
      this.__onWheel = null
    }

    try {
      return GhosttyTerminalVendor.destroyed.call(this)
    } finally {
      this.__ghosttyTerminalDestroying = false
    }
  }
}

export { GhosttyTerminal }
