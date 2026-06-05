import { acquireTerminalSocket, releaseTerminalSocket } from "./terminal_socket"
import { installTerminalClipboardPaste } from "./terminal_clipboard"

export const GhosttyGovernedTerminal = {
  mounted() {
    this.el._ghosttyGovernedCleanup?.()
    this.el.innerHTML = ""

    this.workspaceId = this.el.dataset.workspaceId
    this.sid = this.el.dataset.sid
    this.token = this.el.dataset.socketToken
    this.workspaceCapability = this.el.dataset.terminalCapability
    this.hostId = this.el.dataset.hostId || "local"
    this.rawSessionSid = this.el.dataset.rawSessionSid || this.sid
    this.pendingRawKey = this._pendingRawKey(this.rawSessionSid)
    this.line = ""
    this.cursorPos = 0
    this.interactiveCommands = new Set(["agent", "claude", "clauded", "codex", "grok", "opencode"])
    this.rawAvailable = false
    this._isPrompting = false
    this.focused = false
    this.cursorBlinkVisible = true
    this.cursorBlinkTimer = null

    this._buildScreen()
    this._connectChannel()
    this.el._ghosttyGovernedCleanup = () => this._cleanup()
  },

  destroyed() {
    this._cleanup()
  },

  _buildScreen() {
    this.el.tabIndex = 0
    this.el.style.position = "relative"
    this.el.style.outline = "none"

    // Scroll container holds history (pre) + current prompt row
    this.scroll = document.createElement("div")
    this.scroll.style.height = "100%"
    this.scroll.style.overflowY = "auto"
    this.scroll.style.overscrollBehavior = "contain"
    this.scroll.style.webkitOverflowScrolling = "touch"
    this.scroll.style.boxSizing = "border-box"

    this.pre = document.createElement("pre")
    this.pre.style.margin = "0"
    this.pre.style.whiteSpace = "pre-wrap"
    this.pre.style.overflow = "visible"
    this.pre.style.font = "var(--devide-terminal-font-size, 13px) ui-monospace, SFMono-Regular, Menlo, monospace"
    this.pre.style.lineHeight = "var(--devide-terminal-line-height, 17px)"
    this.pre.style.color = "#e4e4e7"
    this.pre.style.background = "transparent"
    this.pre.style.padding = "8px 8px 0 8px"
    this.pre.style.boxSizing = "border-box"
    this.pre.style.userSelect = "text"
    this.pre.style.webkitUserSelect = "text"
    this.pre.style.cursor = "text"

    this.promptRow = document.createElement("div")
    this.promptRow.style.font = "var(--devide-terminal-font-size, 13px) ui-monospace, SFMono-Regular, Menlo, monospace"
    this.promptRow.style.lineHeight = "var(--devide-terminal-line-height, 17px)"
    this.promptRow.style.color = "#e4e4e7"
    this.promptRow.style.padding = "0 8px 8px 8px"
    this.promptRow.style.whiteSpace = "pre"
    this.promptRow.style.position = "relative"
    this.promptRow.style.cursor = "text"

    // Offscreen measurer for accurate caret positioning within promptRow
    this.promptMeasure = document.createElement("span")
    this.promptMeasure.style.position = "absolute"
    this.promptMeasure.style.visibility = "hidden"
    this.promptMeasure.style.whiteSpace = "pre"
    this.promptMeasure.style.font = "inherit"
    this.promptMeasure.style.lineHeight = "inherit"
    this.promptMeasure.style.left = "0"
    this.promptMeasure.style.top = "0"
    this.promptRow.appendChild(this.promptMeasure)

    this.input = document.createElement("textarea")
    this.input.setAttribute("aria-label", "Governed terminal input")
    this.input.spellcheck = false
    this.input.autocapitalize = "off"
    this.input.autocomplete = "off"
    this.input.style.position = "absolute"
    this.input.style.opacity = "0"
    this.input.style.left = "0"
    this.input.style.top = "0"
    this.input.style.width = "1px"
    this.input.style.height = "1px"
    this.input.style.resize = "none"
    this.input.style.border = "0"

    this.scroll.appendChild(this.pre)
    this.scroll.appendChild(this.promptRow)
    this.el.appendChild(this.scroll)
    this.el.appendChild(this.input)

    this.onFocus = (e) => {
      // Only auto-focus the hidden input for prompt interaction.
      // Clicks/drags inside the pre/promptRow are for selecting plain output to copy.
      if (e && (e.target === this.pre || this.pre.contains(e.target) || e.target === this.promptRow || this.promptRow.contains(e.target))) {
        return
      }
      this.input.focus()
    }
    this.onKeydown = (event) => this._handleKeydown(event)
    this.onPaste = (event) => this._handlePaste(event)
    this.onMobileInsetChange = () => this._scrollBottom()

    this.onInputFocus = () => {
      this.focused = true
      this.cursorBlinkVisible = true
      this._startCaretBlink()
      this._renderPromptRow()
    }
    this.onInputBlur = () => {
      this.focused = false
      this.cursorBlinkVisible = true
      this._stopCaretBlink()
      this._renderPromptRow()
    }

    this.el.addEventListener("mousedown", this.onFocus)
    this.el.addEventListener("focus", this.onFocus)
    this.input.addEventListener("keydown", this.onKeydown)
    this.input.addEventListener("paste", this.onPaste)
    this.input.addEventListener("focus", this.onInputFocus)
    this.input.addEventListener("blur", this.onInputBlur)
    this.pre.addEventListener("copy", (e) => this._handleCopy(e))
    this.promptRow.addEventListener("copy", (e) => this._handleCopy(e))
    window.addEventListener("devide:mobile-terminal-inset-change", this.onMobileInsetChange)
    this.clipboardCleanup = installTerminalClipboardPaste({
      element: this.el,
      input: this.input,
      isActive: () => this._activeForPaste(),
      sendText: (text) => this._insertPastedText(text),
      uploadFile: (payload) => this._pushLiveEvent("terminal:paste_file", payload),
      pathFormat: "shell",
      onDragState: (active) => this._setDropActive(active),
      onNotice: (message) => this._commitToHistory(`[${message}]\r\n`),
      onError: (message) => this._commitToHistory(`[paste failed] ${message}\r\n`)
    })
    this.input.focus()
  },

  _connectChannel() {
    const socketEntry = acquireTerminalSocket(this.token)
    this.socket = socketEntry.socket
    this.channel = this.socket.channel(`terminal:${this.workspaceId}:${this.sid}`, {
      mode: "governed",
      host_id: this.hostId,
      ...(this.workspaceCapability ? { terminal_capability: this.workspaceCapability } : {})
    })

    this.channel.join()
      .receive("ok", (payload) => this._mount(payload.commands || [], payload.raw_available === true))
      .receive("error", ({ reason }) => this._write(`\r\n[join failed: ${reason}]\r\n`))
  },

  _mount(commands, rawAvailable) {
    this.rawAvailable = rawAvailable
    this._write("\r\n[governed terminal]\r\n")
    if (this._rawShellAvailable()) {
      this._write("Safe actions only. Interactive CLIs open in raw shell.\r\n")
    } else {
      this._write("Safe actions only. Raw shell requires manual/local mode.\r\n")
    }
    const available = ["ide", ...commands.filter((cmd) => cmd !== "ide")]
    if (available.length > 0) this._write(`Available: ${available.join(", ")}\r\n`)
    this._prompt()
  },

  _commitToHistory(text) {
    this.pre.textContent += text.replace(/\x1b\[[0-9;]*m/g, "")
    this._scrollBottom()
  },

  _rawButton() {
    return document.getElementById("terminal-mode-raw")
  },

  _rawShellAvailable() {
    return this.rawAvailable || !!this._rawButton()
  },

  _pendingRawKey(sid) {
    return `devide:pending-raw:${this.workspaceId}:${sid}`
  },

  _openRawShell(command) {
    if (typeof this.pushEvent === "function") {
      this.pushEvent("run:start", { id: command })
      return true
    }

    const rawSessionSid = this.el.dataset.rawSessionSid || this.rawSessionSid || this.sid
    window.sessionStorage.setItem(this._pendingRawKey(rawSessionSid), command)

    const rawButton = this._rawButton()
    if (rawButton) {
      rawButton.click()
      return true
    }

    this.pushEvent("terminal:set_mode", { mode: "raw" })
    return true
  },

  _handleKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this._submit()
    } else if (event.key === "Backspace") {
      event.preventDefault()
      if (this.cursorPos > 0) {
        this.line = this.line.slice(0, this.cursorPos - 1) + this.line.slice(this.cursorPos)
        this.cursorPos = Math.max(0, this.cursorPos - 1)
        this._render()
      }
    } else if (event.key === "Delete") {
      event.preventDefault()
      if (this.cursorPos < this.line.length) {
        this.line = this.line.slice(0, this.cursorPos) + this.line.slice(this.cursorPos + 1)
        this._render()
      }
    } else if (event.key === "ArrowLeft") {
      event.preventDefault()
      if (this.cursorPos > 0) {
        this.cursorPos--
        this._render()
      }
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      if (this.cursorPos < this.line.length) {
        this.cursorPos++
        this._render()
      }
    } else if (event.key === "Home") {
      event.preventDefault()
      this.cursorPos = 0
      this._render()
    } else if (event.key === "End") {
      event.preventDefault()
      this.cursorPos = this.line.length
      this._render()
    } else if ((event.key === "c" && (event.ctrlKey || event.metaKey))) {
      const sel = window.getSelection()?.toString() || ""
      if (sel) {
        event.preventDefault()
        if (navigator.clipboard?.writeText) {
          navigator.clipboard.writeText(sel).catch(() => {})
        } else {
          this.input.value = sel
          this.input.select()
          document.execCommand("copy")
          this.input.value = ""
        }
        return
      }
      event.preventDefault()
      this.line = ""
      this.cursorPos = 0
      this._stopCaretBlink()
      this._commitToHistory("^C\r\n")
      this._prompt()
    } else if (event.key === "l" && event.ctrlKey) {
      event.preventDefault()
      this._stopCaretBlink()
      this.pre.textContent = ""
      this._prompt()
    } else if (event.key.length === 1 && !event.metaKey && !event.ctrlKey) {
      event.preventDefault()
      this.line = this.line.slice(0, this.cursorPos) + event.key + this.line.slice(this.cursorPos)
      this.cursorPos++
      this._render()
    }
  },

  _handlePaste(event) {
    const text = event.clipboardData?.getData("text") || ""
    if (text === "") return
    event.preventDefault()
    this._insertPastedText(text)
  },

  _insertPastedText(text) {
    const inserted = text.replace(/[\r\n]+/g, " ")
    this.line = this.line.slice(0, this.cursorPos) + inserted + this.line.slice(this.cursorPos)
    this.cursorPos += inserted.length
    this._render()
  },

  _activeForPaste() {
    const active = document.activeElement
    return active === this.input || active === this.el || this.el.contains(active)
  },

  _pushLiveEvent(event, payload) {
    return new Promise((resolve) => {
      this.pushEvent(event, payload, (reply) => resolve(reply || {}))
    })
  },

  _setDropActive(active) {
    if (!active) {
      this.dropOverlay?.remove()
      this.dropOverlay = null
      return
    }

    if (this.dropOverlay) return

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

    this.el.appendChild(overlay)
    this.dropOverlay = overlay
  },

  _handleCopy(event) {
    const text = window.getSelection()?.toString() || ""
    if (text === "") return
    event.preventDefault()
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).catch(() => {})
    } else {
      this.input.value = text
      this.input.select()
      document.execCommand("copy")
      this.input.value = ""
    }
  },

  _submit() {
    const submitted = this.line.trim()

    this._stopCaretBlink()

    // Commit the prompt line + what the user typed into scrollback history
    const display = "devide$ " + this.line + "\n"
    this._commitToHistory(display)

    this.line = ""
    this.cursorPos = 0

    if (submitted === "ide") {
      this._commitToHistory("[opening ide palette]\r\n")
      this.pushEvent("palette:ide", {})
      this._prompt()
      return
    }

    if (this.interactiveCommands.has(submitted)) {
      if (this._openRawShell(submitted)) {
        this._commitToHistory(`[opening raw shell] ${submitted}\r\n`)
      } else {
        this._commitToHistory(`[denied] ${submitted} requires raw shell (manual/local mode)\r\n`)
        this._prompt()
      }

      return
    }

    this.channel.push("command", { line: submitted })
      .receive("ok", (payload) => {
        if (payload.status === "queued") {
          const assignment = payload.assignment || {}
          const action = assignment.action || {}
          this._commitToHistory(`[queued] ${action.id || assignment.safe_action_id} assignment ${assignment.id}\r\n`)
        } else if (payload.status === "completed") {
          if (payload.output) this._commitToHistory(payload.output.replace(/\n/g, "\r\n"))
          if (payload.exit_code !== 0) this._commitToHistory(`[exit ${payload.exit_code}]\r\n`)
          if (payload.output_truncated) this._commitToHistory("[output truncated]\r\n")
        }
        this._prompt()
      })
      .receive("error", ({ reason }) => {
        this._commitToHistory(`[denied] ${reason}\r\n`)
        this._prompt()
      })
  },

  _prompt() {
    this._isPrompting = true
    this.line = ""
    this.cursorPos = 0
    this.focused = (document.activeElement === this.input)
    this._renderPromptRow()
    this._startCaretBlink()
    this._scrollBottom()
  },

  _render() {
    if (this._isPrompting) {
      this._renderPromptRow()
    }
  },

  _renderPromptRow() {
    if (!this.promptRow) return
    const promptText = "devide$ "
    const before = this.line.slice(0, this.cursorPos)
    const after = this.line.slice(this.cursorPos)

    this.promptRow.innerHTML = ""
    // Re-append the measurer (it gets removed by innerHTML = "")
    this.promptRow.appendChild(this.promptMeasure)

    const wrapper = document.createElement("span")
    wrapper.style.position = "relative"
    wrapper.style.display = "inline-block"

    const promptSpan = document.createElement("span")
    promptSpan.textContent = promptText
    promptSpan.style.color = "#67e8f9"
    wrapper.appendChild(promptSpan)

    // Measure width of prompt + text before cursor for caret x position
    this.promptMeasure.textContent = promptText + before
    const caretLeft = this.promptMeasure.offsetWidth

    const textSpan = document.createElement("span")
    textSpan.textContent = before + after
    wrapper.appendChild(textSpan)

    const caret = document.createElement("span")
    caret.style.position = "absolute"
    caret.style.top = "0.1em"
    caret.style.bottom = "0.15em"
    caret.style.width = "2px"
    caret.style.backgroundColor = "#e4e4e7"
    caret.style.left = `${caretLeft}px`
    caret.style.zIndex = "3"
    caret.style.pointerEvents = "none"
    if (this.focused) {
      caret.style.opacity = this.cursorBlinkVisible ? "1" : "0"
    } else {
      caret.style.opacity = "0.6"
    }
    wrapper.appendChild(caret)

    this.promptRow.appendChild(wrapper)
  },

  _write(text) {
    this._commitToHistory(text)
  },

  _scrollBottom() {
    this.scroll.scrollTop = this.scroll.scrollHeight
  },

  _startCaretBlink() {
    this._stopCaretBlink()
    if (!this.focused || !this._isPrompting) {
      this.cursorBlinkVisible = true
      return
    }
    this.cursorBlinkTimer = setInterval(() => {
      this.cursorBlinkVisible = !this.cursorBlinkVisible
      this._renderPromptRow()
    }, 600)
  },

  _stopCaretBlink() {
    if (this.cursorBlinkTimer !== null) {
      clearInterval(this.cursorBlinkTimer)
      this.cursorBlinkTimer = null
    }
  },

  _cleanup() {
    this._stopCaretBlink()
    this.el.removeEventListener("mousedown", this.onFocus)
    this.el.removeEventListener("focus", this.onFocus)
    this.input?.removeEventListener("keydown", this.onKeydown)
    this.input?.removeEventListener("paste", this.onPaste)
    this.input?.removeEventListener("focus", this.onInputFocus)
    this.input?.removeEventListener("blur", this.onInputBlur)
    this.clipboardCleanup?.()
    this.clipboardCleanup = null
    this._setDropActive(false)
    this.promptRow?.removeEventListener?.("copy", this._handleCopy)
    window.removeEventListener("devide:mobile-terminal-inset-change", this.onMobileInsetChange)
    this.channel?.leave()
    if (this.socket) {
      releaseTerminalSocket(this.token)
    }
    this.channel = null
    this.socket = null
    this.input = null
    this.pre = null
    this.promptRow = null
    this.scroll = null
    this.promptMeasure = null
    if (this.el._ghosttyGovernedCleanup) this.el._ghosttyGovernedCleanup = null
  }
}
