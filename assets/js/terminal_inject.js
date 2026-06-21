// Shared helper: write a string into the currently-focused terminal pane as if
// the user had typed/pasted it. Drives the exact same front-end path a physical
// keyboard does (the GhosttyTerminal hook listens on [data-ghostty-input]), so
// no server-side change is needed and it works across every terminal backend.
//
// Extracted from mobile_key_bar.js so the speech-input hook reuses one code
// path instead of forking the dispatch logic.

const INPUT_SELECTOR = '[data-ghostty-input="true"]'

// Locate the active terminal input: the focused element if it is one, else the
// input inside the active tmux pane tile, else any terminal on the page.
export function activeTerminalInput() {
  const active = document.activeElement
  if (active && active.matches && active.matches(INPUT_SELECTOR)) return active

  const focusedPane = document.querySelector('[data-pane-active="true"]')
  if (focusedPane) {
    const inFocused = focusedPane.querySelector(INPUT_SELECTOR)
    if (inFocused) return inFocused
  }

  return document.querySelector(INPUT_SELECTOR)
}

// Inject text into the active terminal. Prefer a single synthetic paste event;
// fall back to per-character keydown for browsers that can't construct
// clipboard data. Returns true if an input was found, false otherwise.
export function injectTerminalText(text) {
  if (!text) return false
  const input = activeTerminalInput()
  if (!input) return false

  input.focus()

  if (dispatchPasteText(input, text)) return true

  for (const ch of text) {
    let key
    if (ch === "\n" || ch === "\r") key = { key: "Enter", code: "Enter" }
    else if (ch === "\t") key = { key: "Tab", code: "Tab" }
    else key = { key: ch, code: "" }

    const init = {
      ...key,
      bubbles: true,
      cancelable: true,
      ctrlKey: false,
      altKey: false,
      shiftKey: false,
      metaKey: false
    }
    input.dispatchEvent(new KeyboardEvent("keydown", init))
    input.dispatchEvent(new KeyboardEvent("keyup", init))
  }

  return true
}

function dispatchPasteText(input, text) {
  if (text === "") return true
  if (typeof DataTransfer === "undefined" || typeof ClipboardEvent === "undefined") return false

  try {
    const data = new DataTransfer()
    data.setData("text/plain", text)
    data.setData("text", text)

    const event = new ClipboardEvent("paste", {
      bubbles: true,
      cancelable: true,
      clipboardData: data
    })

    input.dispatchEvent(event)
    return true
  } catch (_) {
    return false
  }
}
