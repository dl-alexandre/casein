// Global Cmd+K / Ctrl+K opens the palette; Escape closes it.
// The hook is mounted on a hidden element so it survives LV diffs.
export const PaletteHook = {
  mounted() {
    this._handler = (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "K")) {
        e.preventDefault()
        this.pushEvent("palette:open", {})
      } else if (e.key === "Escape") {
        // Only close if open — cheap to send anyway, server is idempotent.
        this.pushEvent("palette:close", {})
      }
    }
    window.addEventListener("keydown", this._handler)
  },
  destroyed() {
    window.removeEventListener("keydown", this._handler)
  }
}
