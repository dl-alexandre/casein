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
    this.applyDisplayUrl()
    this.applyViewportMode()
    this.bindSelection()
    this.bindShield()
    this.bindExitGuards()
    this.bindResizeObserver()
    this.setInteractive()
  },

  updated() {
    this.snapshotMode = this.isSnapshotMode()
    this.applyRect()
    this.applyDisplayUrl()
    this.applyViewportMode()
    this.setInteractive()
  },

  destroyed() {
    this.teardownExitGuards()
    this.teardownResizeObserver()
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
    if (!this.clip || !this.viewport?.width) return 1

    const availableWidth = this.clip.clientWidth
    if (!availableWidth) return 1

    return Math.min(1, availableWidth / this.viewport.width)
  },

  applyDisplayUrl() {
    if (!this.iframe) return

    const nextUrl = this.el.dataset.displayUrl
    if (!nextUrl || nextUrl === this.displayUrl) return

    this.displayUrl = nextUrl
    if (this.iframe.getAttribute("src") !== nextUrl) {
      this.iframe.setAttribute("src", nextUrl)
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
