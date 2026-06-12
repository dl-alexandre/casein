// PreviewResizer hook — drag the handle between terminal and preview panel to resize.
//
// Mounted on the drag handle div. Reads/writes --preview-panel-width on the
// flex container parent. Persists the chosen width in localStorage so it
// survives page reloads and session switches.

const STORAGE_KEY = "devide:preview-width"
const MIN_WIDTH_PX = 180
const MAX_FRAC = 0.75

export const PreviewResizer = {
  mounted() {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved) this._setWidth(parseFloat(saved))

    this._onDown = (e) => this._startDrag(e)
    this.el.addEventListener("pointerdown", this._onDown)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onDown)
  },

  _startDrag(e) {
    e.preventDefault()
    this.el.setPointerCapture(e.pointerId)
    const container = this.el.parentElement
    if (!container) return

    const onMove = (e) => {
      const rect = container.getBoundingClientRect()
      const width = rect.right - e.clientX
      const maxW = rect.width * MAX_FRAC
      if (width < MIN_WIDTH_PX || width > maxW) return
      this._setWidth(width)
    }

    const onUp = () => {
      this.el.removeEventListener("pointermove", onMove)
      this.el.removeEventListener("pointerup", onUp)
      const panel = document.getElementById("preview-agent-panel")
      if (panel) {
        const w = parseFloat(getComputedStyle(panel).width)
        if (w > 0) localStorage.setItem(STORAGE_KEY, w)
      }
    }

    this.el.addEventListener("pointermove", onMove)
    this.el.addEventListener("pointerup", onUp)
  },

  _setWidth(px) {
    const container = this.el.parentElement
    if (container) container.style.setProperty("--preview-panel-width", `${px}px`)
  },
}
