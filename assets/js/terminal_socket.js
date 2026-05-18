import {Socket} from "phoenix"

const registry = (window.__devIdeTerminalSockets = window.__devIdeTerminalSockets || {})

function socketKey(token) {
  return `token:${token || "anon"}`
}

export function acquireTerminalSocket(token) {
  const key = socketKey(token)
  const existing = registry[key]

  if (existing) {
    existing.refCount += 1
    return existing
  }

  const socket = new Socket("/socket", {params: {token}})
  socket.connect()

  const entry = {
    socket,
    refCount: 1
  }

  registry[key] = entry
  return entry
}

export function releaseTerminalSocket(token) {
  const key = socketKey(token)
  const entry = registry[key]

  if (!entry) return

  if (entry.refCount > 0) {
    entry.refCount -= 1
  }

  if (entry.refCount <= 0) {
    entry.socket.disconnect()
    delete registry[key]
  }
}
