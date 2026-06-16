import { acquireTerminalSocket, releaseTerminalSocket } from "./terminal_socket"
import { installTerminalClipboardPaste } from "./terminal_clipboard"
import { copyTextSync } from "./terminal_copy"
import {termVar} from "./terminal_themes"

function statusColor(kind) {
  const tokens = {
    muted: "--devide-term-muted",
    success: "--devide-term-success",
    error: "--devide-term-error",
    warning: "--devide-term-warning",
    info: "--devide-term-info"
  }

  return termVar(tokens[kind] || tokens.muted)
}

function selectionTextWithin(...roots) {
  const sel = window.getSelection && window.getSelection()
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return ""

  const range = sel.getRangeAt(0)
  const within = roots.some((root) => {
    if (!root) return false
    if (root.contains(range.commonAncestorContainer)) return true

    try {
      return range.intersectsNode(root)
    } catch (_) {
      return false
    }
  })

  return within ? sel.toString() : ""
}

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
    this.availableCommands = []
    this.rawAvailable = false
    this.commandHistory = []
    this.historyIndex = -1
    this.historyDraft = ""
    this._isPrompting = false
    this.focused = false
    this.cursorBlinkVisible = true
    this.cursorBlinkTimer = null

    this._buildScreen()
    this._connectChannel()
    this.__onTerminalTheme = () => this._applyChromeStyles()
    window.addEventListener("devide:terminal-theme", this.__onTerminalTheme)
    this.el._ghosttyGovernedCleanup = () => this._cleanup()
  },

  destroyed() {
    this._cleanup()
  },

  _applyChromeStyles() {
    if (!this.el) return

    this.el.style.background = termVar("--devide-term-bg") || "#0a0a0a"
    this.el.style.border = `1px solid ${termVar("--devide-term-border") || "#27272a"}`

    if (this.pre) {
      this.pre.style.color = termVar("--devide-term-fg") || "#e4e4e7"
    }

    if (this.promptRow) {
      this.promptRow.style.color = termVar("--devide-term-fg") || "#e4e4e7"
      this.promptRow.style.borderTop =
        `1px solid ${termVar("--devide-term-prompt-border") || "#18181b"}`
    }

    if (this.focused) {
      this.el.style.boxShadow =
        `inset 0 0 0 1px ${termVar("--devide-term-focus-ring") || "#3b82f6"}`
    }

    if (this._isPrompting) {
      this._renderPromptRow()
    }
  },

  _buildScreen() {
    this.el.tabIndex = 0
    this.el.style.position = "relative"
    this.el.style.outline = "none"
    this.el.style.borderRadius = "6px"

    // Scroll container holds history (pre) + current prompt row
    this.scroll = document.createElement("div")
    this.scroll.style.height = "100%"
    this.scroll.style.overflowY = "auto"
    this.scroll.style.boxSizing = "border-box"

    this.pre = document.createElement("pre")
    this.pre.style.margin = "0"
    this.pre.style.whiteSpace = "pre-wrap"
    this.pre.style.overflow = "visible"
    this.pre.style.font = "13px ui-monospace, SFMono-Regular, Menlo, monospace"
    this.pre.style.lineHeight = "1.35"
    this.pre.style.background = "transparent"
    this.pre.style.padding = "10px 10px 4px 10px"
    this.pre.style.boxSizing = "border-box"
    this.pre.style.userSelect = "text"
    this.pre.style.webkitUserSelect = "text"
    this.pre.style.cursor = "text"

    this.promptRow = document.createElement("div")
    this.promptRow.style.font = "13px ui-monospace, SFMono-Regular, Menlo, monospace"
    this.promptRow.style.lineHeight = "1.35"
    this.promptRow.style.padding = "6px 10px 10px 10px"
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
    this.onSelectionEnd = () => {}

    this.onInputFocus = () => {
      this.focused = true
      this.cursorBlinkVisible = true
      this.el.style.boxShadow =
        `inset 0 0 0 1px ${termVar("--devide-term-focus-ring") || "#3b82f6"}`
      this._startCaretBlink()
      this._renderPromptRow()
    }
    this.onInputBlur = () => {
      this.focused = false
      this.cursorBlinkVisible = true
      this.el.style.boxShadow = "none"
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
    this.scroll.addEventListener("mouseup", this.onSelectionEnd, true)
    this.scroll.addEventListener("touchend", this.onSelectionEnd, true)
    this.clipboardCleanup = installTerminalClipboardPaste({
      element: this.el,
      input: this.input,
      isActive: () => this._activeForPaste(),
      sendText: (text) => this._insertPastedText(text),
      uploadImage: (payload) => this._pushLiveEvent("terminal:paste_image", payload),
      uploadFile: (payload) => this._pushLiveEvent("terminal:paste_file", payload),
      pathFormat: "shell",
      onDragState: (active) => this._setDropActive(active),
      onNotice: (message) => this._appendStatus(`[${message}]\r\n`, statusColor("muted")),
      onError: (message) => this._appendStatus(`[paste failed] ${message}\r\n`, statusColor("error"))
    })
    this._applyChromeStyles()
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
    this.availableCommands = Array.isArray(commands) ? commands : []
    this.rawAvailable = rawAvailable
    this._appendStatus("\r\n[governed]\r\n", statusColor("muted"))
    if (this._rawShellAvailable()) {
      this._commitToHistory("Safe commands only. Type 'help' for list. Interactive CLIs open raw shell.\r\n")
    } else {
      this._commitToHistory("Safe commands only. Type 'help' for list. Raw shell requires manual/local mode.\r\n")
    }
    if (this.availableCommands.length > 0) {
      const preview = this.availableCommands.slice(0, 6).join(", ")
      this._appendStatus(`Examples: ${preview}${this.availableCommands.length > 6 ? ", …" : ""}\r\n`, statusColor("muted"))
    }
    this._prompt()
  },

  _commitToHistory(text) {
    const clean = text.replace(/\x1b\[[0-9;]*m/g, "")
    const node = document.createTextNode(clean)
    this.pre.appendChild(node)
    this._scrollBottom()
  },

  _appendStatus(text, color) {
    const span = document.createElement("span")
    span.style.color = color
    span.textContent = text
    this.pre.appendChild(span)
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
    // Gate client-side: raw shell only exists in manual/local mode. Without
    // this check we'd optimistically print "[opening raw shell]" and push
    // set_mode, only for the backend to deny it with a red error toast.
    if (!this._rawShellAvailable()) {
      return false
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
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this._navigateHistory(-1)
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      this._navigateHistory(1)
    } else if (event.key === "Escape") {
      event.preventDefault()
      if (this.historyIndex !== -1) {
        this.line = this.historyDraft
        this.cursorPos = this.line.length
        this.historyIndex = -1
        this._render()
      } else if (this.line.length > 0) {
        this.line = ""
        this.cursorPos = 0
        this._render()
      }
    } else if (event.key === "Tab") {
      event.preventDefault()
      this._completeCommand()
    } else if ((event.key === "c" && (event.ctrlKey || event.metaKey))) {
      const sel = selectionTextWithin(this.pre, this.promptRow)
      if (sel) {
        event.preventDefault()
        copyTextSync(sel, this.input)
        return
      }
      event.preventDefault()
      this.line = ""
      this.cursorPos = 0
      this._stopCaretBlink()
      this._appendStatus("^C\r\n", statusColor("error"))
      this._prompt()
    } else if (event.key === "l" && event.ctrlKey) {
      event.preventDefault()
      this._stopCaretBlink()
      this.pre.textContent = ""
      this._prompt()
    } else if (event.ctrlKey && event.key.toLowerCase() === "a") {
      event.preventDefault()
      this.cursorPos = 0
      this._render()
    } else if (event.ctrlKey && event.key.toLowerCase() === "e") {
      event.preventDefault()
      this.cursorPos = this.line.length
      this._render()
    } else if (event.ctrlKey && event.key.toLowerCase() === "k") {
      event.preventDefault()
      if (this.cursorPos < this.line.length) {
        this.line = this.line.slice(0, this.cursorPos)
        this._render()
      }
    } else if (event.ctrlKey && event.key.toLowerCase() === "u") {
      event.preventDefault()
      this.line = this.line.slice(this.cursorPos)
      this.cursorPos = 0
      this._render()
    } else if (event.ctrlKey && event.key.toLowerCase() === "w") {
      event.preventDefault()
      this._deleteWordBackward()
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

  _navigateHistory(direction) {
    if (this.commandHistory.length === 0) return
    if (this.historyIndex === -1) {
      this.historyDraft = this.line
      this.historyIndex = this.commandHistory.length - 1
    } else {
      this.historyIndex += direction
    }
    if (this.historyIndex < 0) this.historyIndex = 0
    if (this.historyIndex >= this.commandHistory.length) {
      this.line = this.historyDraft
      this.historyIndex = -1
    } else {
      this.line = this.commandHistory[this.historyIndex]
    }
    this.cursorPos = this.line.length
    this._render()
  },

  _deleteWordBackward() {
    if (this.cursorPos === 0) return
    const before = this.line.slice(0, this.cursorPos)
    const after = this.line.slice(this.cursorPos)
    const trimmed = before.trimEnd()
    const lastSpace = trimmed.lastIndexOf(" ")
    const newBefore = lastSpace >= 0 ? trimmed.slice(0, lastSpace + 1) : ""
    this.line = newBefore + after
    this.cursorPos = newBefore.length
    this._render()
  },

  _commonPrefix(strings) {
    if (!strings.length) return ""
    let prefix = strings[0]
    for (const s of strings) {
      while (prefix && !s.startsWith(prefix)) {
        prefix = prefix.slice(0, -1)
      }
      if (!prefix) break
    }
    return prefix
  },

  _completeCommand() {
    const cmds = this.availableCommands || []
    if (cmds.length === 0 || this.cursorPos !== this.line.length) return
    const partial = this.line
    if (!partial) return
    const matches = cmds.filter((c) => c.startsWith(partial))
    if (matches.length === 1) {
      this.line = matches[0]
      this.cursorPos = this.line.length
      this._render()
    } else if (matches.length > 1) {
      const common = this._commonPrefix(matches)
      if (common.length > partial.length) {
        this.line = common
        this.cursorPos = this.line.length
        this._render()
      } else {
        // ambiguous: show matches below current prompt line
        this._commitToHistory("\n")
        this._appendStatus(matches.join("  ") + "\n", statusColor("muted"))
        this._scrollBottom()
      }
    }
  },

  _showLocalHelp() {
    const list = this.availableCommands && this.availableCommands.length
      ? this.availableCommands.join("  ")
      : "(no commands advertised)"
    this._appendStatus("Commands:\n", statusColor("info"))
    this._commitToHistory("  " + list + "\n")
    if (this._rawShellAvailable()) {
      this._appendStatus("Interactive CLIs open raw shell.\n", statusColor("muted"))
    } else {
      this._appendStatus("Raw shell requires manual/local mode.\n", statusColor("muted"))
    }
    this._appendStatus("Built-ins: clear, help, ?   |   history: ↑/↓   |   edit: ctrl-a/e/k/u/w, tab-complete\n", statusColor("muted"))
  },

  _handleCopy(event) {
    const text = selectionTextWithin(this.pre, this.promptRow)
    if (text === "") return
    event.preventDefault()
    copyTextSync(text, this.input)
  },

  _submit() {
    const submitted = this.line.trim()

    this._stopCaretBlink()

    // Commit the prompt line + what the user typed into scrollback history
    const display = "devide$ " + this.line + "\n"
    this._commitToHistory(display)

    this.line = ""
    this.cursorPos = 0

    // Local commands (never sent to server)
    if (submitted === "clear" || submitted === "cls") {
      this.pre.textContent = ""
      this._prompt()
      return
    }
    if (submitted === "help" || submitted === "?") {
      this._showLocalHelp()
      this._prompt()
      return
    }

    if (submitted === "ide") {
      this._appendStatus("Opening command palette…\r\n", "#67e8f9")
      this.pushEvent("palette:ide", {})
      this._prompt()
      return
    }

    // Record in command history (edited recalls count as new entry)
    if (submitted && submitted !== this.commandHistory[this.commandHistory.length - 1]) {
      this.commandHistory.push(submitted)
      if (this.commandHistory.length > 200) this.commandHistory.shift()
    }
    this.historyIndex = -1
    this.historyDraft = ""

    // Match the command word, not the whole line, so an interactive command
    // with arguments (e.g. `claude --resume`, `codex exec "…"`) is also routed
    // into the raw shell. The full line is what we hand off to the raw PTY.
    const commandWord = submitted.split(/\s+/)[0]
    if (this.interactiveCommands.has(commandWord)) {
      if (this._openRawShell(submitted)) {
        this._appendStatus(`[opening raw shell] ${submitted}\r\n`, statusColor("warning"))
      } else {
        this._appendStatus(`[denied] ${submitted} requires raw shell (manual/local mode)\r\n`, statusColor("error"))
        this._prompt()
      }

      return
    }

    this.channel.push("command", { line: submitted })
      .receive("ok", (payload) => {
        if (payload.status === "queued") {
          const assignment = payload.assignment || {}
          const action = assignment.action || {}
          this._appendStatus(`[queued] ${action.id || assignment.safe_action_id} assignment ${assignment.id}\r\n`, statusColor("success"))
        } else if (payload.status === "completed") {
          if (payload.output) this._commitToHistory(payload.output.replace(/\n/g, "\r\n"))
          if (payload.exit_code !== 0) this._appendStatus(`[exit ${payload.exit_code}]\r\n`, statusColor("warning"))
          if (payload.output_truncated) this._appendStatus("[output truncated]\r\n", statusColor("muted"))
        }
        this._prompt()
      })
      .receive("error", ({ reason }) => {
        this._appendStatus(`[denied] ${reason}\r\n`, statusColor("error"))
        this._prompt()
      })
  },

  _prompt() {
    this._isPrompting = true
    this.line = ""
    this.cursorPos = 0
    this.historyIndex = -1
    this.historyDraft = ""
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
    promptSpan.textContent = "devide"
    promptSpan.style.color = termVar("--devide-term-prompt") || "#67e8f9"
    wrapper.appendChild(promptSpan)
    const dollar = document.createElement("span")
    dollar.textContent = "$ "
    dollar.style.color = termVar("--devide-term-muted") || "#64748b"
    wrapper.appendChild(dollar)

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
    caret.style.backgroundColor = termVar("--devide-term-cursor") || "#e4e4e7"
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
    if (this.__onTerminalTheme) {
      window.removeEventListener("devide:terminal-theme", this.__onTerminalTheme)
      this.__onTerminalTheme = null
    }

    this._stopCaretBlink()
    this.el.removeEventListener("mousedown", this.onFocus)
    this.el.removeEventListener("focus", this.onFocus)
    this.input?.removeEventListener("keydown", this.onKeydown)
    this.input?.removeEventListener("paste", this.onPaste)
    this.input?.removeEventListener("focus", this.onInputFocus)
    this.input?.removeEventListener("blur", this.onInputBlur)
    this.scroll?.removeEventListener("mouseup", this.onSelectionEnd, true)
    this.scroll?.removeEventListener("touchend", this.onSelectionEnd, true)
    this.clipboardCleanup?.()
    this.clipboardCleanup = null
    this._setDropActive(false)
    this.promptRow?.removeEventListener?.("copy", this._handleCopy)
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
