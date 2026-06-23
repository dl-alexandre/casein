export const PreviewPaneOverlay = {
  mounted() {
    this.paneId = this.el.dataset.paneId
    this.entered = false
    this.shield = this.el.querySelector("[data-preview-shield]")
    this.clip = this.el.querySelector("[data-preview-clip]")
    this.iframe = this.el.querySelector("iframe[data-preview-iframe]")
    this.viewport = this.parseViewport(this.el.dataset.viewport)
    this.displayUrl = null
    this.snapshotMode = this.isSnapshotMode()

    this.applyRect()
    this.bindTelemetry()
    this.applyDisplayUrl()
    this.applyViewportMode()
    this.bindSelection()
    this.bindShield()
    this.bindExitGuards()
    this.bindResizeObserver()
    this.bindPreviewActions()
    this.setInteractive()
    this.pushTelemetry("overlay_mounted", this.frameState())
    this.startVisibilityHeartbeat()
  },

  updated() {
    this.snapshotMode = this.isSnapshotMode()
    this.applyRect()
    this.applyDisplayUrl()
    this.applyViewportMode()
    this.setInteractive()
  },

  destroyed() {
    this.pushTelemetry("overlay_destroyed", this.frameState())
    this.stopVisibilityHeartbeat()
    this.teardownTelemetry()
    this.teardownExitGuards()
    this.teardownResizeObserver()
    this.teardownPreviewActions()
  },

  applyRect() {
    const rect = this.parseRect(this.el.dataset.paneRect)
    if (!rect) return

    Object.assign(this.el.style, {
      position: "absolute",
      left: `${rect.left}%`,
      top: `${rect.top}%`,
      width: `${rect.width}%`,
      height: `${rect.height}%`,
      zIndex: this.entered ? "40" : "25",
      pointerEvents: "auto",
      contain: "layout"
    })
  },

  applyViewportMode() {
    if (!this.clip || !this.iframe) return

    if (this.viewport) {
      const scale = this.viewportScale()
      this.clip.style.overflow = "hidden"
      this.clip.style.width = "100%"
      this.clip.style.height = "100%"
      this.iframe.style.width = `${this.viewport.width}px`
      this.iframe.style.height = `${this.viewport.height}px`
      this.iframe.style.border = "0"
      this.iframe.style.transform = scale < 1 ? `scale(${scale})` : "none"
      this.iframe.style.transformOrigin = "0 0"
    } else {
      this.clip.style.overflow = "hidden"
      this.clip.style.width = "100%"
      this.clip.style.height = "100%"
      this.iframe.style.width = "100%"
      this.iframe.style.height = "100%"
      this.iframe.style.border = "0"
      this.iframe.style.transform = "none"
      this.iframe.style.transformOrigin = "0 0"
    }
  },

  viewportScale() {
    if (!this.clip || !this.viewport?.width || !this.viewport?.height) return 1

    const availableWidth = this.clip.clientWidth
    const availableHeight = this.clip.clientHeight
    if (!availableWidth || !availableHeight) return 1

    return Math.min(1, availableWidth / this.viewport.width, availableHeight / this.viewport.height)
  },

  applyDisplayUrl() {
    if (!this.iframe) return

    const nextUrl = this.el.dataset.displayUrl || this.iframe.dataset.src
    if (!nextUrl || nextUrl === this.displayUrl) return

    this.displayUrl = nextUrl
    if (this.iframe.getAttribute("src") !== nextUrl) {
      this.iframe.setAttribute("src", nextUrl)
      this.pushTelemetry("iframe_src_assigned", this.frameState())
      window.setTimeout(() => this.confirmLoadedIfComplete(), 0)
      window.setTimeout(() => this.confirmLoadedIfComplete(), 250)
    }
  },

  confirmLoadedIfComplete() {
    if (!this.iframe || !this.displayUrl) return

    try {
      const doc = this.iframe.contentDocument
      if (doc?.readyState === "complete") {
        this.pushTelemetry("iframe_loaded", this.frameState())
      }
    } catch (_err) {
      // Cross-origin frames still fire the normal load event. The preview proxy
      // should be same-origin, but keep the fallback path harmless.
    }
  },

  bindShield() {
    if (!this.shield) return

    this.shield.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()

      if (this.entered) return

      this.select()

      if (this.snapshotMode) {
        this.forwardSnapshotClick(event)
        return
      }

      const paneId = this.el.dataset.paneId
      if (!paneId) return

      this.pushEvent("tmux:select_pane", { "pane-id": paneId })
    })

    this.shield.addEventListener("dblclick", (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.enter()
    })
  },

  bindSelection() {
    this.el.addEventListener("mouseenter", () => this.select())
    this.iframe?.addEventListener("focus", () => this.select())
  },

  bindTelemetry() {
    this.onPointerDown = (event) => this.pushTelemetry("pointer_down", this.pointerPayload(event))
    this.onPointerUp = (event) => this.pushTelemetry("pointer_up", this.pointerPayload(event))
    this.onKeyDownTelemetry = (event) => {
      if (!this.entered) return
      this.pushTelemetry("key_intent", {
        key: this.safeKey(event.key),
        modifiers: this.modifiers(event)
      })
    }
    this.onIframeLoad = () => this.pushTelemetry("iframe_loaded", { url: this.displayUrl })
    this.onIframeError = () => this.pushTelemetry("iframe_error", { url: this.displayUrl })
    this.onIframeFocus = () => this.pushTelemetry("iframe_focus", { url: this.displayUrl })
    this.onWindowBlurTelemetry = () => {
      if (this.entered) this.pushTelemetry("iframe_blur", { url: this.displayUrl })
    }
    this.onWheelTelemetry = (event) => {
      if (!this.snapshotMode) return
      this.pushTelemetry("scroll", {
        delta_x: Math.round(event.deltaX || 0),
        delta_y: Math.round(event.deltaY || 0)
      })
    }

    this.el.addEventListener("pointerdown", this.onPointerDown, true)
    this.el.addEventListener("pointerup", this.onPointerUp, true)
    this.el.addEventListener("wheel", this.onWheelTelemetry, { passive: true })
    window.addEventListener("keydown", this.onKeyDownTelemetry, true)
    window.addEventListener("blur", this.onWindowBlurTelemetry)
    this.iframe?.addEventListener("load", this.onIframeLoad)
    this.iframe?.addEventListener("error", this.onIframeError)
    this.iframe?.addEventListener("focus", this.onIframeFocus)
  },

  teardownTelemetry() {
    this.el.removeEventListener("pointerdown", this.onPointerDown, true)
    this.el.removeEventListener("pointerup", this.onPointerUp, true)
    this.el.removeEventListener("wheel", this.onWheelTelemetry)
    window.removeEventListener("keydown", this.onKeyDownTelemetry, true)
    window.removeEventListener("blur", this.onWindowBlurTelemetry)
    this.iframe?.removeEventListener("load", this.onIframeLoad)
    this.iframe?.removeEventListener("error", this.onIframeError)
    this.iframe?.removeEventListener("focus", this.onIframeFocus)
  },

  bindExitGuards() {
    this.onKeyDown = (event) => {
      if (!this.entered) return
      if (event.key === "Escape") this.exit()
    }

    this.onWindowBlur = () => {
      if (!this.entered) return

      window.setTimeout(() => {
        const active = document.activeElement
        if (active && this.el.contains(active)) return
        this.exit()
      }, 0)
    }

    window.addEventListener("keydown", this.onKeyDown, true)
    window.addEventListener("blur", this.onWindowBlur)
  },

  teardownExitGuards() {
    window.removeEventListener("keydown", this.onKeyDown, true)
    window.removeEventListener("blur", this.onWindowBlur)
  },

  bindResizeObserver() {
    if (!window.ResizeObserver || !this.clip) return

    this.resizeObserver = new ResizeObserver(() => {
      this.applyViewportMode()
    })
    this.resizeObserver.observe(this.clip)
  },

  teardownResizeObserver() {
    this.resizeObserver?.disconnect()
    this.resizeObserver = null
  },

  bindPreviewActions() {
    this.onPreviewPaneAction = (event) => this.handlePreviewPaneAction(event.detail || {})
    this.el.addEventListener("devide:preview-pane-action", this.onPreviewPaneAction)
  },

  teardownPreviewActions() {
    this.el.removeEventListener("devide:preview-pane-action", this.onPreviewPaneAction)
  },

  startVisibilityHeartbeat() {
    this.stopVisibilityHeartbeat()
    this.visibilityHeartbeat = window.setInterval(() => {
      if (!this.displayUrl) return
      this.pushTelemetry("visibility_heartbeat", this.frameState())
    }, 5000)
  },

  stopVisibilityHeartbeat() {
    if (!this.visibilityHeartbeat) return
    window.clearInterval(this.visibilityHeartbeat)
    this.visibilityHeartbeat = null
  },

  enter() {
    if (this.entered) return
    this.entered = true
    this.setInteractive()
    this.el.classList.add("preview-pane-entered")
    this.applyRect()
    this.select()
    this.iframe?.focus()
  },

  exit() {
    if (!this.entered) return
    this.entered = false
    this.setInteractive()
    this.el.classList.remove("preview-pane-entered")
    this.applyRect()
    this.pushEvent("preview-pane:exit", { "pane-id": this.paneId })
  },

  select() {
    this.pushEvent("preview-pane:enter", { "pane-id": this.paneId })
  },

  setInteractive() {
    if (this.snapshotMode) {
      if (this.shield) {
        this.shield.style.pointerEvents = "auto"
        this.shield.style.cursor = "pointer"
      }
      if (this.iframe) this.iframe.style.pointerEvents = "none"
      return
    }

    if (this.shield) {
      this.shield.style.pointerEvents = "none"
      this.shield.style.cursor = ""
    }
    if (this.iframe) this.iframe.style.pointerEvents = "auto"
  },

  handlePreviewPaneAction(payload) {
    const action = payload.preview_action || payload.previewAction
    const target = payload.target || {}
    const requestId = payload.request_id || payload.requestId

    try {
      if (!this.iframe) throw new Error("iframe_unavailable")
      if (this.snapshotMode) throw new Error("snapshot_mode")

      if (action === "click") {
        this.performVisibleClick(target)
        this.ackPreviewAction("visible_click", requestId, "ok", target)
      } else if (action === "type") {
        this.performVisibleType(target)
        this.ackPreviewAction("visible_type", requestId, "ok", target)
      } else if (action === "press") {
        this.performVisiblePress(target)
        this.ackPreviewAction("visible_press", requestId, "ok", target)
      } else {
        throw new Error("unknown_action")
      }
    } catch (err) {
      const event = action === "type" ? "visible_type" : action === "press" ? "visible_press" : "visible_click"
      this.ackPreviewAction(event, requestId, "error", target, this.safeReason(err))
    }
  },

  performVisibleClick(target) {
    const doc = this.iframeDocument()

    if (target.selector) {
      const element = this.queryTarget(doc, target.selector, target.nth)
      if (!element) throw new Error("selector_not_found")
      element.scrollIntoView({ block: "center", inline: "center" })
      element.click()
      return
    }

    if (Number.isFinite(target.x) && Number.isFinite(target.y)) {
      const win = this.iframe.contentWindow
      const element = doc.elementFromPoint(target.x, target.y)
      if (!element) throw new Error("point_target_not_found")
      const eventOpts = this.pointerEventOptions(target)
      element.dispatchEvent(new win.MouseEvent("mousedown", eventOpts))
      element.dispatchEvent(new win.MouseEvent("mouseup", eventOpts))
      element.dispatchEvent(new win.MouseEvent("click", eventOpts))
      return
    }

    throw new Error("missing_click_target")
  },

  performVisibleType(target) {
    const doc = this.iframeDocument()
    const element = this.queryTarget(doc, target.selector, target.nth)
    if (!element) throw new Error("selector_not_found")

    const text = typeof target.text === "string" ? target.text : ""
    element.focus()

    if ("value" in element) {
      element.value = `${element.value || ""}${text}`
      element.dispatchEvent(new this.iframe.contentWindow.InputEvent("input", {
        bubbles: true,
        inputType: "insertText",
        data: text
      }))
      element.dispatchEvent(new this.iframe.contentWindow.Event("change", { bubbles: true }))
    } else {
      element.textContent = `${element.textContent || ""}${text}`
      element.dispatchEvent(new this.iframe.contentWindow.InputEvent("input", {
        bubbles: true,
        inputType: "insertText",
        data: text
      }))
    }
  },

  performVisiblePress(target) {
    const doc = this.iframeDocument()
    const win = this.iframe.contentWindow
    const key = target.key || ""
    if (!key) throw new Error("missing_key")

    const active = doc.activeElement || doc.body
    if (!active) throw new Error("missing_key_target")

    const opts = { key, bubbles: true, cancelable: true }
    active.dispatchEvent(new win.KeyboardEvent("keydown", opts))
    active.dispatchEvent(new win.KeyboardEvent("keyup", opts))
  },

  iframeDocument() {
    try {
      const doc = this.iframe?.contentDocument
      if (!doc) throw new Error("iframe_unavailable")
      return doc
    } catch (err) {
      throw new Error("cross_origin_blocked", { cause: err })
    }
  },

  queryTarget(doc, selector, nth) {
    if (!selector) return null
    const index = Number.isInteger(nth) && nth >= 0 ? nth : 0
    return Array.from(doc.querySelectorAll(selector))[index] || null
  },

  pointerEventOptions(target) {
    return {
      bubbles: true,
      cancelable: true,
      clientX: target.x || 0,
      clientY: target.y || 0,
      button: target.button || 0,
      altKey: Boolean(target.modifiers?.alt),
      ctrlKey: Boolean(target.modifiers?.ctrl),
      metaKey: Boolean(target.modifiers?.meta),
      shiftKey: Boolean(target.modifiers?.shift)
    }
  },

  ackPreviewAction(event, requestId, status, target, reason = null) {
    this.pushTelemetry(event, {
      request_id: requestId,
      status,
      reason,
      selector: target.selector || null,
      nth: Number.isInteger(target.nth) ? target.nth : null,
      x: Number.isFinite(target.x) ? target.x : null,
      y: Number.isFinite(target.y) ? target.y : null,
      key: target.key ? this.safeKey(target.key) : null,
      text_length: typeof target.text === "string" ? target.text.length : null
    })
  },

  safeReason(err) {
    const message = err?.message || `${err || "error"}`
    return message.replace(/[^a-zA-Z0-9_:-]/g, "_").slice(0, 80)
  },

  forwardSnapshotClick(event) {
    const targetRect = this.iframe?.getBoundingClientRect() || this.clip?.getBoundingClientRect()
    if (!targetRect) return

    const scale = this.viewportScale()
    if (!scale) return

    const x = Math.round((event.clientX - targetRect.left) / scale)
    const y = Math.round((event.clientY - targetRect.top) / scale)

    if (this.viewport) {
      if (x < 0 || y < 0 || x >= this.viewport.width || y >= this.viewport.height) return
    }

    this.showClickFeedback(event.clientX, event.clientY)

    this.pushEvent("preview-pane:snapshot-click", {
      "pane-id": this.paneId,
      x,
      y,
      button: event.button || 0,
      modifiers: {
        alt: event.altKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey,
        shift: event.shiftKey
      }
    })
  },

  pushTelemetry(event, metadata = {}) {
    if (!this.paneId) return
    this.pushEvent("preview-pane:telemetry", {
      "pane-id": this.paneId,
      event,
      mode: this.snapshotMode ? "snapshot" : "iframe",
      url: this.displayUrl,
      metadata
    })
  },

  frameState() {
    const rect = this.el.getBoundingClientRect()
    return {
      url: this.displayUrl,
      iframe_src: this.iframe?.getAttribute("src") || null,
      width: Math.round(rect.width || 0),
      height: Math.round(rect.height || 0)
    }
  },

  pointerPayload(event) {
    const rect = this.iframe?.getBoundingClientRect() || this.clip?.getBoundingClientRect() || this.el.getBoundingClientRect()
    const scale = this.viewportScale() || 1

    return {
      x: Math.round((event.clientX - rect.left) / scale),
      y: Math.round((event.clientY - rect.top) / scale),
      button: event.button || 0,
      modifiers: this.modifiers(event)
    }
  },

  modifiers(event) {
    return {
      alt: event.altKey,
      ctrl: event.ctrlKey,
      meta: event.metaKey,
      shift: event.shiftKey
    }
  },

  safeKey(key) {
    if (!key) return "unknown"
    if (key.length === 1) return "character"
    return key
  },

  showClickFeedback(clientX, clientY) {
    const dot = document.createElement("span")
    const rect = this.el.getBoundingClientRect()

    dot.setAttribute("aria-hidden", "true")
    dot.className = "pointer-events-none absolute z-20 size-4 -translate-x-1/2 -translate-y-1/2 rounded-full border border-sky-400/80 bg-sky-300/30"
    dot.style.left = `${clientX - rect.left}px`
    dot.style.top = `${clientY - rect.top}px`
    dot.style.transition = "opacity 180ms ease, transform 180ms ease"

    this.el.appendChild(dot)

    window.requestAnimationFrame(() => {
      dot.style.opacity = "0"
      dot.style.transform = "translate(-50%, -50%) scale(1.8)"
    })

    window.setTimeout(() => dot.remove(), 220)
  },

  parseRect(raw) {
    if (!raw) return null
    try {
      const rect = JSON.parse(raw)
      if (
        typeof rect.left === "number" &&
        typeof rect.top === "number" &&
        typeof rect.width === "number" &&
        typeof rect.height === "number"
      ) {
        return rect
      }
    } catch (_) {
      return null
    }
    return null
  },

  parseViewport(raw) {
    if (!raw) return null
    const match = String(raw).match(/^(\d+)x(\d+)$/i)
    if (!match) return null
    return { width: Number(match[1]), height: Number(match[2]) }
  },

  isSnapshotMode() {
    return this.el.dataset.snapshotMode === "true"
  }
}
