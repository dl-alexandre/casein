import {applyCopySelection, copyInGesture, COPY_FALLBACK_STYLE} from "./clipboard_write.mjs"
import {hideToast, showToast} from "./toast"

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
  // readOnly keeps iOS from raising the soft keyboard when we focus this to
  // copy; applyCopySelection lifts it for the duration of the selection.
  target.readOnly = true
  Object.assign(target.style, COPY_FALLBACK_STYLE)
  document.body.appendChild(target)
  __fallbackInput = target
  return target
}

/**
 * Synchronous copy for explicit user gestures (keydown, click). Safari needs
 * this inside the gesture handler — async clipboard.writeText often rejects.
 *
 * Must be called *during* the gesture. Calling it from a promise callback (e.g.
 * a writeText rejection handler) is too late: the user activation is spent by
 * the time the microtask runs and execCommand will refuse.
 */
export function copyTextSync(text, input) {
  if (!text) return false

  const target = input || copyFallbackInput()
  const previous = target.value

  if (!applyCopySelection(target, text, {doc: document, win: window})) {
    target.value = previous
    return false
  }

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
 * Best-effort copy from inside a user gesture. Returns whether the copy either
 * completed synchronously or was handed to the async clipboard API; pass
 * `onAsyncResult` to learn the outcome in the latter case.
 *
 * Sync is attempted first on purpose. The async API is the nicer interface but
 * it rejects without a user activation on WebKit, and any fallback chained onto
 * that rejection runs in a microtask where the activation no longer exists —
 * so an async-first ordering leaves iOS with no working path at all.
 */
export function copyTextWithFallback(text, input, {onAsyncResult} = {}) {
  return copyInGesture(text, {
    syncCopy: (value) => copyTextSync(value, input),
    asyncWrite: (value) => navigator.clipboard?.writeText?.(value),
    onAsyncResult
  })
}

/** True when the platform can hand text to a native share sheet. */
export function canShareText(text) {
  if (!text || typeof navigator === "undefined" || typeof navigator.share !== "function") {
    return false
  }
  if (typeof navigator.canShare === "function") {
    try {
      return navigator.canShare({text})
    } catch (_) {
      return false
    }
  }
  return true
}

/**
 * Open the platform share sheet for `text`. On iOS this is the most reliable
 * escape hatch when clipboard permission is refused: the sheet always offers
 * Copy. Must be called from a user gesture.
 */
export function shareText(text) {
  if (!canShareText(text)) return false
  try {
    const result = navigator.share({text})
    if (result && typeof result.catch === "function") result.catch(() => {})
    return true
  } catch (_) {
    return false
  }
}

export function hideClipboardToast() {
  hideToast("Agent copied text")
}

/**
 * Retained name for the ~15 existing call sites; the surface underneath is now
 * the shared toast stack (see toast.js), so clipboard results, server flash
 * messages, and shortcut hints queue against each other instead of fighting
 * over one DOM node in two different corners.
 *
 * `duration` is now optional — omit it to get the per-kind default.
 */
export function showClipboardToast(message, options = {}) {
  showToast(message, options)
}
