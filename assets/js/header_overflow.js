// Header ⋯ overflow menu (`<details class="header-overflow">`).
//
// Two jobs:
// 1. Keep the menu open across LiveView morphs. The `open` attribute is
//    browser-set, so a re-render (activity dots, notifications, topology)
//    strips it and the menu snaps shut — same trap as SessionPicker.
// 2. Host client-only sizing controls (font size / display zoom) that live in
//    the menu on desktop; they dispatch the same window events as the mobile
//    keybar so the terminal hooks stay the single consumer.

function dispatchKeybarSpec(spec) {
  if (spec === "FontDown" || spec === "FontUp") {
    window.dispatchEvent(
      new CustomEvent("devide:font-size", {detail: {delta: spec === "FontUp" ? 1 : -1}})
    )
    return true
  }

  if (spec === "ZoomDown" || spec === "ZoomUp" || spec === "ZoomReset") {
    window.dispatchEvent(
      new CustomEvent("devide:terminal-display-zoom", {
        detail: {
          delta: spec === "ZoomUp" ? 0.1 : spec === "ZoomDown" ? -0.1 : 0,
          reset: spec === "ZoomReset",
        },
      })
    )
    return true
  }

  return false
}

export const HeaderOverflow = {
  mounted() {
    this._wasOpen = false

    this._onToggle = () => {
      this._wasOpen = this.el.open
    }

    // Client-side sizing stays in-menu; do not let the click fall through to
    // anything that would treat it as a navigation target.
    this._onClick = (e) => {
      const btn = e.target.closest?.("[data-keybar-key]")
      if (!btn || !this.el.contains(btn)) return

      const spec = btn.dataset.keybarKey
      if (!spec) return

      if (dispatchKeybarSpec(spec)) {
        e.preventDefault()
        e.stopPropagation()
      }
    }

    this.el.addEventListener("toggle", this._onToggle)
    this.el.addEventListener("click", this._onClick)
  },

  beforeUpdate() {
    this._wasOpen = this.el.open
  },

  updated() {
    if (this._wasOpen && !this.el.open) this.el.setAttribute("open", "")
  },

  destroyed() {
    this.el.removeEventListener("toggle", this._onToggle)
    this.el.removeEventListener("click", this._onClick)
  },
}
