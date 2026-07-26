let __fallbackInput = null

function copyFallbackInput() {
  if (__fallbackInput && __fallbackInput.isConnected) return __fallbackInput

  const target = document.createElement("textarea")
  target.id = "casein-copy-fallback"
  target.setAttribute("aria-hidden", "true")
  target.setAttribute("tabindex", "-1")
  target.setAttribute("autocomplete", "off")
  target.setAttribute("autocorrect", "off")
  target.setAttribute("autocapitalize", "off")
  target.setAttribute("spellcheck", "false")
  Object.assign(target.style, {
    position: "fixed",
    left: "-10000px",
    top: "0",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    opacity: "0",
    whiteSpace: "pre-wrap"
  })
  document.body.appendChild(target)
  __fallbackInput = target
  return target
}

/**
 * Synchronous copy for explicit user gestures (keydown, click). Safari needs this
 * inside the gesture handler — async clipboard.writeText often rejects.
 */
export function copyTextSync(text, input) {
  if (!text) return false

  const target = input || copyFallbackInput()
  const previous = target.value
  target.value = text
  target.focus({ preventScroll: true })
  target.select()

  let copied
  try {
    copied = document.execCommand("copy")
  } catch (_) {
    copied = false
  }

  target.value = previous
  return copied
}

/**
 * Best-effort copy; prefers async API then falls back to execCommand.
 */
export function copyTextWithFallback(text, input) {
  if (!text) return false

  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => copyTextSync(text, input))
    return true
  }

  return copyTextSync(text, input)
}

export function showClipboardToast(message, { kind = "info", duration = 4000 } = {}) {
  if (!message) return

  let el = document.getElementById("casein-clipboard-toast")
  if (!el) {
    el = document.createElement("div")
    el.id = "casein-clipboard-toast"
    el.setAttribute("role", "status")
    el.setAttribute("aria-live", "polite")
    document.body.appendChild(el)
  }

  el.dataset.kind = kind
  el.textContent = message
  el.classList.add("casein-clipboard-toast--visible")
  clearTimeout(el.__hideTimer)
  el.__hideTimer = window.setTimeout(() => {
    el.classList.remove("casein-clipboard-toast--visible")
  }, duration)
}