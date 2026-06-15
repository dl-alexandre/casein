export const PreviewPaneOverlay = {
  mounted() {
    this.paneId = this.el.dataset.paneId
    this.entered = false
    this.shield = this.el.querySelector("[data-preview-shield]")
    this.clip = this.el.querySelector("[data-preview-clip]")
    this.iframe = this.el.querySelector("iframe[data-preview-iframe]")
    this.viewport = this.parseViewport(this.el.dataset.viewport)

    this.applyRect()
    this.applyViewportMode()
    this.bindShield()
    this.bindExitGuards()
    this.setInteractive()
  },

  updated() {
    this.applyRect()
    this.applyViewportMode()
  },

  destroyed() {
    this.teardownExitGuards()
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
      pointerEvents: "none",
      contain: "layout"
    })
  },

  applyViewportMode() {
    if (!this.clip || !this.iframe) return

    if (this.viewport) {
      this.clip.style.overflow = "hidden"
      this.clip.style.width = "100%"
      this.clip.style.height = "100%"
      this.iframe.style.width = `${this.viewport.width}px`
      this.iframe.style.height = `${this.viewport.height}px`
      this.iframe.style.border = "0"
      this.iframe.style.transform = "none"
    } else {
      this.clip.style.overflow = "hidden"
      this.clip.style.width = "100%"
      this.clip.style.height = "100%"
      this.iframe.style.width = "100%"
      this.iframe.style.height = "100%"
      this.iframe.style.border = "0"
      this.iframe.style.transform = "none"
    }
  },

  bindShield() {
    if (!this.shield) return

    this.shield.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()

      if (this.entered) return

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

  enter() {
    if (this.entered) return
    this.entered = true
    this.setInteractive()
    this.el.classList.add("preview-pane-entered")
    this.applyRect()
    this.pushEvent("preview-pane:enter", { "pane-id": this.paneId })
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

  setInteractive() {
    if (this.shield) this.shield.style.pointerEvents = "none"
    if (this.iframe) this.iframe.style.pointerEvents = "auto"
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
  }
}
