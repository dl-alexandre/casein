// Header ⋯ overflow menu (`<details class="header-overflow">`).
//
// Three jobs:
// 1. Keep the menu open across LiveView morphs. The `open` attribute is
//    browser-set, so a re-render (activity dots, notifications, topology)
//    strips it and the menu snaps shut — same trap as SessionPicker.
// 2. Host client-only sizing controls (font size / display zoom) that live in
//    the menu on desktop; they dispatch the same window events as the mobile
//    keybar so the terminal hooks stay the single consumer.
// 3. Size the panel to the room actually left around the ⋯ button, so it runs
//    to the bottom of the viewport instead of scrolling inside a fixed cap,
//    and grows to fit its labels instead of wrapping them at `min-width`.

import {overflowMenuMaxHeight, overflowMenuMaxWidth} from "./header_overflow_fit.mjs"

function dispatchKeybarSpec(spec) {
  if (spec === "FontDown" || spec === "FontUp") {
    window.dispatchEvent(
      new CustomEvent("casein:font-size", {detail: {delta: spec === "FontUp" ? 1 : -1}})
    )
    return true
  }

  if (spec === "ZoomDown" || spec === "ZoomUp" || spec === "ZoomReset") {
    window.dispatchEvent(
      new CustomEvent("casein:terminal-display-zoom", {
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
      this._fitMenu()
    }

    this._onViewportChange = () => {
      if (this.el.open) this._fitMenu()
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
    window.addEventListener("resize", this._onViewportChange)
  },

  beforeUpdate() {
    this._wasOpen = this.el.open
  },

  updated() {
    if (this._wasOpen && !this.el.open) this.el.setAttribute("open", "")
    // A morph can move the header (tab strip wrapping, banner appearing), so
    // re-measure rather than trust the budget taken when the menu opened.
    if (this.el.open) this._fitMenu()
  },

  destroyed() {
    this.el.removeEventListener("toggle", this._onToggle)
    this.el.removeEventListener("click", this._onClick)
    window.removeEventListener("resize", this._onViewportChange)
  },

  // Publish the budget as a custom property; the CSS keeps its static cap as
  // the fallback for the frame before the first measurement lands.
  _fitMenu() {
    const menu = this.el.querySelector(".header-overflow-menu")
    if (!menu) return

    if (!this.el.open) {
      menu.style.removeProperty("--header-overflow-max-h")
      menu.style.removeProperty("--header-overflow-max-w")
      return
    }

    const anchor = this.el.querySelector("summary") || this.el
    const rect = anchor.getBoundingClientRect()

    const maxHeight = overflowMenuMaxHeight({
      anchorBottom: rect.bottom,
      viewportHeight: window.innerHeight,
    })
    if (maxHeight !== null) menu.style.setProperty("--header-overflow-max-h", `${maxHeight}px`)

    const maxWidth = overflowMenuMaxWidth({
      anchorRight: rect.right,
      viewportWidth: window.innerWidth,
    })
    if (maxWidth !== null) menu.style.setProperty("--header-overflow-max-w", `${maxWidth}px`)
  },
}
