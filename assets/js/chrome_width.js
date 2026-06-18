// ChromeWidth hook
//
// Toggles `:root[data-chrome-narrow]` when the workspace header — and therefore
// the terminal pane below it — is narrower than the threshold. This lets the
// mobile session switcher (key bar + nav sheet) track the *pane* width, e.g.
// when an open preview/side panel squeezes the chrome while the viewport stays
// wide. The header already reasons about its own width via CSS container
// queries, but a CSS `@container` can't drive the viewport-fixed key bar (a
// container establishes a containing block for `position: fixed` descendants,
// which would unpin the bottom bar), so we measure here instead.
//
// Additive: app.css still reveals the mobile chrome on (pointer: coarse) and
// narrow viewports without JS — this attribute only adds the pane-relative case.

const NARROW_PX = 640

export const ChromeWidth = {
  mounted() {
    this.apply = () => {
      const w = this.el.clientWidth
      document.documentElement.toggleAttribute("data-chrome-narrow", w > 0 && w <= NARROW_PX)
    }
    this.ro = new ResizeObserver(this.apply)
    this.ro.observe(this.el)
    this.apply()
  },

  destroyed() {
    this.ro?.disconnect()
    document.documentElement.removeAttribute("data-chrome-narrow")
  },
}
