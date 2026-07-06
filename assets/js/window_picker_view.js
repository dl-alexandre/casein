// Persists the window-picker presentation ("dropdown" | "tabs" | "sidebar") per
// browser and replays it on mount, mirroring the terminal theme hybrid: the
// server owns the assign, this hook owns the localStorage copy.
//
// Mounted on the header pickers container (`data-view` carries the server's
// current value). On mount, a stored preference that differs from the server
// default is pushed back up via `view:set_window_picker`; every server-side
// change is announced with a `window-picker-view` event so the store follows.

const STORAGE_KEY = "devide:window-picker-view"
const VIEWS = ["dropdown", "tabs", "sidebar"]

export const WindowPickerView = {
  mounted() {
    this.handleEvent("window-picker-view", ({view}) => {
      if (!VIEWS.includes(view)) return
      try {
        localStorage.setItem(STORAGE_KEY, view)
      } catch (_e) {
        // Storage may be unavailable (private mode, embedded webview) — the
        // toggle still works for the life of the LiveView.
      }
    })

    let stored
    try {
      stored = localStorage.getItem(STORAGE_KEY)
    } catch (_e) {
      stored = null
    }

    if (VIEWS.includes(stored) && stored !== this.el.dataset.view) {
      this.pushEvent("view:set_window_picker", {view: stored})
    }
  },
}
