const SOURCE = "devide-preview"
const VERSION = 1
const REQUEST_ID_KEY = "devide:preview:request_id"
const LIVE_CONNECTED_CLASS = "phx-connected"
const LIVE_DISCONNECTED_CLASS = "phx-disconnected"

export function installPreviewBridge({liveSocket} = {}) {
  if (!previewBridgeEnabled()) return null
  if (window.__devidePreviewBridge) return window.__devidePreviewBridge

  const bridge = new PreviewBridge(liveSocket)
  window.__devidePreviewBridge = bridge
  bridge.start()
  return bridge
}

class PreviewBridge {
  constructor(liveSocket) {
    this.liveSocket = liveSocket || null
    this.requestId = previewRequestId()
    this.lastLiveConnected = null
    this.started = false
    this.onPageLoadingStart = (event) =>
      this.emit("devide:preview:page_loading_start", {kind: event.detail?.kind || null})
    this.onPageLoadingStop = (event) =>
      this.emit("devide:preview:page_loading_stop", {kind: event.detail?.kind || null})
    this.onError = (event) => {
      this.emit("devide:preview:client_error", {
        message: event.message || "client_error",
        filename: event.filename || null,
        lineno: event.lineno || null,
        colno: event.colno || null
      })
    }
    this.onUnhandledRejection = (event) => {
      this.emit("devide:preview:client_error", {
        message: "unhandled_rejection",
        reason: safeReason(event.reason)
      })
    }
  }

  start() {
    if (this.started) return
    this.started = true

    this.emit("devide:preview:bridge_ready")
    this.bindDomReady()
    this.bindPageLoading()
    this.bindClientErrors()
    this.bindLiveSocketState()
  }

  emit(type, detail = {}) {
    const message = {
      source: SOURCE,
      version: VERSION,
      type,
      payload: {
        url: window.location.href,
        pathname: window.location.pathname,
        timestamp: Date.now(),
        request_id: this.requestId,
        ...detail
      }
    }

    window.dispatchEvent(new CustomEvent("devide:preview:signal", {detail: message}))

    if (window.parent && window.parent !== window) {
      window.parent.postMessage(message, "*")
    }
  }

  bindDomReady() {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", () => this.emit("devide:preview:dom_loaded"), {
        once: true
      })
      return
    }

    window.queueMicrotask(() => this.emit("devide:preview:dom_loaded"))
  }

  bindPageLoading() {
    window.addEventListener("phx:page-loading-start", this.onPageLoadingStart)
    window.addEventListener("phx:page-loading-stop", this.onPageLoadingStop)
  }

  bindClientErrors() {
    window.addEventListener("error", this.onError)
    window.addEventListener("unhandledrejection", this.onUnhandledRejection)
  }

  bindLiveSocketState() {
    this.reportLiveSocketState()

    if (!document.body || !window.MutationObserver) return

    this.liveSocketObserver = new MutationObserver(() => this.reportLiveSocketState())
    this.liveSocketObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["class"]
    })
  }

  reportLiveSocketState() {
    const connected = liveSocketConnected(this.liveSocket)
    if (connected === this.lastLiveConnected) return

    this.lastLiveConnected = connected

    if (connected === true) {
      this.emit("devide:preview:live_socket_connected", {connected: true})
    } else if (connected === false) {
      this.emit("devide:preview:live_socket_disconnected", {connected: false})
    }
  }
}

function previewBridgeEnabled() {
  let explicitPreview = false

  try {
    const params = new URLSearchParams(window.location.search)

    explicitPreview =
      params.get("devide_preview") === "1" || params.get("preview_superadmin") === "1"
  } catch (_) {
    /* constrained test contexts can reject URLSearchParams */
  }

  if (explicitPreview) return true
  if (process.env.NODE_ENV !== "development") return false

  return window.parent && window.parent !== window
}

function previewRequestId() {
  try {
    let id = window.sessionStorage.getItem(REQUEST_ID_KEY)
    if (!id) {
      id = `pv-${Math.random().toString(36).slice(2, 10)}`
      window.sessionStorage.setItem(REQUEST_ID_KEY, id)
    }
    return id
  } catch (_) {
    return `pv-${Math.random().toString(36).slice(2, 10)}`
  }
}

function liveSocketConnected(liveSocket) {
  if (document.body?.classList?.contains(LIVE_CONNECTED_CLASS)) return true
  if (document.body?.classList?.contains(LIVE_DISCONNECTED_CLASS)) return false

  try {
    if (typeof liveSocket?.socket?.isConnected === "function") {
      return liveSocket.socket.isConnected()
    }
  } catch (_) {
    /* socket state is best-effort only */
  }

  return null
}

function safeReason(reason) {
  if (reason == null) return null
  if (typeof reason === "string") return reason
  if (reason instanceof Error) return reason.message

  try {
    return JSON.stringify(reason)
  } catch (_) {
    return String(reason)
  }
}
