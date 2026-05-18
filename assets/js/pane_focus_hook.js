// Capture-phase pointer listener that fires `focus_pane` to the LV before
// the GhosttyTerminal hook's own mousedown handler can preventDefault or
// otherwise interfere. Without this, clicking an unfocused pane sometimes
// failed to switch focus because:
//
//   * The Ghostty hook's mousedown handler calls `e.preventDefault()` for
//     text-selection, which in some browsers suppresses the synthetic
//     click event that LiveView's window-level listener relies on.
//   * The hook also calls `input.focus()` on its hidden textarea, moving
//     keyboard focus into the clicked pane even when the LV-side
//     focused_pane_id hadn't updated yet — visually confusing.
//
// Running in the capture phase means we see the pointerdown first and can
// push the focus_pane event regardless of what the inner hook does.
//
// The `phx-click="focus_pane"` on the pane wrapper still works as a
// fallback for keyboard / accessibility paths; this hook is the
// belt-and-suspenders fast path for pointer input.
export const PaneFocusOnClick = {
  mounted() {
    this._onPointerDown = (e) => {
      const paneId = this.el.dataset.paneId
      if (!paneId) return
      // Don't intercept clicks on the pane's own toolbar buttons (split,
      // close, etc.) — they have their own phx-click handlers and we don't
      // want focus_pane to race with them. Floating overlay sits inside
      // the wrapper, so detect by closest button ancestor.
      if (e.target.closest("button")) return
      this.pushEventTo(this.el, "focus_pane", { "pane-id": paneId })
    }
    this.el.addEventListener("pointerdown", this._onPointerDown, true)
  },
  destroyed() {
    if (this._onPointerDown) {
      this.el.removeEventListener("pointerdown", this._onPointerDown, true)
    }
  },
}
