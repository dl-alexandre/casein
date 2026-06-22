// Focus + select the text of an inline rename field as soon as it mounts.
//
// Used by the session/window rename forms in the session picker. LiveView's
// morphdom strips the HTML `autofocus` attribute on patch, so a tiny hook is
// the reliable way to land the caret in the field (and pre-select the current
// name so the user can just type a replacement). Escape-to-cancel is handled
// server-side via `phx-keydown`/`phx-key` on the same input.
export const RenameInput = {
  mounted() {
    this.focusAndSelect()
  },

  focusAndSelect() {
    // Defer to the next frame so the element is laid out (and any dropdown it
    // lives in has finished opening) before we grab focus.
    requestAnimationFrame(() => {
      this.el.focus()
      if (typeof this.el.select === "function") this.el.select()
    })
  },
}
