export function clearComposerText(root, paneId) {
  if (!root || root.dataset?.paneId !== paneId) return false

  const textarea = root.querySelector("textarea[name='text']")
  if (!textarea) return false

  textarea.value = ""
  textarea.focus({preventScroll: true})
  return true
}

export function truncateUtf8(value, maxBytes) {
  if (typeof value !== "string" || !Number.isInteger(maxBytes) || maxBytes < 0) return ""

  const encoder = new TextEncoder()
  if (encoder.encode(value).byteLength <= maxBytes) return value

  let result = ""
  let bytes = 0

  for (const character of value) {
    const characterBytes = encoder.encode(character).byteLength
    if (bytes + characterBytes > maxBytes) break
    result += character
    bytes += characterBytes
  }

  return result
}

export const MobileAgentComposer = {
  mounted() {
    this._textarea = this.el.querySelector("textarea[name='text']")
    this._textLimit = Number.parseInt(this.el.dataset.textLimit || "0", 10)
    this._onInput = () => {
      const limited = truncateUtf8(this._textarea?.value, this._textLimit)
      if (this._textarea && this._textarea.value !== limited) this._textarea.value = limited
    }
    this._textarea?.addEventListener("input", this._onInput)

    this._clearEventRef = this.handleEvent("mobile_agent_composer:clear", ({pane_id}) => {
      clearComposerText(this.el, pane_id)
    })
  },

  destroyed() {
    this._textarea?.removeEventListener("input", this._onInput)
    if (this._clearEventRef) this.removeHandleEvent?.(this._clearEventRef)
  },
}
