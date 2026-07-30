import {canShareText, shareText, showClipboardToast} from "./terminal_copy"

/**
 * Shares the element's `data-share-text` via the platform share sheet.
 *
 * Rendered `hidden` by the server and revealed only where a share sheet exists,
 * so desktop never shows a dead button. On iOS this is the dependable escape
 * hatch when a clipboard write is refused outright — the sheet always offers
 * Copy, and it is reachable from the same tap.
 */
export const ShareText = {
  mounted() {
    this.syncVisibility()

    this.onClick = (event) => {
      event.preventDefault()
      const text = this.el.dataset.shareText || ""
      if (!text) return
      // navigator.share must be called from the gesture, so share directly here.
      if (!shareText(text)) {
        showClipboardToast("Sharing isn't available here", {kind: "error"})
      }
    }

    this.el.addEventListener("click", this.onClick)
  },

  updated() {
    // A re-render restores the server-rendered `hidden`, so reapply it rather
    // than only revealing once on mount (see liveview-wipes-hook-classes).
    this.syncVisibility()
  },

  syncVisibility() {
    if (canShareText(this.el.dataset.shareText || "")) this.el.hidden = false
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  }
}
