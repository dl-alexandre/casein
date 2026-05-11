import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

export const TerminalHook = {
  mounted() {
    const workspaceId = this.el.dataset.workspaceId
    const sid = this.el.dataset.sid
    const token = this.el.dataset.socketToken
    const mode = this.el.dataset.terminalMode || "governed"
    const hostId = this.el.dataset.hostId || "local"

    const term = new Terminal({
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      cursorBlink: true,
      scrollback: 5000,
      convertEol: false,
      theme: { background: "#0a0a0a" }
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(this.el)
    fit.fit()

    const socket = new Socket("/socket", { params: { token } })
    socket.connect()
    const channel = socket.channel(`terminal:${workspaceId}:${sid}`, { mode, host_id: hostId })

    channel.on("data", ({ data }) => term.write(data))
    channel.on("exit", ({ reason }) => term.write(`\r\n[session exited: ${reason}]\r\n`))

    channel.join()
      .receive("ok", (payload) => {
        if (payload.mode === "raw") {
          this._mountRawTerminal(term, fit, channel)
        } else {
          this._mountGovernedTerminal(term, channel, payload.commands || [])
        }
      })
      .receive("error", ({ reason }) => {
        term.write(`\r\n[join failed: ${reason}]\r\n`)
      })

    this._term = term
    this._channel = channel
    this._socket = socket
  },

  _mountRawTerminal(term, fit, channel) {
    const sendResize = () => {
      fit.fit()
      channel.push("resize", { cols: term.cols, rows: term.rows })
    }

    sendResize()
    this._resizeObserver = new ResizeObserver(() => sendResize())
    this._resizeObserver.observe(this.el)
    this._dataDisposable = term.onData(data => channel.push("input", { data }))
  },

  _mountGovernedTerminal(term, channel, commands) {
    let line = ""
    const prompt = "\x1b[36mdevide\x1b[0m$ "

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

      channel.push("command", { line: submitted })
        .receive("ok", (payload) => {
          if (payload.status === "queued") {
            const assignment = payload.assignment || {}
            const action = assignment.action || {}
            term.write(`[queued] ${action.id || assignment.safe_action_id} assignment ${assignment.id}\r\n`)
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
    this._resizeObserver?.disconnect()
    this._dataDisposable?.dispose()
    this._channel?.leave()
    this._socket?.disconnect()
    this._term?.dispose()
  }
}
