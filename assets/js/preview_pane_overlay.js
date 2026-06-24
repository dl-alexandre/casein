export const PreviewPaneOverlay = {
  mounted() {
    this.paneId = this.el.dataset.paneId
    this.entered = false
    this.shield = this.el.querySelector("[data-preview-shield]")
    this.clip = this.el.querySelector("[data-preview-clip]")
    this.iframe = this.el.querySelector("iframe[data-preview-iframe]")
    this.status = this.el.querySelector("[data-preview-status]")
    this.statusTitle = this.el.querySelector("[data-preview-status-title]")
    this.statusDetail = this.el.querySelector("[data-preview-status-detail]")
    this.reloadButton = this.el.querySelector("[data-preview-reload]")
    this.reopenButton = this.el.querySelector("[data-preview-reopen]")
    this.viewport = this.parseViewport(this.el.dataset.viewport)
    this.displayUrl = null
    this.loadedUrl = null
    this.loadStartedAt = null
    this.loadTimeout = null
    this.recoveryAttempts = 0
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
    this.bindStatusActions()
    this.bindRecording()
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
    this.teardownStatusActions()
    this.teardownRecording()
    this.clearLoadTimeout()
  },

  // ── Screen recording ────────────────────────────────────────────────────
  // Capture the live preview with getDisplayMedia + MediaRecorder, cropped to
  // this pane via Region Capture where supported, and stream the webm to the
  // server in ordered chunks. On stop the server surfaces the recording as a
  // playback artifact in this pane (see show.ex "preview-recording:finalized").
  bindRecording() {
    this.recorder = null
    this.recordingStream = null
    this.recordingId = null
    this.recordingSeq = 0
    this.recordingUploads = []
    this.workspaceId = this.el.dataset.workspaceId || null

    // A pane already showing a recording (playback) is not itself recordable.
    if (!this.workspaceId || this.el.dataset.playbackMode === "true") return
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) return
    if (typeof window.MediaRecorder === "undefined") return

    const button = document.createElement("button")
    button.type = "button"
    button.dataset.previewRecord = ""
    button.className =
      "pointer-events-auto absolute left-2 top-2 z-20 flex items-center gap-1 rounded border " +
      "border-zinc-700/70 bg-zinc-950/80 px-2 py-1 text-[10px] font-medium leading-none " +
      "text-zinc-200 shadow-sm backdrop-blur transition hover:border-rose-400 hover:text-rose-100"
    button.textContent = "● Record"

    this.onRecordClick = (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.toggleRecording()
    }
    button.addEventListener("click", this.onRecordClick)
    this.el.appendChild(button)
    this.recordButton = button
  },

  teardownRecording() {
    if (this.recordButton && this.onRecordClick) {
      this.recordButton.removeEventListener("click", this.onRecordClick)
    }
    this.stopRecordingStream()
    this.recorder = null
  },

  toggleRecording() {
    if (this.recorder && this.recorder.state === "recording") {
      this.stopRecording()
    } else {
      this.startRecording()
    }
  },

  async startRecording() {
    try {
      const stream = await navigator.mediaDevices.getDisplayMedia({
        video: {displaySurface: "browser"},
        preferCurrentTab: true,
        audio: false
      })
      this.recordingStream = stream
      await this.cropToPane(stream)

      this.recordingId = this.newRecordingId()
      this.recordingSeq = 0
      this.recordingUploads = []

      const recorder = new MediaRecorder(stream, {mimeType: this.pickRecordingMime()})
      recorder.ondataavailable = (event) => {
        if (event.data && event.data.size > 0) {
          this.recordingUploads.push(this.uploadChunk(event.data, this.recordingSeq++))
        }
      }
      recorder.onstop = () => this.finalizeRecording()
      // A surface the user stops sharing from the browser chrome ends the track.
      stream.getVideoTracks().forEach((track) => {
        track.addEventListener("ended", () => this.stopRecording())
      })

      recorder.start(4000)
      this.recorder = recorder
      this.setRecordButtonState("recording")
    } catch (_error) {
      this.stopRecordingStream()
      this.setRecordButtonState("idle")
    }
  },

  async cropToPane(stream) {
    const target = this.clip || this.el
    const [track] = stream.getVideoTracks()
    if (!track || !window.CropTarget || typeof track.cropTo !== "function") return

    try {
      const cropTarget = await window.CropTarget.fromElement(target)
      await track.cropTo(cropTarget)
    } catch (_error) {
      // Region Capture unsupported or surface isn't the current tab — fall back
      // to recording whatever the user chose to share.
    }
  },

  stopRecording() {
    this.setRecordButtonState("uploading")
    if (this.recorder && this.recorder.state !== "inactive") {
      try {
        this.recorder.stop()
      } catch (_error) {
        this.stopRecordingStream()
        this.setRecordButtonState("idle")
      }
    } else {
      this.stopRecordingStream()
      this.setRecordButtonState("idle")
    }
  },

  stopRecordingStream() {
    if (this.recordingStream) {
      this.recordingStream.getTracks().forEach((track) => track.stop())
      this.recordingStream = null
    }
  },

  async uploadChunk(blob, seq) {
    const url = `/preview-recordings/${encodeURIComponent(this.workspaceId)}/${this.recordingId}/chunk?seq=${seq}`
    try {
      await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/octet-stream",
          "x-csrf-token": this.recordingCsrfToken()
        },
        body: blob,
        credentials: "same-origin"
      })
    } catch (_error) {
      // A dropped chunk corrupts the webm; surfaced when finalize fails.
    }
  },

  async finalizeRecording() {
    this.stopRecordingStream()
    const recordingId = this.recordingId

    try {
      await Promise.all(this.recordingUploads)
      const url = `/preview-recordings/${encodeURIComponent(this.workspaceId)}/${recordingId}/finalize`
      const response = await fetch(url, {
        method: "POST",
        headers: {"x-csrf-token": this.recordingCsrfToken()},
        credentials: "same-origin"
      })
      const payload = await response.json()
      if (response.ok && payload && payload.url) {
        this.pushEvent("preview-recording:finalized", {pane_id: this.paneId, url: payload.url})
      }
    } catch (_error) {
      // Leave the live preview in place if finalize fails.
    } finally {
      this.recorder = null
      this.recordingUploads = []
      this.setRecordButtonState("idle")
    }
  },

  setRecordButtonState(state) {
    if (!this.recordButton) return
    if (state === "recording") {
      this.recordButton.textContent = "■ Stop"
      this.recordButton.classList.add("border-rose-400", "text-rose-100")
    } else if (state === "uploading") {
      this.recordButton.textContent = "… Saving"
      this.recordButton.disabled = true
    } else {
      this.recordButton.textContent = "● Record"
      this.recordButton.disabled = false
      this.recordButton.classList.remove("border-rose-400", "text-rose-100")
    }
  },

  newRecordingId() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") {
      return window.crypto.randomUUID()
    }
    return `rec-${Date.now()}-${Math.floor(Math.random() * 1e9)}`
  },

  pickRecordingMime() {
    const candidates = ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm"]
    for (const candidate of candidates) {
      if (window.MediaRecorder.isTypeSupported(candidate)) return candidate
    }
    return "video/webm"
  },

  recordingCsrfToken() {
    const meta = document.querySelector("meta[name='csrf-token']")
    return meta ? meta.getAttribute("content") : ""
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
    this.loadedUrl = null
    if (this.iframe.getAttribute("src") !== nextUrl) {
      this.setFrameSrc(nextUrl, "display_url_changed")
      window.setTimeout(() => this.confirmLoadedIfComplete(), 0)
      window.setTimeout(() => this.confirmLoadedIfComplete(), 250)
    } else if (!this.frameState().loaded) {
      this.scheduleLoadTimeout("existing_src_not_loaded")
    }
  },

  confirmLoadedIfComplete() {
    if (!this.iframe || !this.displayUrl) return

    try {
      const doc = this.iframe.contentDocument
      if (doc?.readyState === "complete") {
        this.loadedUrl = this.displayUrl
        this.clearLoadTimeout()
        this.hideStatus()
        this.recoveryAttempts = 0
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
    this.onIframeLoad = () => {
      this.loadedUrl = this.displayUrl
      this.clearLoadTimeout()
      this.hideStatus()
      this.recoveryAttempts = 0
      this.pushTelemetry("iframe_loaded", this.frameState())
    }
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

  bindStatusActions() {
    this.onPreviewReload = (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.reloadFrame("manual_reload")
    }

    this.onPreviewReopen = (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.requestReopen("manual_reopen")
    }

    this.reloadButton?.addEventListener("click", this.onPreviewReload)
    this.reopenButton?.addEventListener("click", this.onPreviewReopen)
  },

  teardownStatusActions() {
    this.reloadButton?.removeEventListener("click", this.onPreviewReload)
    this.reopenButton?.removeEventListener("click", this.onPreviewReopen)
  },

  startVisibilityHeartbeat() {
    this.stopVisibilityHeartbeat()
    this.visibilityHeartbeat = window.setInterval(() => {
      if (!this.displayUrl) return
      if (!this.frameState().loaded) return
      this.pushTelemetry("visibility_heartbeat", this.frameState())
    }, 5000)
  },

  stopVisibilityHeartbeat() {
    if (!this.visibilityHeartbeat) return
    window.clearInterval(this.visibilityHeartbeat)
    this.visibilityHeartbeat = null
  },

  setFrameSrc(url, reason) {
    if (!this.iframe || !url) return

    this.loadStartedAt = Date.now()
    this.loadedUrl = null
    this.iframe.setAttribute("src", url)
    this.pushTelemetry("iframe_src_assigned", {
      ...this.frameState(),
      diagnostic: reason,
      recovery_attempts: this.recoveryAttempts
    })
    this.scheduleLoadTimeout(reason)
  },

  reloadFrame(reason) {
    const targetUrl =
      this.el.dataset.displayUrl || this.iframe?.dataset.src || this.iframe?.getAttribute("src")

    if (!targetUrl) {
      this.showStatus("src_missing")
      this.pushTelemetry("iframe_load_timeout", {
        ...this.frameState(),
        diagnostic: "src_missing",
        recovery_attempts: this.recoveryAttempts
      })
      return
    }

    this.showStatus("reloading")
    this.setFrameSrc(targetUrl, reason)
  },

  requestReopen(reason) {
    this.clearLoadTimeout()
    this.showStatus("reopening")
    this.pushTelemetry("preview_reopen_requested", {
      ...this.frameState(),
      diagnostic: reason,
      recovery_attempts: this.recoveryAttempts
    })
    this.pushEvent("preview-pane:recover", {
      "pane-id": this.paneId,
      reason
    })
  },

  scheduleLoadTimeout(reason) {
    this.clearLoadTimeout()
    this.loadTimeout = window.setTimeout(() => this.handleLoadTimeout(reason), 4500)
  },

  clearLoadTimeout() {
    if (!this.loadTimeout) return
    window.clearTimeout(this.loadTimeout)
    this.loadTimeout = null
  },

  handleLoadTimeout(reason) {
    this.loadTimeout = null
    const state = this.frameState()
    if (state.loaded) {
      this.hideStatus()
      return
    }

    const diagnostic = this.loadDiagnostic(state)
    this.pushTelemetry("iframe_load_timeout", {
      ...state,
      diagnostic,
      load_ms: this.loadStartedAt ? Date.now() - this.loadStartedAt : null,
      recovery_attempts: this.recoveryAttempts
    })

    if (this.recoveryAttempts === 0) {
      this.recoveryAttempts += 1
      this.reloadFrame(`auto_reload_after_${diagnostic}`)
      return
    }

    if (this.recoveryAttempts === 1) {
      this.recoveryAttempts += 1
      this.requestReopen(`auto_reopen_after_${diagnostic}`)
      return
    }

    this.showStatus(reason || diagnostic)
  },

  loadDiagnostic(state = this.frameState()) {
    if (!state.iframe_src) return "src_missing"
    if (state.loaded_url === "about:blank") return "about_blank"
    if (!state.loaded_url) return "load_timeout"
    return "empty_body"
  },

  showStatus(reason) {
    if (!this.status) return

    const messages = {
      about_blank: "The preview frame loaded a blank document.",
      empty_body: "The preview document loaded but did not render content.",
      load_timeout: "The preview did not finish loading in the browser.",
      reloading: "Reloading the preview frame.",
      reopening: "Replacing the preview pane.",
      src_missing: "The preview frame has no URL to load."
    }

    if (this.statusTitle) this.statusTitle.textContent = "Preview is stalled"
    if (this.statusDetail) {
      this.statusDetail.textContent =
        messages[reason] || messages.load_timeout
    }

    this.status.classList.remove("hidden")
    this.status.classList.add("flex")
  },

  hideStatus() {
    if (!this.status) return
    this.status.classList.add("hidden")
    this.status.classList.remove("flex")
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
    const iframeSrc = this.iframe?.getAttribute("src") || null
    const loadedUrl = this.loadedFrameUrl()

    return {
      url: this.displayUrl,
      iframe_src: iframeSrc,
      loaded_url: loadedUrl,
      loaded: Boolean(iframeSrc && loadedUrl && this.loadedUrl === this.displayUrl),
      width: Math.round(rect.width || 0),
      height: Math.round(rect.height || 0)
    }
  },

  loadedFrameUrl() {
    if (!this.loadedUrl || this.loadedUrl !== this.displayUrl) return null

    try {
      const doc = this.iframe?.contentDocument
      if (!doc) return this.loadedUrl
      if (doc.readyState !== "complete") return null
      const href = this.iframe?.contentWindow?.location?.href
      if (!href || href === "about:blank") return null

      const body = doc.body
      if (!body || (body.children.length === 0 && body.textContent.trim().length === 0)) {
        return null
      }

      return href
    } catch (_err) {
      return this.loadedUrl
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
