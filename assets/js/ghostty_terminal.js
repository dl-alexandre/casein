/**
 * Extension layer over vendor GhosttyTerminal hook.
 *
 * This keeps local rendering/layout patches off of `assets/vendor/ghostty.js` so
 * dependency refreshes do not silently drop them.
 */
import {GhosttyTerminal as GhosttyTerminalVendor} from "../vendor/ghostty"
import { installTerminalClipboardPaste } from "./terminal_clipboard"
import { copyTextSync, copyTextWithFallback } from "./terminal_copy"

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

function cellStyle(fg, bg, flags) {
  if (!fg && !bg && !flags) return ""

  const key = `${fg ? fg.join(",") : ""}|${bg ? bg.join(",") : ""}|${flags || 0}`
  const cached = CELL_STYLE_CACHE.get(key)
  if (cached !== undefined) return cached

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

  const style = styles.join(";")
  if (CELL_STYLE_CACHE.size > 4096) CELL_STYLE_CACHE.clear()
  CELL_STYLE_CACHE.set(key, style)
  return style
}

function renderCellsRLE(pre, rows) {
  let html = ""
  for (const row of rows) {
    let currentStyle = null
    let currentText = ""

    for (const [char, fg, bg, flags] of row) {
      const style = cellStyle(fg, bg, flags)
      const cellChar = escapeCellChar(char || " ")

      if (style === currentStyle) {
        currentText += cellChar
      } else {
        if (currentText) {
          html += currentStyle
            ? `<span style="${currentStyle}">${currentText}</span>`
            : currentText
        }

        currentStyle = style
        currentText = cellChar
      }
    }

    if (currentText) {
      html += currentStyle ? `<span style="${currentStyle}">${currentText}</span>` : currentText
    }

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

function markTerminalPerf(hook, name, detail = {}) {
  const marker = window.__devideMarkPerf
  if (typeof marker !== "function") return

  marker(`terminal:${name}`, {
    id: hook?.el?.id,
    pane_id: hook?.el?.id?.replace(/^ghostty-/, ""),
    ...detail
  })
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
        .trim() || "17px"
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
    rect.style.background = "rgba(137, 180, 250, 0.35)"
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
  renderPatched(hook, payload, hook.__upstreamRender)
}

function hydrateRenderPayload(hook, payload) {
  if (payload.cells) return payload
  if (!Array.isArray(payload.rows)) return payload

  const cells = Array.isArray(hook.rowsData) ? hook.rowsData.map((row) => row.slice()) : []

  for (const row of payload.rows) {
    const index = row.index
    if (Number.isInteger(index) && Array.isArray(row.cells)) {
      cells[index] = row.cells
    }
  }

  return { ...payload, cells }
}

function renderPatched(hook, payload, upstreamRender) {
  if (payload.id !== hook.el.id) return
  payload = hydrateRenderPayload(hook, payload)
  if (!payload.cells) return

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

  upstreamRender(payload)
  alignCursorPosition(hook)
  updateScrollbarChrome(hook, payload.scrollbar)
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
  if (wrapper?.classList?.contains("ring-primary")) return true

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
    this.onRenderCells = renderCellsRLE

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
        return pushEvent(event, payload, onReply)
      }
    }

    // Wheel scrolls Ghostty's viewport through emulator scrollback (not tmux
    // mouse-wheel bytes). Accumulate per-frame so trackpads don't spam the LV.
    this.__wheelAccum = 0
    this.__wheelRaf = null
    this.__onWheel = (e) => {
      e.preventDefault()

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
        this.__touchXY = { x: t.clientX, y: t.clientY }
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
      }

      this.__onTouchEnd = () => {
        clearTimeout(this.__lpTimer)
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
      this.el.addEventListener("touchmove", this.__onTouchMove, { passive: true })
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

    this.__clipboardCleanup = installTerminalClipboardPaste({
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
    })

    patchPreLayout(this)
    drainPendingRawCommand(this)
  },

  destroyed() {
    if (this.__ghosttyTerminalDestroying) return
    this.__ghosttyTerminalDestroying = true

    if (this.__onSelectionChange) {
      document.removeEventListener("selectionchange", this.__onSelectionChange)
      this.__onSelectionChange = null
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

    this.__clipboardCleanup?.()
    this.__clipboardCleanup = null
    setDropActive(this, false)

    clearTimeout(this.__lpTimer)
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

export { GhosttyTerminal }
