import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

export const TerminalHook = {
  mounted() {
    this.el._terminalHookCleanup?.()
    this.el.innerHTML = ""

    const workspaceId = this.el.dataset.workspaceId
    const sid = this.el.dataset.sid
    const token = this.el.dataset.socketToken
    const mode = this.el.dataset.terminalMode || "governed"
    const hostId = this.el.dataset.hostId || "local"
    const pendingRawKey = `devide:pending-raw:${workspaceId}:${sid}`

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

    const socket = new Socket("/socket", { params: { token } })
    socket.connect()
    const channel = socket.channel(`terminal:${workspaceId}:${sid}`, {
      mode,
      host_id: hostId
    })

    channel.on("data", ({ data }) => term.write(data))
    channel.on("exit", ({ reason }) => term.write(`\r\n[session exited: ${reason}]\r\n`))

    channel.join()
      .receive("ok", (payload) => {
        if (payload.mode === "raw") {
          this._mountRawTerminal(term, fit, channel, pendingRawKey)
        } else {
          this._mountGovernedTerminal(term, channel, payload.commands || [], pendingRawKey)
        }
      })
      .receive("error", ({ reason }) => {
        term.write(`\r\n[join failed: ${reason}]\r\n`)
      })

    this._term = term
    this._channel = channel
    this._socket = socket
    this.el._terminalHookCleanup = () => this._cleanupTerminal()
  },

  _mountRawTerminal(term, fit, channel, pendingRawKey) {
    const sendResize = () => {
      fit.fit()
      channel.push("resize", { cols: term.cols, rows: term.rows })
    }

    sendResize()
    this._resizeObserver = new ResizeObserver(() => sendResize())
    this._resizeObserver.observe(this.el)
    this._dataDisposable = term.onData(data => {
      if (!this._isTerminalResponse(data)) channel.push("input", { data })
    })

    const pending = window.sessionStorage.getItem(pendingRawKey)
    if (pending) {
      window.sessionStorage.removeItem(pendingRawKey)
      window.setTimeout(() => channel.push("input", { data: `${pending}\r` }), 50)
    }
  },

  _mountGovernedTerminal(term, channel, commands, pendingRawKey) {
    let line = ""
    const prompt = "\x1b[36mdevide\x1b[0m$ "
    const interactiveCommands = new Set(["claude", "clauded", "codex", "grok", "opencode"])

    const writePrompt = () => term.write(prompt)
    const writeHelp = () => {
      term.write("\r\n[governed terminal]\r\n")
      term.write("Safe actions only. Raw shell requires manual/local mode.\r\n")
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
        const rawButton = document.getElementById("terminal-mode-raw")

        if (rawButton) {
          window.sessionStorage.setItem(pendingRawKey, submitted.trim())
          term.write(`[opening raw shell] ${submitted.trim()}\r\n`)
          rawButton.click()
        } else {
          term.write("[denied] raw shell is not available for this workspace\r\n")
          writePrompt()
        }

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
  },

  destroyed() {
    this._cleanupTerminal()
  },

  _cleanupTerminal() {
    this._resizeObserver?.disconnect()
    this._dataDisposable?.dispose()
    this._channel?.leave()
    this._socket?.disconnect()
    this._term?.dispose()
    this._resizeObserver = null
    this._dataDisposable = null
    this._channel = null
    this._socket = null
    this._term = null
    if (this.el._terminalHookCleanup) this.el._terminalHookCleanup = null
  },

  _isTerminalResponse(data) {
    return /^\x1b\[\?1;2c$/.test(data) ||
      /^\x1b\[>0;\d+;0c$/.test(data) ||
      /^\x1b\]1[01];rgb:[0-9a-f/]+\x1b\\$/i.test(data) ||
      data === "\x1b[O"
  }
}
