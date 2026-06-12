// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dev_ide"
import topbar from "../vendor/topbar"
import {GhosttyGovernedTerminal} from "./ghostty_governed_hook"
import {FileViewerHook} from "./file_viewer_hook"
import {PaletteHook} from "./palette_hook"
import {PaneFocusOnClick} from "./pane_focus_hook"
import {GhosttyTerminal} from "./ghostty_terminal"
import {MobileKeyBar} from "./mobile_key_bar"
import {WorkspaceLeader} from "./workspace_leader"
import {SessionPicker} from "./session_picker"
import {PreviewHistory} from "./preview_history"
import {PreviewResizer} from "./preview_resizer"
import {copyTextSync, showClipboardToast} from "./terminal_copy"
import "./terminal_focus"

function markPerf(name, detail = {}) {
  if (window.performance?.mark) {
    window.performance.mark(`devide:${name}`)
  }

  window.dispatchEvent(new CustomEvent("devide:perf", { detail: { name, ...detail } }))

  try {
    if (new URLSearchParams(window.location.search).has("perf")) {
      console.debug("[devide:perf]", name, detail)
    }
  } catch (_) {
    /* location parsing can fail in constrained test contexts */
  }
}

window.__devideMarkPerf = markPerf
markPerf("app_js_loaded")

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Per-tab id so each browser tab/window gets its own terminal session that
// survives refresh. sessionStorage is unique per tab and persists across
// reloads (cleared when the tab closes), so the same tab keeps its session
// while separate windows stay independent instead of converging.
function devideTabId() {
  try {
    let id = window.sessionStorage.getItem("devide:tab")
    if (!id) {
      id = Math.random().toString(36).slice(2, 10)
      window.sessionStorage.setItem("devide:tab", id)
    }
    return id
  } catch (_) {
    return "t" + Math.random().toString(36).slice(2, 8)
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  // DevIDE runs behind OAuth/Caddy on a shared host. A short fallback window
  // causes loaded websocket handshakes to spawn long-poll joins, which looks
  // like a page refresh loop. Give the websocket path time to settle first.
  longPollFallbackMs: 10000,
  params: {_csrf_token: csrfToken, tab_id: devideTabId()},
  hooks: {...colocatedHooks, GhosttyGovernedTerminal, FileViewerHook, PaletteHook, GhosttyTerminal, PaneFocusOnClick, MobileKeyBar, WorkspaceLeader, SessionPicker, PreviewHistory, PreviewResizer},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// OSC52 clipboard bridge: the server extracts a terminal program's
// set-clipboard request (e.g. a vim yank with clipboard=unnamedplus, or tmux
// set-clipboard) from the PTY stream and pushes it here to write to the real
// system clipboard.
//
// The catch: this write fires with no user gesture, and navigator.clipboard
// .writeText requires a focused document + (Safari/Firefox) transient user
// activation — so a fresh OSC52 copy often rejects and the text silently
// vanishes. Instead of swallowing that, when the immediate write fails we stash
// the latest text and flush it on the very next user interaction (the gesture
// that grants activation), so the copy lands as soon as the user touches the
// page. Only the most recent OSC52 payload is kept pending — that matches "the
// last thing the program copied is what you paste".
let __pendingClipboardText = null
let __clipboardGestureArmed = false

function __clipboardWriteSucceeded() {
  __pendingClipboardText = null
  __teardownClipboardGesture()
  showClipboardToast("Copied to clipboard")
}

function __flushPendingClipboard() {
  const text = __pendingClipboardText
  if (text == null) return

  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).then(
      () => __clipboardWriteSucceeded(),
      () => {
        if (copyTextSync(text)) {
          __clipboardWriteSucceeded()
        }
      }
    )
    return
  }

  if (copyTextSync(text)) __clipboardWriteSucceeded()
}

function __armClipboardGesture() {
  if (__clipboardGestureArmed) return
  __clipboardGestureArmed = true
  window.addEventListener("pointerdown", __flushPendingClipboard, true)
  window.addEventListener("click", __flushPendingClipboard, true)
  window.addEventListener("touchend", __flushPendingClipboard, true)
  window.addEventListener("keydown", __flushPendingClipboard, true)
  window.addEventListener("focus", __flushPendingClipboard, true)
  window.addEventListener("copy", __flushPendingClipboard, true)
}

function __teardownClipboardGesture() {
  if (!__clipboardGestureArmed) return
  __clipboardGestureArmed = false
  window.removeEventListener("pointerdown", __flushPendingClipboard, true)
  window.removeEventListener("click", __flushPendingClipboard, true)
  window.removeEventListener("touchend", __flushPendingClipboard, true)
  window.removeEventListener("keydown", __flushPendingClipboard, true)
  window.removeEventListener("focus", __flushPendingClipboard, true)
  window.removeEventListener("copy", __flushPendingClipboard, true)
}

window.addEventListener("phx:clipboard:write", (e) => {
  const text = e.detail?.text
  if (!text) return

  const write = () => {
    if (navigator.clipboard?.writeText) {
      return navigator.clipboard.writeText(text)
    }

    return copyTextSync(text) ? Promise.resolve() : Promise.reject(new Error("copy blocked"))
  }

  write().then(
    () => {
      __pendingClipboardText = null
      __teardownClipboardGesture()
      showClipboardToast("Copied to clipboard")
    },
    (err) => {
      __pendingClipboardText = text
      __armClipboardGesture()
      showClipboardToast("Copy ready — tap anywhere, then paste", { kind: "pending", duration: 6000 })
      if (window.console && console.debug) {
        console.debug("OSC52 clipboard write deferred to next gesture:", err?.name || err)
      }
    }
  )
})

window.addEventListener("phx:devide:reload_preview_iframe", () => {
  const iframe = document.getElementById("preview-agent-iframe")
  if (!iframe) return

  const src = iframe.getAttribute("src")
  if (!src) return

  try {
    iframe.contentWindow?.location.reload()
    return
  } catch (_) {
    // Cross-origin frames can reject direct reload; resetting src is allowed.
  }

  iframe.setAttribute("src", src)
})

window.addEventListener("phx:devide:reload_page", () => {
  window.location.reload()
})

// On coarse-pointer (touch) devices, auto-zoom when a new split is created so
// the user always sees one full-screen pane rather than a cramped tiled layout.
window.addEventListener("phx:devide:pane:split", () => {
  if (!window.matchMedia("(pointer: coarse)").matches) return
  const js = JSON.stringify([["push", {event: "pane:zoom_focused", value: {}}]])
  window.liveSocket.execJS(document.documentElement, js)
})

// Font size via CSS variable — persisted in localStorage.
// Mobile keybar A- / A+ buttons dispatch "devide:font-size" with {delta: ±1}.
// The CSS variable --devide-terminal-line-height is kept in sync (≈ fontSize × 1.31).
let _fontSize = parseInt(localStorage.getItem("devide:font-size") || "13", 10)

function applyFontSize(px) {
  const root = document.documentElement.style
  root.setProperty("--devide-font-size", px + "px")
  root.setProperty("--devide-terminal-line-height", Math.round(px * 1.31) + "px")
}

applyFontSize(_fontSize)

window.addEventListener("devide:font-size", (e) => {
  _fontSize = Math.max(8, Math.min(24, _fontSize + (e.detail?.delta || 0)))
  applyFontSize(_fontSize)
  localStorage.setItem("devide:font-size", _fontSize)
  // Nudge Ghostty panes to re-measure with the new font size
  document.querySelectorAll('[phx-hook="GhosttyTerminal"]').forEach((el) => {
    const orig = el.style.minHeight
    el.style.minHeight = (parseFloat(orig) || 100) + 0.5 + "px"
    requestAnimationFrame(() => { el.style.minHeight = orig || "" })
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// Nudge Ghostty fit terminals on initial entry into raw mode (helps the very
// first default-raw load settle its ResizeObserver measurements).
window.addEventListener("phx:terminal_mode_changed", () => {
  // the event may carry detail; we just need a delay after the view has settled
  setTimeout(() => {
    document.querySelectorAll('[phx-hook="GhosttyTerminal"]').forEach((el) => {
      const orig = el.style.minHeight
      el.style.minHeight = (parseFloat(orig) || 100) + 0.5 + "px"
      requestAnimationFrame(() => { el.style.minHeight = orig || "" })
    })
  }, 50)
}, { once: true })

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
