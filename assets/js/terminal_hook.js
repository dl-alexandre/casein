import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { acquireTerminalSocket, releaseTerminalSocket } from "./terminal_socket"
import { installTerminalClipboardPaste } from "./terminal_clipboard"

export const TerminalHook = {
  mounted() {
    this.el._terminalHookCleanup?.()
    this.el.innerHTML = ""

    const workspaceId = this.el.dataset.workspaceId
    const sid = this.el.dataset.sid
    const token = this.el.dataset.socketToken
    const workspaceCapability = this.el.dataset.terminalCapability
    const mode = this.el.dataset.terminalMode || "governed"
    const hostId = this.el.dataset.hostId || "local"
    const rawSessionSid = this.el.dataset.rawSessionSid || sid
    const pendingRawKey = `devide:pending-raw:${workspaceId}:${rawSessionSid}`

    const term = new Terminal({
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      cursorBlink: true,
      cursorStyle: "bar",
      cursorWidth: 2,
      scrollback: 5000,
      convertEol: false,
      theme: {
        background: "#0a0a0a",
        cursor: "#e4e4e7",
        cursorAccent: "#0a0a0a"
      }
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(this.el)
    fit.fit()

    const socketEntry = acquireTerminalSocket(token)
    const socket = socketEntry.socket
    const channel = socket.channel(`terminal:${workspaceId}:${sid}`, {
      mode,
      host_id: hostId,
      ...(workspaceCapability ? { terminal_capability: workspaceCapability } : {})
    })

    channel.on("data", (payload) => this._handleTerminalData(term, payload))
    channel.on("exit", ({ reason }) => term.write(`\r\n[session exited: ${reason}]\r\n`))

    channel.join()
      .receive("ok", (payload) => {
        if (payload.mode === "raw") {
          this._mountRawTerminal(term, fit, channel, pendingRawKey)
        } else {
          this._mountGovernedTerminal(term, channel, payload.commands || [], pendingRawKey, payload.raw_available === true)
        }
      })
      .receive("error", ({ reason }) => {
        term.write(`\r\n[join failed: ${reason}]\r\n`)
      })

    this._term = term
    this._channel = channel
    this._socket = socket
    this._socketToken = token
    this._replayTimers = []
    this._clipboardCleanups = []
    // Ensure relative positioning once at mount so badge overlay works
    // without mutating layout on every replay or affecting static parents.
    this.el.style.position = this.el.style.position || "relative"
    this.el._terminalHookCleanup = () => this._cleanupTerminal()
  },

  _mountRawTerminal(term, fit, channel, pendingRawKey) {
    // Measure + update xterm immediately; debounce the PTY resize to avoid
    // a resize syscall on every ResizeObserver tick during a window drag.
    let resizeTimer = null
    const sendResize = () => {
      fit.fit()
      clearTimeout(resizeTimer)
      resizeTimer = setTimeout(
        () => channel.push("resize", { cols: term.cols, rows: term.rows }),
        50
      )
    }

    fit.fit()
    channel.push("resize", { cols: term.cols, rows: term.rows })
    this._resizeObserver = new ResizeObserver(() => sendResize())
    this._resizeObserver.observe(this.el)
    this._dataDisposable = term.onData(data => {
      if (!this._isTerminalResponse(data)) channel.push("input", { data })
    })
    this._clipboardCleanups.push(installTerminalClipboardPaste({
      element: this.el,
      input: this.el.querySelector(".xterm-helper-textarea"),
      isActive: () => this._activeForPaste(),
      sendText: (text) => channel.push("input", { data: text }),
      uploadImage: (payload) => this._pushLiveEvent("terminal:paste_image", payload),
      uploadFile: (payload) => this._pushLiveEvent("terminal:paste_file", payload),
      bracketedPaste: true,
      pathFormat: "shell",
      onNotice: (message) => term.write(`\r\n[${message}]\r\n`),
      onError: (message) => term.write(`\r\n[paste failed] ${message}\r\n`)
    }))

    const pending = window.sessionStorage.getItem(pendingRawKey)
    if (pending) {
      window.sessionStorage.removeItem(pendingRawKey)
      window.setTimeout(() => channel.push("input", { data: `${pending}\r` }), 50)
    }
  },

  _mountGovernedTerminal(term, channel, commands, pendingRawKey, rawAvailable) {
    let line = ""
    const prompt = "\x1b[36mdevide\x1b[0m$ "
    const interactiveCommands = new Set(["agent", "claude", "clauded", "codex", "grok", "opencode"])

    const rawButton = () => document.getElementById("terminal-mode-raw")
    const writePrompt = () => term.write(prompt)
    const writeHelp = () => {
      term.write("\r\n[governed terminal]\r\n")
      if (rawAvailable || rawButton()) {
        term.write("Safe actions only. Interactive CLIs open raw shell.\r\n")
      } else {
        term.write("Safe actions only. Raw shell requires manual/local mode.\r\n")
      }
      if (commands.length > 0) {
        term.write(`Available: ${commands.join(", ")}\r\n`)
      }
      writePrompt()
    }

    const submit = () => {
      const submitted = line
      line = ""
      term.write("\r\n")

      if (interactiveCommands.has(submitted.trim())) {
        const button = rawButton()

        window.sessionStorage.setItem(pendingRawKey, submitted.trim())
        term.write(`[opening raw shell] ${submitted.trim()}\r\n`)
        if (button) button.click()
        else this.pushEvent("terminal:set_mode", { mode: "raw" })

        return
      }

      channel.push("command", { line: submitted })
        .receive("ok", (payload) => {
          if (payload.status === "queued") {
            const assignment = payload.assignment || {}
            const action = assignment.action || {}
            term.write(`[queued] ${action.id || assignment.safe_action_id} assignment ${assignment.id}\r\n`)
          } else if (payload.status === "completed") {
            if (payload.output) term.write(payload.output.replace(/\n/g, "\r\n"))
            if (payload.exit_code !== 0) term.write(`[exit ${payload.exit_code}]\r\n`)
            if (payload.output_truncated) term.write("[output truncated]\r\n")
          }
          writePrompt()
        })
        .receive("error", ({ reason }) => {
          term.write(`[denied] ${reason}\r\n`)
          writePrompt()
        })
    }

    const backspace = () => {
      if (line.length > 0) {
        line = line.slice(0, -1)
        term.write("\b \b")
      }
    }

    const appendPrintable = (ch) => {
      if (ch >= " " && ch !== "\x7f") {
        line += ch
        term.write(ch)
      }
    }

    writeHelp()

    const handleChar = (ch) => {
      if (ch === "\r") {
        submit()
      } else if (ch === "\u007f") {
        backspace()
      } else if (ch === "\u0003") {
        line = ""
        term.write("^C\r\n")
        writePrompt()
      } else if (ch === "\u000c") {
        term.clear()
        writePrompt()
      } else {
        appendPrintable(ch)
      }
    }

    this._dataDisposable = term.onData(data => {
      if (data.startsWith("\x1b")) {
        // Ignore cursor/navigation escape sequences in governed line mode.
      } else {
        for (const ch of data) {
          handleChar(ch)
        }
      }
    })
    this._clipboardCleanups.push(installTerminalClipboardPaste({
      element: this.el,
      input: this.el.querySelector(".xterm-helper-textarea"),
      isActive: () => this._activeForPaste(),
      sendText: (text) => {
        for (const ch of text.replace(/\r\n/g, "\n")) {
          handleChar(ch === "\n" || ch === "\r" ? "\r" : ch)
        }
      },
      uploadImage: (payload) => this._pushLiveEvent("terminal:paste_image", payload),
      uploadFile: (payload) => this._pushLiveEvent("terminal:paste_file", payload),
      pathFormat: "shell",
      onNotice: (message) => term.write(`\r\n[${message}]\r\n`),
      onError: (message) => term.write(`\r\n[paste failed] ${message}\r\n`)
    }))
  },

  destroyed() {
    this._cleanupTerminal()
  },

  _cleanupTerminal() {
    this._resizeObserver?.disconnect()
    this._dataDisposable?.dispose()
    ;(this._clipboardCleanups || []).forEach((cleanup) => cleanup())
    this._channel?.leave()
    if (this._socket) {
      releaseTerminalSocket(this._socketToken)
    }
    this._term?.dispose()
    // Clear any pending replay chunk/badge timers (prevents execution after
    // term dispose or element removal during long reconnect replays).
    ;(this._replayTimers || []).forEach((id) => clearTimeout(id))
    this._replayTimers = []
    this._resizeObserver = null
    this._dataDisposable = null
    this._clipboardCleanups = []
    this._channel = null
    this._socket = null
    this._term = null
    if (this.el._terminalHookCleanup) this.el._terminalHookCleanup = null
  },

  _isTerminalResponse(data) {
    return /^\x1bP>\|[^\x1b]*(?:\x1b\\|\x9c)$/.test(data) ||
      /^\x1b\[\?1;2c$/.test(data) ||
      /^\x1b\[>0;\d+;0c$/.test(data) ||
      /^\x1b\]1[01];rgb:[0-9a-f/]+\x1b\\$/i.test(data) ||
      data === "\x1b[O"
  },

  _activeForPaste() {
    const active = document.activeElement
    if (active === this.el || this.el.contains(active)) return true
    if (active && active !== document.body && active !== document.documentElement) return false
    return true
  },

  _pushLiveEvent(event, payload) {
    return new Promise((resolve) => {
      this.pushEvent(event, payload, (reply) => resolve(reply || {}))
    })
  },

  // Reconnect UX: visually distinguish replay frames from owner (rich marker
  // with replay_frame + state_marker). Uses delayed chunked append (backpressure
  // feel) + transient "replay" badge. Muted effect via short-lived overlay.
  // Chunk timing synced with Elixir constants in session_owner.ex.
  _handleTerminalData(term, payload) {
    if (!payload || !payload.data) {
      if (typeof payload === "string") term.write(payload)
      return
    }
    if (payload.replay_frame || payload.replay) {
      this._renderReplayFrame(term, payload.data, payload.state_marker)
    } else {
      term.write(payload.data)
    }
  },

  _renderReplayFrame(term, data, _marker) {
    // Transient badge (works alongside xterm; positioned relative to hook el)
    const badge = document.createElement("div")
    badge.textContent = "⟳ replay"
    badge.style.cssText =
      "position:absolute;top:6px;right:8px;font:10px/1 ui-monospace,monospace;" +
      "background:rgba(63,63,70,.85);color:#a1a1aa;padding:1px 6px;border-radius:3px;" +
      "pointer-events:none;z-index:20;opacity:.9"
    // xterm may cover; append to el and remove soon (position set once in mounted)
    this.el.appendChild(badge)
    const badgeTimer = setTimeout(() => { try { badge.remove() } catch (_) {} }, 1100)
    this._replayTimers.push(badgeTimer)

    // Delayed append: small chunks for visible "replay streaming" effect on reconnect.
    // Matches server-side @replay_chunk_size / @replay_chunk_delay_ms in
    // lib/dev_ide/terminals/session_owner.ex (and the 5 ms stagger comment there).
    // 96 bytes/chunk * 5 ms keeps it snappy but distinguishable from live.
    const chunkSize = 96
    for (let i = 0; i < data.length; i += chunkSize) {
      const chunk = data.slice(i, i + chunkSize)
      const writeTimer = setTimeout(() => { try { term.write(chunk) } catch (_) {} }, Math.floor(i / chunkSize) * 5)
      this._replayTimers.push(writeTimer)
    }
  }
}
