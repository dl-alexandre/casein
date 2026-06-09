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
    // Double-tap-to-zoom is touch-only: on desktop a double-click is reserved
    // for native word selection, so there we expose zoom via the pane button.
    const coarse =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(pointer: coarse)").matches
    this._lastTap = 0

    const elementTarget = (target) => {
      if (!target) return null
      return target.nodeType === Node.ELEMENT_NODE ? target : target.parentElement
    }

    const terminalTextTarget = (target) => {
      const el = elementTarget(target)
      return Boolean(el?.closest('[phx-hook="GhosttyTerminal"] pre'))
    }

    const handleCoarseDoubleTap = (paneId) => {
      if (!coarse) return

      const now = Date.now()
      if (now - this._lastTap < 300) {
        this._lastTap = 0
        this.pushEvent("zoom_pane", { "pane-id": paneId })
      } else {
        this._lastTap = now
      }
    }

    this._onPointerDown = (e) => {
      const paneId = this.el.dataset.paneId
      if (!paneId) return
      // Don't intercept clicks on the pane's own toolbar buttons (split,
      // close, etc.) — they have their own phx-click handlers and we don't
      // want focus_pane to race with them. Floating overlay sits inside
      // the wrapper, so detect by closest button ancestor.
      const target = elementTarget(e.target)
      if (target?.closest("button")) return
      // A terminal-text drag is browser text selection, not pane focusing.
      // The wrapper's phx-click still focuses on an actual click, but skipping
      // pointerdown avoids a LiveView patch racing an in-progress selection.
      if (terminalTextTarget(e.target)) {
        handleCoarseDoubleTap(paneId)
        return
      }
      // Push to the root LV (not pushEventTo with this.el — that routes
      // to a LiveComponent if one owns the element, and focus_pane lives
      // on the LV itself).
      this.pushEvent("focus_pane", { "pane-id": paneId })
      handleCoarseDoubleTap(paneId)
    }
    this.el.addEventListener("pointerdown", this._onPointerDown, true)
  },
  destroyed() {
    if (this._onPointerDown) {
      this.el.removeEventListener("pointerdown", this._onPointerDown, true)
    }
  },
}
