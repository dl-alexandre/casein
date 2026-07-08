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
import {FileViewerHook} from "./file_viewer_hook"
import {PaletteHook} from "./palette_hook"
import {GhosttyTerminal} from "./ghostty_terminal"
import {MobileKeyBar} from "./mobile_key_bar"
import {ChromeWidth} from "./chrome_width"
import {WorkspaceLeader} from "./workspace_leader"
import {TerminalActivity} from "./terminal_activity"
import {SessionPicker, wantsBrowserNavigation} from "./session_picker"
import {RenameInput} from "./rename_input"
import {MobileNavSheet} from "./mobile_nav_sheet"
import {PreviewPaneOverlay} from "./preview_pane_overlay"
import {FilePaneOverlay} from "./file_pane_overlay"
import {PaneHistoryDrawer} from "./pane_history_drawer"
import {TerminalSurface} from "./terminal_surface_hook"
import {TmuxPaneResize} from "./tmux_pane_resize_hook"
import {CopyText} from "./copy_text_hook"
import {ContextMenu} from "./context_menu_hook"
import {WindowPickerSidebar} from "./window_picker_sidebar"
import {WindowTabStrip} from "./window_tab_strip"
import {copyTextSync, showClipboardToast} from "./terminal_copy"
import {installPickerLinkCopy} from "./picker_link_copy"
import {installPreviewBridge} from "./preview_bridge"
import "./terminal_focus"
import {initTerminalThemes} from "./terminal_themes"

// Move the session onto the freshly-deployed instance. Prefer a background
// LiveView reconnect over a full page reload: the reconnect re-dials
// /run/devide/current.sock, which the atomic symlink swap now points at the new
// instance. For a code-only deploy the session resumes in place with no reload
// (tmux-backed terminals survive; mount rebuilds from params/session/tmux). If
// the new instance's static asset digest changed, its mount detects that via
// `static_changed?/1` and issues an external redirect — a real reload — on its
// own, so asset deploys still hard-reload exactly when they must. Falls back to
// a hard reload if the LiveSocket isn't available for any reason.
function applyDeployUpdate() {
  try {
    window.sessionStorage.setItem("devide:justUpdated", "1")
  } catch (_) {
    /* private mode / storage disabled — the toast is best-effort */
  }

  const ls = window.liveSocket
  if (ls && typeof ls.disconnect === "function" && typeof ls.connect === "function") {
    ls.disconnect(() => ls.connect())
  } else {
    window.location.reload()
  }
}

const DeployUpdateNow = {
  mounted() {
    this.onClick = () => applyDeployUpdate()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}

const DeploySyncNow = {
  mounted() {
    this.onClick = () => window.location.reload()
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}

function attentionSurfaceState() {
  if (document.visibilityState !== "visible") return "hidden"
  return document.hasFocus() ? "focused" : "visible"
}

const AttentionSurface = {
  mounted() {
    this.report = (force = false) => {
      const state = attentionSurfaceState()
      if (!force && this.lastState === state) return
      this.lastState = state
      this.pushEvent("terminal:attention_surface", {state})
    }

    this.onSurfaceChange = () => this.report(false)
    document.addEventListener("visibilitychange", this.onSurfaceChange)
    window.addEventListener("focus", this.onSurfaceChange)
    window.addEventListener("blur", this.onSurfaceChange)
    window.addEventListener("pageshow", this.onSurfaceChange)
    this.report(true)
  },

  destroyed() {
    document.removeEventListener("visibilitychange", this.onSurfaceChange)
    window.removeEventListener("focus", this.onSurfaceChange)
    window.removeEventListener("blur", this.onSurfaceChange)
    window.removeEventListener("pageshow", this.onSurfaceChange)
  },
}

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

function installServiceWorker() {
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return

  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").then(
      (registration) => {
        registration.update?.()

        registration.addEventListener("updatefound", () => {
          const worker = registration.installing
          if (!worker) return

          worker.addEventListener("statechange", () => {
            if (worker.state === "installed" && navigator.serviceWorker.controller) {
              window.dispatchEvent(
                new CustomEvent("devide:service-worker-update", {
                  detail: {registration}
                })
              )
            }
          })
        })
      },
      (error) => {
        if (window.console?.debug) console.debug("service worker registration failed", error)
      }
    )
  }, {once: true})
}

installServiceWorker()

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

function devideLongPollFallbackMs() {
  // The trusted-LAN HTTP shortcut is served through a raw systemd socket proxy.
  // WebSocket works there, but Phoenix long-poll fallback can fail LiveView
  // session verification and look like a page refresh loop. Keep fallback for
  // ordinary localhost/devbox paths, but avoid it on portless plain HTTP.
  if (window.location.protocol === "http:" && window.location.port === "") {
    return 0
  }

  return 10000
}

const liveSocket = new LiveSocket("/live", Socket, {
  // DevIDE runs behind OAuth/Caddy on a shared host. A short fallback window
  // causes loaded websocket handshakes to spawn long-poll joins, which looks
  // like a page refresh loop. Give the websocket path time to settle first.
  longPollFallbackMs: devideLongPollFallbackMs(),
  params: {_csrf_token: csrfToken, tab_id: devideTabId()},
  hooks: {...colocatedHooks, DeployUpdateNow, DeploySyncNow, AttentionSurface, FileViewerHook, PaletteHook, GhosttyTerminal, MobileKeyBar, ChromeWidth, WorkspaceLeader, TerminalActivity, SessionPicker, RenameInput, MobileNavSheet, PreviewPaneOverlay, FilePaneOverlay, PaneHistoryDrawer, TerminalSurface, TmuxPaneResize, CopyText, ContextMenu, WindowPickerSidebar, WindowTabStrip},
})

installPickerLinkCopy()

// Header window tabs are real links so middle/modified clicks and "open in
// new tab" keep working, but a plain click must switch windows through the
// phx-click event — never a full-page navigation — so it stays as smooth as
// the C-b n/p keybindings. (The dropdown pickers get the same guard inside
// the SessionPicker hook.)
window.addEventListener(
  "click",
  (e) => {
    const item = e.target?.closest?.("a[data-window-tab-select][href][phx-click]")
    if (!item) return

    if (wantsBrowserNavigation(e)) {
      e.stopPropagation()
      return
    }

    e.preventDefault()
  },
  true
)

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

window.addEventListener("phx:devide:reload_preview_iframes", (event) => {
  const paneId = event.detail?.pane_id || event.detail?.["pane-id"]
  const force = event.detail?.force === true || event.detail?.force === "true"
  const iframes = Array.from(
    document.querySelectorAll('[id^="preview-pane-"] iframe[data-preview-iframe]')
  ).filter((iframe) => {
    if (!paneId) return true
    return iframe.closest("[data-pane-id]")?.dataset.paneId === paneId
  })

  iframes.forEach((iframe) => {
    const targetSrc =
      iframe.closest("[data-pane-id]")?.dataset.displayUrl ||
      iframe.dataset.src ||
      iframe.getAttribute("src")
    const src = iframe.getAttribute("src")
    if (!targetSrc) return

    // The URL actually changed — point the frame at the new document.
    if (src !== targetSrc) {
      iframe.setAttribute("src", targetSrc)
      return
    }

    // Same URL: only reload when a caller explicitly forces it (e.g. a header
    // reload button or an agent reload tool). A bare focus/registration event
    // must NOT reload the live frame, or the preview flashes on every agent
    // step that focuses the pane.
    if (!force) return

    try {
      iframe.contentWindow?.location.reload()
      return
    } catch (_) {
      // Cross-origin frames can reject direct reload; resetting src is allowed.
    }

    iframe.setAttribute("src", targetSrc)
  })
})

window.addEventListener("phx:devide:preview_pane_action", (event) => {
  const paneId = event.detail?.pane_id || event.detail?.["pane-id"]
  if (!paneId) return

  const escape = window.CSS?.escape || ((value) => `${value}`.replace(/"/g, '\\"'))
  const overlay = document.querySelector(`[data-pane-id="${escape(paneId)}"]`)
  if (!overlay) return

  overlay.dispatchEvent(
    new CustomEvent("devide:preview-pane-action", {
      bubbles: false,
      detail: event.detail || {}
    })
  )
})

window.addEventListener("phx:devide:reload_page", () => {
  window.location.reload()
})

function shortcutHintFromButton(button) {
  if (!button) return null

  const explicitShortcut =
    button.dataset.shortcut ||
    button.closest(".leader-key-control")?.dataset.shortcut
  if (explicitShortcut) return explicitShortcut

  const title = button.getAttribute("title") || ""
  const titleShortcut =
    title.match(/Shortcut:\s*([^.;]+(?:\s+then\s+[^.;]+)?)/i) ||
    title.match(/(?:·\s*|\()((?:Ctrl \+ B|C-b|Ctrl\/Cmd|Ctrl|Cmd)[^)]+)\)?$/)
  if (titleShortcut) return titleShortcut[1].trim()

  const key =
    button.closest(".leader-key-control")?.querySelector(".leader-kbd")?.textContent?.trim() ||
    button.querySelector(".leader-kbd")?.textContent?.trim()
  if (key) return `Ctrl + B ${key}`

  return null
}

function humanShortcut(shortcut) {
  if (!shortcut) return null

  const keyLabel = (key) =>
    /^[a-z]$/.test(key) ? key.toUpperCase() : key

  const leader = shortcut.match(/^Ctrl \+ B,?\s+then\s+(.+)$/i)
  if (leader) return `Keyboard shortcut: Press Ctrl + B, then ${keyLabel(leader[1].trim())}`

  if (shortcut.startsWith("C-b ")) {
    return `Keyboard shortcut: Press Ctrl + B, then ${keyLabel(shortcut.slice(4).trim())}`
  }

  if (shortcut.startsWith("Ctrl + B ")) {
    return `Keyboard shortcut: Press Ctrl + B, then ${keyLabel(shortcut.slice("Ctrl + B ".length).trim())}`
  }

  return `Keyboard shortcut: Press ${shortcut.split("+").map((part) => part.trim()).join(" + ")}`
}

function actionLabelFromButton(button) {
  const label =
    button.getAttribute("aria-label") ||
    (button.getAttribute("title") || "").split("·")[0].replace(/\([^)]*\)\s*$/, "").trim()

  return label ? `${label}: ` : ""
}

document.addEventListener("click", (e) => {
  if (document.body.hasAttribute("data-leader-dispatching")) return

  const button = e.target.closest?.(
    ".workspace-main-header .leader-key-control button, .workspace-main-header .leader-key-control summary, .workspace-main-header button"
  )
  if (!button || button.disabled) return

  const shortcut = shortcutHintFromButton(button)
  if (!shortcut) return

  showClipboardToast(`${actionLabelFromButton(button)}${humanShortcut(shortcut)}`, {
    kind: "shortcut",
    duration: 2600
  })
})

const quietAgentNotifications = new Map()

function quietAgentTag(detail = {}) {
  return `devide-quiet-${detail.session_id || ""}-${detail.window_id || ""}`
}

function closeQuietAgentNotifications() {
  for (const notification of quietAgentNotifications.values()) {
    notification.close()
  }
  quietAgentNotifications.clear()

  if (navigator.serviceWorker?.ready) {
    navigator.serviceWorker.ready.then((registration) => {
      if (!registration.getNotifications) return

      registration.getNotifications().then((notifications) => {
        notifications.forEach((notification) => {
          if (`${notification.tag || ""}`.startsWith("devide-quiet-")) notification.close()
        })
      })
    }).catch(() => {})
  }
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") closeQuietAgentNotifications()
})
window.addEventListener("focus", closeQuietAgentNotifications)

// Quiet-agent OS notifications: the server pushes devide:agent_quiet only when
// the attention policy chooses `notify` for a quiet transition. Inline quiet
// badges cover focused workspace cases. The `tag` dedupes per window, so a
// flapping agent updates one notification instead of stacking.
window.addEventListener("phx:devide:agent_quiet", (e) => {
  if ((e.detail || {}).reaction !== "notify") return
  if (document.visibilityState === "visible" && document.hasFocus()) return
  if (!("Notification" in window) || Notification.permission !== "granted") return

  const d = e.detail || {}
  const where = [d.window, d.workspace].filter(Boolean).join(" · ")
  const tag = quietAgentTag(d)
  quietAgentNotifications.get(tag)?.close()

  const options = {
    body: `${where || "agent window"} — likely finished or awaiting input`,
    tag,
    icon: "/images/pwa-icon-192.png",
    badge: "/images/pwa-icon-192.png",
    data: {
      type: "agent_quiet",
      url: agentQuietUrl(d),
      session_id: d.session_id || null,
      window_id: d.window_id || null
    }
  }

  const showWindowNotification = () => showAgentQuietWindowNotification(options, d)

  if (navigator.serviceWorker?.ready) {
    navigator.serviceWorker.ready.then(
      (registration) => registration.showNotification("Agent went quiet", options),
      showWindowNotification
    ).catch(showWindowNotification)
    return
  }

  showWindowNotification()
})

function showAgentQuietWindowNotification(options, detail) {
  const notification = new Notification("Agent went quiet", options)
  quietAgentNotifications.set(options.tag, notification)
  notification.onclose = () => {
    if (quietAgentNotifications.get(options.tag) === notification) {
      quietAgentNotifications.delete(options.tag)
    }
  }
  notification.onclick = () => {
    window.focus()
    notification.close()
    openAgentQuietConversation(detail)
  }
}

function agentQuietUrl(detail) {
  const url = new URL(window.location.href)
  if (detail.session_id) url.searchParams.set("session", detail.session_id)
  if (detail.window_id) url.searchParams.set("window", detail.window_id)
  return url.href
}

function openAgentQuietConversation(detail) {
  // Deeplink straight to the agent's conversation through the same attach path
  // the picker uses, so server-side unseen quiet state is acknowledged.
  if (detail?.session_id && window.liveSocket) {
    const value = {"session-id": detail.session_id}
    if (detail.tmux_session) value["tmux-session"] = detail.tmux_session
    if (detail.window_id) value["window-id"] = detail.window_id
    window.liveSocket.execJS(
      document.documentElement,
      JSON.stringify([["push", {event: "attach_terminal_session", value}]])
    )
  }
}

// Browser alert permission must be an explicit user action. Any button or menu
// item can opt in by setting data-devide-notification-permission, and server or
// hook code can dispatch devide:notifications:request from a gesture handler.
const requestNotificationPermission = () => {
  if (!("Notification" in window)) return Promise.resolve("unsupported")
  if (Notification.permission !== "default") return Promise.resolve(Notification.permission)
  return Promise.resolve(Notification.requestPermission()).catch(() => "default")
}

const notificationPermissionState = () => {
  if (!("Notification" in window)) return "unsupported"
  return Notification.permission
}

const syncNotificationPermissionTriggers = (permission = notificationPermissionState()) => {
  document.querySelectorAll("[data-devide-notification-permission]").forEach((trigger) => {
    const visible = permission === "default"
    trigger.classList.toggle("hidden", !visible)
    trigger.classList.toggle("inline-flex", visible)
    trigger.setAttribute("aria-hidden", visible ? "false" : "true")
    trigger.dataset.notificationPermission = permission
  })
}

const renderNotificationPermission = (permission) => {
  syncNotificationPermissionTriggers(permission)

  if (permission === "granted") {
    showClipboardToast("Browser alerts enabled")
  } else if (permission === "denied") {
    showClipboardToast("Browser alerts are blocked in this browser", {kind: "pending", duration: 5000})
  } else if (permission === "unsupported") {
    showClipboardToast("Browser alerts are not supported here", {kind: "pending", duration: 5000})
  }
}

const requestAndRenderNotificationPermission = () => {
  requestNotificationPermission().then(renderNotificationPermission)
}

window.DevIDE = Object.assign(window.DevIDE || {}, {
  requestNotificationPermission
})

window.addEventListener("devide:notifications:request", requestAndRenderNotificationPermission)
window.addEventListener("phx:page-loading-stop", () => syncNotificationPermissionTriggers())

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => syncNotificationPermissionTriggers(), {once: true})
} else {
  syncNotificationPermissionTriggers()
}

if (navigator.serviceWorker) {
  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type !== "DEVIDE_AGENT_QUIET_OPEN") return
    openAgentQuietConversation(event.data.detail || {})
  })
}

document.addEventListener("click", (e) => {
  const trigger = e.target.closest?.("[data-devide-notification-permission]")
  if (!trigger) return

  e.preventDefault()
  requestAndRenderNotificationPermission()
})

// Mobile single-pane focus (auto-zoom so the terminal renders crisp/native rather
// than the distorting CSS fit-scale) is handled by the TmuxPaneResize hook's
// ensure-zoom logic — see assets/js/tmux_pane_resize_hook.js — not by a split event.

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
initTerminalThemes()

window.addEventListener("devide:font-size", (e) => {
  _fontSize = Math.max(8, Math.min(24, _fontSize + (e.detail?.delta || 0)))
  applyFontSize(_fontSize)
  localStorage.setItem("devide:font-size", _fontSize)
  const lineH = Math.round(_fontSize * 1.31) + "px"
  // Re-patch all mounted terminal pres with new lineHeight so cell metrics update
  document.querySelectorAll('[phx-hook="GhosttyTerminal"] pre').forEach((pre) => {
    pre.style.lineHeight = lineH
  })
  // Nudge Ghostty panes to trigger refit via their ResizeObserver
  document.querySelectorAll('[phx-hook="GhosttyTerminal"]').forEach((el) => {
    const orig = el.style.minHeight
    el.style.minHeight = (parseFloat(orig) || 100) + 0.5 + "px"
    requestAnimationFrame(() => { el.style.minHeight = orig || "" })
  })
})

window.addEventListener("phx:devide:open_tab", (e) => {
  const url = e.detail?.url
  if (url) window.open(url, "_blank", "noreferrer")
})

// After an update-triggered move lands — whether that was a background
// reconnect (applyDeployUpdate) or the reload a static-asset change forced —
// surface a subtle confirmation. The flag is only set when we deliberately
// update, so ordinary network-blip reconnects and fresh loads stay silent.
const deploySocket = typeof liveSocket.getSocket === "function" && liveSocket.getSocket()
if (deploySocket && typeof deploySocket.onOpen === "function") {
  deploySocket.onOpen(() => {
    try {
      if (window.sessionStorage.getItem("devide:justUpdated")) {
        window.sessionStorage.removeItem("devide:justUpdated")
        showClipboardToast("Updated to the latest version")
      }
    } catch (_) {
      /* storage disabled — best-effort toast */
    }
  })
}

// connect if there are any LiveViews on the page
liveSocket.connect()
installPreviewBridge({liveSocket})

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
