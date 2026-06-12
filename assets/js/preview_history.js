// PreviewHistory hook — back/forward navigation for the preview iframe.
//
// Mounted on the iframe container div. Tracks URL history by listening to
// iframe `load` events. For same-origin proxied previews the URL is readable
// from contentWindow.location; for cross-origin iframes we catch what we can
// from the load event itself and fall back to the iframe's current src.
//
// The back/forward buttons (#preview-history-back / #preview-history-forward)
// are plain HTML buttons rendered outside this hook's element, so we locate
// them by id. Navigation sets iframe.src directly and marks the load as
// history-triggered to avoid double-pushing to the stack.

export const PreviewHistory = {
  mounted() {
    this._stack = []      // URL strings
    this._idx = -1        // current position
    this._historyNav = false  // true when we triggered the load ourselves

    this._iframe = document.getElementById("preview-agent-iframe")
    this._backBtn = document.getElementById("preview-history-back")
    this._fwdBtn = document.getElementById("preview-history-forward")
    this._urlDisplay = document.getElementById("preview-url-display")

    this._onLoad = () => this._handleLoad()
    this._iframe?.addEventListener("load", this._onLoad)

    this._backBtn?.addEventListener("click", () => this._goBack())
    this._fwdBtn?.addEventListener("click", () => this._goForward())

    // Push the initial src as the first history entry.
    if (this._iframe?.src) this._push(this._iframe.src)
  },

  updated() {
    // LiveView re-rendered: re-locate elements (ids are stable) and re-attach
    // load listener if the iframe was replaced.
    const iframe = document.getElementById("preview-agent-iframe")
    if (iframe && iframe !== this._iframe) {
      this._iframe?.removeEventListener("load", this._onLoad)
      this._iframe = iframe
      this._iframe.addEventListener("load", this._onLoad)
      this._stack = []
      this._idx = -1
      if (this._iframe.src) this._push(this._iframe.src)
    } else {
      // The patch may have reverted button disabled state or the URL text
      // to their server-rendered values — re-assert what the stack knows.
      this._render()
    }
  },

  destroyed() {
    this._iframe?.removeEventListener("load", this._onLoad)
  },

  _handleLoad() {
    if (this._historyNav) {
      this._historyNav = false
      this._render()
      return
    }

    let url
    try {
      url = this._iframe.contentWindow?.location?.href
    } catch (_) {
      // Cross-origin frame — can't read the URL. Leave the stack unchanged
      // so back/forward still point at the last trackable entry.
      this._render()
      return
    }
    if (url && url !== "about:blank") this._push(url)
  },

  _push(url) {
    // Cross-origin iframes fall back to iframe.src on every in-iframe
    // navigation, which never changes — don't stack duplicates of the
    // current entry (back/forward would otherwise lie).
    if (url === this._stack[this._idx]) {
      this._render()
      return
    }
    // Truncate forward history when navigating from a mid-stack position.
    this._stack = this._stack.slice(0, this._idx + 1)
    this._stack.push(url)
    this._idx = this._stack.length - 1
    this._render()
  },

  _goBack() {
    if (this._idx <= 0) return
    this._idx--
    this._navigate(this._stack[this._idx])
  },

  _goForward() {
    if (this._idx >= this._stack.length - 1) return
    this._idx++
    this._navigate(this._stack[this._idx])
  },

  _navigate(url) {
    if (!this._iframe || !url) return
    this._historyNav = true
    this._iframe.src = url
    this._render()
  },

  _render() {
    const canBack = this._idx > 0
    const canFwd = this._idx < this._stack.length - 1
    const url = this._stack[this._idx] || ""

    if (this._backBtn) this._backBtn.disabled = !canBack
    if (this._fwdBtn) this._fwdBtn.disabled = !canFwd

    if (this._urlDisplay && url && url !== "about:blank") {
      this._urlDisplay.textContent = url
      this._urlDisplay.title = url
    }
  },
}
