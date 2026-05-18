// Global Ctrl+Space toggles the palette; Escape closes it.
// Arrow Up/Down navigate the result list while the modal is open.
// Mounted on a hidden element that survives LV diffs.
//
// Note: Ctrl+Space (not Cmd+Space) is the binding on every platform —
// Cmd+Space is reserved by macOS for Spotlight and must never be
// intercepted.
//
// Server contract:
//   - palette:open        — toggle visible
//   - palette:close       — hide
//   - palette:nav {dir}   — "up" | "down"
//   - palette:execute     — fired by form submit (Enter) with _selected_id
const PALETTE_RESULTS_ID = "palette-results"

function paletteIsOpen() {
  return document.getElementById(PALETTE_RESULTS_ID) !== null
}

function scrollSelectedIntoView() {
  // Defer one frame so the LV-applied class change has rendered before we
  // measure offsets — otherwise the first nav after open can scroll wrong.
  requestAnimationFrame(() => {
    const container = document.getElementById(PALETTE_RESULTS_ID)
    if (!container) return
    const selected = container.querySelector("li.bg-primary\\/15")
    if (selected && typeof selected.scrollIntoView === "function") {
      selected.scrollIntoView({block: "nearest"})
    }
  })
}

export const PaletteHook = {
  mounted() {
    this._handler = (e) => {
      // Ctrl+Space toggles regardless of state. `e.key` for the space bar
      // is the literal " " character; `e.code === "Space"` is a useful
      // belt-and-braces fallback for non-US keymaps.
      if (e.ctrlKey && !e.metaKey && !e.altKey && (e.key === " " || e.code === "Space")) {
        e.preventDefault()
        this.pushEvent(paletteIsOpen() ? "palette:close" : "palette:open", {})
        return
      }

      // The rest only matter while the palette is visible.
      if (!paletteIsOpen()) return

      if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("palette:close", {})
      } else if (e.key === "ArrowDown") {
        e.preventDefault()
        this.pushEvent("palette:nav", {dir: "down"})
        scrollSelectedIntoView()
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.pushEvent("palette:nav", {dir: "up"})
        scrollSelectedIntoView()
      }
    }
    window.addEventListener("keydown", this._handler)
  },
  destroyed() {
    window.removeEventListener("keydown", this._handler)
  }
}
