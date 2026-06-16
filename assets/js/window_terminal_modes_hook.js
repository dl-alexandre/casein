const SESSION_PREFIX = "devide:window-terminal-modes:"
const LOCAL_PREFIX = "devide:window-terminal-modes-persist:"
const NEW_WINDOWS_RAW_PREFIX = "devide:new-windows-raw:"
const STORAGE_VERSION = 1
const LOCAL_TTL_MS = 30 * 24 * 60 * 60 * 1000

function sessionKey(workspaceId, terminalSid) {
  return `${SESSION_PREFIX}${workspaceId}:${terminalSid}`
}

function localKey(workspaceId, terminalSid) {
  return `${LOCAL_PREFIX}${workspaceId}:${terminalSid}`
}

function newWindowsRawKey(workspaceId) {
  return `${NEW_WINDOWS_RAW_PREFIX}${workspaceId}`
}

function normalizePayload(raw) {
  if (!raw || typeof raw !== "object") return null

  if (raw.modes || raw.names || raw.new_windows_raw != null) {
    return {
      v: raw.v || STORAGE_VERSION,
      modes: raw.modes || {},
      names: raw.names || {},
      new_windows_raw: raw.new_windows_raw === true,
      updated_at: raw.updated_at || Date.now(),
    }
  }

  return {
    v: STORAGE_VERSION,
    modes: raw,
    names: {},
    new_windows_raw: false,
    updated_at: Date.now(),
  }
}

function readStored(workspaceId, terminalSid) {
  if (!workspaceId || !terminalSid) return null

  try {
    const sessionRaw = window.sessionStorage.getItem(sessionKey(workspaceId, terminalSid))
    const localRaw = window.localStorage.getItem(localKey(workspaceId, terminalSid))
    const sessionPayload = sessionRaw ? normalizePayload(JSON.parse(sessionRaw)) : null
    const localPayload = localRaw ? normalizePayload(JSON.parse(localRaw)) : null

    const newWindowsRaw =
      window.localStorage.getItem(newWindowsRawKey(workspaceId)) === "true"

    let chosen = null

    if (localPayload && Date.now() - (localPayload.updated_at || 0) <= LOCAL_TTL_MS) {
      chosen = localPayload
    } else if (sessionPayload) {
      chosen = sessionPayload
    } else if (localPayload) {
      chosen = localPayload
    }

    if (!chosen) {
      if (!newWindowsRaw) return null
      return {
        v: STORAGE_VERSION,
        modes: {},
        names: {},
        new_windows_raw: true,
        updated_at: Date.now(),
      }
    }

    return { ...chosen, new_windows_raw: chosen.new_windows_raw || newWindowsRaw }
  } catch (_error) {
    return null
  }
}

function writeStored(workspaceId, terminalSid, payload) {
  if (!workspaceId || !terminalSid) return

  const body = {
    v: STORAGE_VERSION,
    modes: payload?.modes || {},
    names: payload?.names || {},
    new_windows_raw: payload?.new_windows_raw === true,
    updated_at: Date.now(),
  }

  const json = JSON.stringify(body)
  const empty =
    Object.keys(body.modes).length === 0 &&
    Object.keys(body.names).length === 0 &&
    !body.new_windows_raw

  try {
    const sKey = sessionKey(workspaceId, terminalSid)
    const lKey = localKey(workspaceId, terminalSid)

    if (empty) {
      window.sessionStorage.removeItem(sKey)
      window.localStorage.removeItem(lKey)
    } else {
      window.sessionStorage.setItem(sKey, json)
      window.localStorage.setItem(lKey, json)
    }

    if (body.new_windows_raw) {
      window.localStorage.setItem(newWindowsRawKey(workspaceId), "true")
    } else {
      window.localStorage.removeItem(newWindowsRawKey(workspaceId))
    }
  } catch (_error) {
    // storage may be unavailable in hardened browsers
  }
}

export const WindowTerminalModes = {
  mounted() {
    this.workspaceId = this.el.dataset.workspaceId
    this.terminalSid = this.el.dataset.terminalSid
    this._ignoreStorage = false

    this.handleEvent("terminal:window_modes", (data) => {
      if (data.workspace_id !== this.workspaceId || data.terminal_sid !== this.terminalSid) return
      this._ignoreStorage = true
      writeStored(data.workspace_id, data.terminal_sid, data)
      this._ignoreStorage = false
    })

    this._onStorage = (event) => {
      if (this._ignoreStorage) return
      if (!event.key) return

      const matchesSession = event.key === sessionKey(this.workspaceId, this.terminalSid)
      const matchesLocal = event.key === localKey(this.workspaceId, this.terminalSid)
      const matchesNewWindows = event.key === newWindowsRawKey(this.workspaceId)

      if (!matchesSession && !matchesLocal && !matchesNewWindows) return

      const restored = readStored(this.workspaceId, this.terminalSid)
      if (restored) this.pushEvent("terminal:restore_window_modes", restored)
    }

    window.addEventListener("storage", this._onStorage)

    const restored = readStored(this.workspaceId, this.terminalSid)
    if (restored) this.pushEvent("terminal:restore_window_modes", restored)
  },

  updated() {
    const nextSid = this.el.dataset.terminalSid
    if (nextSid && nextSid !== this.terminalSid) {
      this.terminalSid = nextSid
      const restored = readStored(this.workspaceId, this.terminalSid)
      if (restored) this.pushEvent("terminal:restore_window_modes", restored)
    }
  },

  destroyed() {
    window.removeEventListener("storage", this._onStorage)
  },
}
