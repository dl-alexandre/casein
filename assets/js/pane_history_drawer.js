const BOTTOM_EPSILON_PX = 6

function storageKey(key) {
  return `casein:pane-history:${key || "unknown"}`
}

function atBottom(el) {
  if (!el) return true
  return el.scrollHeight - el.clientHeight - el.scrollTop <= BOTTOM_EPSILON_PX
}

function readState(key) {
  try {
    const raw = window.sessionStorage.getItem(storageKey(key))
    return raw ? JSON.parse(raw) : null
  } catch (_) {
    return null
  }
}

function writeState(key, state) {
  try {
    window.sessionStorage.setItem(storageKey(key), JSON.stringify(state))
  } catch (_) {
    // Storage can be disabled; scroll memory is best-effort.
  }
}

export const PaneHistoryDrawer = {
  mounted() {
    this.key = this.el.dataset.historyKey || ""
    this.scrollEl = this.el.querySelector("[data-history-scroll]")
    this.latestButton = this.el.querySelector("[data-history-latest]")
    this.pinState = this.el.querySelector("[data-history-pin-state]")
    this.pinned = readState(this.key)?.pinned !== false

    this.onScroll = () => {
      this.pinned = atBottom(this.scrollEl)
      this.persist()
      this.renderPinState()
    }

    this.onLatest = () => {
      this.pinned = true
      this.scrollToBottom()
      this.persist()
      this.renderPinState()
    }

    this.scrollEl?.addEventListener("scroll", this.onScroll, {passive: true})
    this.latestButton?.addEventListener("click", this.onLatest)
    this.restoreOrFollow()
    this.renderPinState()
  },

  updated() {
    const nextKey = this.el.dataset.historyKey || ""

    if (nextKey !== this.key) {
      this.persist()
      this.key = nextKey
      this.pinned = readState(this.key)?.pinned !== false
    }

    this.restoreOrFollow()
    this.renderPinState()
  },

  destroyed() {
    this.persist()
    this.scrollEl?.removeEventListener("scroll", this.onScroll)
    this.latestButton?.removeEventListener("click", this.onLatest)
  },

  restoreOrFollow() {
    if (this.el.dataset.historyReady !== "true") return

    const saved = readState(this.key)

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        if (this.pinned || !saved) {
          this.scrollToBottom()
        } else if (Number.isFinite(saved.top)) {
          this.scrollEl.scrollTop = saved.top
        }

        this.persist()
        this.renderPinState()
      })
    })
  },

  scrollToBottom() {
    if (!this.scrollEl) return
    this.scrollEl.scrollTop = this.scrollEl.scrollHeight
  },

  persist() {
    if (!this.key || !this.scrollEl) return

    writeState(this.key, {
      top: this.scrollEl.scrollTop,
      pinned: this.pinned || atBottom(this.scrollEl)
    })
  },

  renderPinState() {
    if (!this.pinState) return

    const pinned = this.pinned || atBottom(this.scrollEl)
    this.pinState.textContent = pinned ? "Following latest" : "Viewing history"
    this.pinState.dataset.pinned = pinned ? "true" : "false"
  }
}
