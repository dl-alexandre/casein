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
import {TerminalHook} from "./terminal_hook"
import {GhosttyGovernedTerminal} from "./ghostty_governed_hook"
import {FileViewerHook} from "./file_viewer_hook"
import {PaletteHook} from "./palette_hook"
import {SplitResizer} from "./split_resizer_hook"
import {PaneFocusOnClick} from "./pane_focus_hook"
import {GhosttyTerminal} from "./ghostty_terminal"
import {MobileKeyBar} from "./mobile_key_bar"
import "@xterm/xterm/css/xterm.css"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, TerminalHook, GhosttyGovernedTerminal, FileViewerHook, PaletteHook, GhosttyTerminal, SplitResizer, PaneFocusOnClick, MobileKeyBar},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// ------------------------------------------------------------------
// Raw terminal split layout persistence (Option B - decoupled)
// The PaneLayoutPersistence hook lives on the utility bar (sibling to the
// Ghostty panes) so it never interferes with GhosttyTerminal hook init.
// Saves are driven by server push_event (global listener here is belt-and-
// suspenders). Restores are server-driven request + hook reply (with rAF
// deferral so child Ghostty components finish fit/terminal_ready first).
// This is what finally made the raw shell prompt reliable on enter + reconnect.
// ------------------------------------------------------------------
const PANE_LAYOUT_KEY_PREFIX = "devide:pane_layout:"

function getSavedPaneLayout(wsId = "default") {
  const key = `${PANE_LAYOUT_KEY_PREFIX}${wsId}`
  try {
    const raw = window.localStorage.getItem(key)
    return raw ? JSON.parse(raw) : null
  } catch (_) {
    return null
  }
}

// Maintain the dev debug surface that Tidewave / console users expect.
window.__devidePaneDebug = window.__devidePaneDebug || {}
function updateDebug(wsId, extra = {}) {
  if (!window.__devidePaneDebug[wsId]) {
    window.__devidePaneDebug[wsId] = { getSaved: () => getSavedPaneLayout(wsId) }
  }
  Object.assign(window.__devidePaneDebug[wsId], extra)
}

function persistPaneLayout(payload) {
  const wsId = payload?.workspace_id || "default"
  const key = `${PANE_LAYOUT_KEY_PREFIX}${wsId}`
  try {
    if (payload?.layout) {
      window.localStorage.setItem(key, JSON.stringify(payload.layout))
    }
  } catch (_) {
    /* quota or serialization error */
  }
}

// Global save listener (no DOM hook required)
window.addEventListener("phx:save_pane_layout", (e) => {
  const p = e.detail?.payload || e.detail
  persistPaneLayout(p)
  if (p?.workspace_id) updateDebug(p.workspace_id, { lastSaved: Date.now() })

  // Nudge all Ghostty fit terminals after any structural layout change (split/close/resize).
  // This wakes up ResizeObservers for newly inserted panes whose initial measurement
  // happened before the flex container had its final size. Double rAF gives the browser
  // time to commit the new layout.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      document.querySelectorAll('[phx-hook="GhosttyTerminal"]').forEach((el) => {
        // Cause a micro layout change on the hook root to trigger observers
        const orig = el.style.minHeight
        el.style.minHeight = (parseFloat(orig) || 100) + 0.5 + "px"
        requestAnimationFrame(() => {
          el.style.minHeight = orig || ""
        })
      })
    })
  })
})

// Also nudge on initial entry into raw mode (helps the very first default-raw load)
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

// Global request/reply for restore (the key part of Option B — no hook on the
// terminal subtree, so new split panes don't race with restore logic).
window.addEventListener("phx:request_saved_layout", (e) => {
  const payload = e.detail?.payload || e.detail || {}
  const wsId = payload.workspace_id || "default"
  const saved = getSavedPaneLayout(wsId)

  updateDebug(wsId, { lastRequest: Date.now() })

  if (saved && window.liveSocket) {
    // execJS commands use the [op, args_map] encoding that Phoenix.LiveView.JS
    // produces — `push` expects {event, value, ...}. Sending the older
    // [op, event_name, payload] tuple shape caused LV to log the entire
    // JSON string as the event name (handle_event(\"[[\\\"push\\\"…\")
    // and the restore silently failed, leaving pane_layout out of sync
    // and subsequent splits behaving wrong.
    const js = JSON.stringify([
      ["push", { event: "restore_pane_layout", value: { layout: saved } }]
    ])
    window.liveSocket.execJS(document.documentElement, js)
    updateDebug(wsId, { lastRestorePushed: Date.now() })
  }
})

// Dev observability: Tidewave / console can listen for these to trace the
// exact persistence lifecycle without guessing.
;["phx:save_pane_layout", "phx:request_saved_layout", "phx:persistence:saved", "phx:persistence:restore_pushed", "phx:persistence:hook_mounted"].forEach((evt) => {
  window.addEventListener(evt, (e) => {
    if (location.hostname === "localhost" || location.search.includes("debug_pane")) {
      console.debug("[pane-persist]", evt, e.detail || e)
    }
  })
})

// The authoritative debug surface for the raw split-pane persistence is now
// provided globally (no DOM hook required):
//   window.__devidePaneDebug[wsId].getSaved()   // if you want to attach a small helper
//   or just call getSavedPaneLayout(wsId) from the console.

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
