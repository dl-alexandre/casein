import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Socket } from "phoenix"

export const TerminalHook = {
  mounted() {
    const workspaceId = this.el.dataset.workspaceId
    const sid = this.el.dataset.sid
    const token = this.el.dataset.socketToken

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
    const channel = socket.channel(`terminal:${workspaceId}:${sid}`, {})

    channel.on("data", ({ data }) => term.write(data))
    channel.on("exit", ({ reason }) => term.write(`\r\n[session exited: ${reason}]\r\n`))

    channel.join()
      .receive("ok", ({ cols, rows }) => {
        const sendResize = () => {
          fit.fit()
          channel.push("resize", { cols: term.cols, rows: term.rows })
        }
        sendResize()
        this._resizeObserver = new ResizeObserver(() => sendResize())
        this._resizeObserver.observe(this.el)
        term.onData(data => channel.push("input", { data }))
      })
      .receive("error", ({ reason }) => {
        term.write(`\r\n[join failed: ${reason}]\r\n`)
      })

    this._term = term
    this._channel = channel
    this._socket = socket
  },

  destroyed() {
    this._resizeObserver?.disconnect()
    this._channel?.leave()
    this._socket?.disconnect()
    this._term?.dispose()
  }
}
