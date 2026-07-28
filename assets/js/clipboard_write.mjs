/**
 * Clipboard selection primitives, split out of terminal_copy.js so the WebKit
 * dance is testable without a real DOM (terminal_copy.js is CommonJS-resolved
 * `.js`; only `.mjs` modules can be imported from the node --test suites).
 */

function hasFn(obj, name) {
  return Boolean(obj) && typeof obj[name] === "function"
}

function assign(target, key, value) {
  try {
    target[key] = value
    return true
  } catch (_) {
    return false
  }
}

/**
 * Establish a document selection covering `target`'s full contents so that a
 * subsequent `execCommand("copy")` has something to act on. Returns whether a
 * selection was actually established.
 *
 * WebKit (iOS Safari) is the entire reason this is not just `target.select()`:
 * execCommand copies the *document* selection, and on iOS a bare select() on a
 * form control does not establish one — the copy silently succeeds-as-noop.
 * The contentEditable/readOnly toggle plus an explicit Range is the
 * long-standing workaround; setSelectionRange alone is not enough on older iOS
 * and the Range alone is not enough on newer, so we do both and restore the
 * element's prior state before the caller runs the copy.
 *
 * Every step is individually guarded because this runs inside a user gesture on
 * the copy path — a throw part-way through would lose the copy entirely, and a
 * gesture cannot be replayed.
 */
export function applyCopySelection(target, text, env = {}) {
  if (!target || typeof text !== "string") return false

  const doc = env.doc
  const win = env.win

  assign(target, "value", text)

  // Toggling these makes the selection stick on WebKit; both are put back
  // before we return so the element stays keyboard-inert between copies.
  const previousEditable = target.contentEditable
  const previousReadOnly = target.readOnly
  assign(target, "contentEditable", "true")
  assign(target, "readOnly", false)

  if (hasFn(target, "focus")) {
    try {
      target.focus({preventScroll: true})
    } catch (_) {
      try {
        target.focus()
      } catch (_) {
        /* focus is best-effort; selection below may still land */
      }
    }
  }

  let selected = false

  if (hasFn(doc, "createRange") && hasFn(win, "getSelection")) {
    try {
      const range = doc.createRange()
      range.selectNodeContents(target)
      const selection = win.getSelection()
      if (selection) {
        selection.removeAllRanges()
        selection.addRange(range)
        selected = true
      }
    } catch (_) {
      /* fall through to the form-control selection below */
    }
  }

  if (hasFn(target, "setSelectionRange")) {
    try {
      target.setSelectionRange(0, text.length)
      selected = true
    } catch (_) {
      /* fall through */
    }
  } else if (hasFn(target, "select")) {
    try {
      target.select()
      selected = true
    } catch (_) {
      /* fall through */
    }
  }

  assign(target, "contentEditable", previousEditable)
  assign(target, "readOnly", previousReadOnly)

  return selected
}

/**
 * Run a copy from inside a user gesture, synchronous path first.
 *
 * The ordering is the point of this function. `execCommand("copy")` is only
 * permitted while the activation that triggered the current call is still being
 * processed, whereas `clipboard.writeText` settles in a microtask — so chaining
 * the sync attempt onto a writeText rejection puts it after the activation has
 * been spent, where it can never succeed. Since writeText is exactly the call
 * that rejects on WebKit, an async-first ordering leaves iOS with no working
 * path at all. Sync first, async as the fallback.
 *
 * Returns true when the copy either completed synchronously or was handed to
 * the async API; `onAsyncResult` reports the outcome in the latter case.
 */
export function copyInGesture(text, {syncCopy, asyncWrite, onAsyncResult} = {}) {
  if (!text) return false

  if (typeof syncCopy === "function" && syncCopy(text)) return true

  if (typeof asyncWrite === "function") {
    const pending = asyncWrite(text)
    if (pending && typeof pending.then === "function") {
      pending.then(
        () => onAsyncResult?.(true),
        () => onAsyncResult?.(false)
      )
      return true
    }
  }

  return false
}

/**
 * Style/attribute contract for the offscreen copy target.
 *
 * `readOnly` keeps the iOS soft keyboard from appearing when we focus it, and
 * the element is given real dimensions and a 16px font: zero-sized or
 * fully-transparent elements are unreliable copy sources on WebKit, and a sub-
 * 16px font would trigger Safari's focus zoom if it ever became visible.
 * Position is offscreen-left rather than `display: none` — a non-rendered
 * element cannot hold a selection.
 */
export const COPY_FALLBACK_STYLE = {
  position: "fixed",
  left: "-10000px",
  top: "0",
  width: "2em",
  height: "2em",
  padding: "0",
  border: "none",
  outline: "none",
  boxShadow: "none",
  background: "transparent",
  fontSize: "16px",
  whiteSpace: "pre-wrap"
}
