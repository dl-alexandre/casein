// Soft-keyboard dismissal policy for the terminal input — pure predicate.
//
// On a phone the keyboard covers over half the grid, so the moment you submit a
// line — a shell command, an agent prompt — is exactly when you want those rows
// back. Blurring the hidden input is what dismisses it; a tap on the terminal
// re-raises it.
//
// Kept pure because the interesting part is the exclusion list, and a jsdom
// test can never exercise it through a real event: `dispatchEvent` forces
// `isTrusted` to false, so a scripted keystroke and the mobile key bar's own
// synthesis are indistinguishable at the DOM level.

/**
 * Should this keydown on the terminal input dismiss the soft keyboard?
 *
 * @param {{isTrusted?: boolean, key?: string, shiftKey?: boolean,
 *          altKey?: boolean, ctrlKey?: boolean, metaKey?: boolean,
 *          isComposing?: boolean, keyCode?: number}} event
 */
export function enterDismissesSoftKeyboard(event) {
  if (!event || event.key !== "Enter") return false

  // Only a real keystroke. The mobile key bar synthesizes Enter when pasting
  // multi-line text; blurring mid-paste would strand the remaining lines.
  if (!event.isTrusted) return false

  // Agent composers read Shift/Alt/Ctrl/Cmd+Enter as "newline, don't submit" —
  // the operator is still writing, so the keyboard stays.
  if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return false

  // Mid-composition Enter commits an IME candidate rather than the line.
  // keyCode 229 is the pre-`isComposing` signal iOS/Android still emit.
  if (event.isComposing || event.keyCode === 229) return false

  return true
}
