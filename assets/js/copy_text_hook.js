import {copyTextWithFallback, showClipboardToast} from "./terminal_copy"

/**
 * Copies the element's `data-copy-text` to the clipboard on click/tap and flashes
 * a transient `data-copied` marker (Tailwind `data-[copied]:` styles the flash).
 * The marker is a data attribute, not a class, so a LiveView re-render that strips
 * hook-added classes can't leave it stuck (see liveview-wipes-hook-classes).
 */
export const CopyText = {
  mounted() {
    this.onClick = (event) => {
      event.preventDefault()
      const text = this.el.dataset.copyText || ""
      if (!text) return

      const ok = copyTextWithFallback(text)
      showClipboardToast(ok ? `Copied ${text}` : "Copy failed", {
        kind: ok ? "info" : "error"
      })

      if (!ok) return
      this.el.dataset.copied = "true"
      clearTimeout(this.flashTimer)
      this.flashTimer = setTimeout(() => {
        delete this.el.dataset.copied
      }, 800)
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    clearTimeout(this.flashTimer)
    this.el.removeEventListener("click", this.onClick)
  }
}
