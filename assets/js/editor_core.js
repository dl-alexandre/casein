// Shared CodeMirror wiring for every DevIDE editor surface: the single files-tab
// viewer (`file_viewer_hook.js`) and the per-pane file-pane overlays
// (`file_pane_overlay.js`). Keeps one source of truth for language selection,
// the base extension set (now including a `Mod-s` save binding), clipboard
// helpers, and the context-menu action executor so multiple CodeMirror instances
// stay consistent.

import { EditorState } from "@codemirror/state"
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { copyTextWithFallback, showClipboardToast } from "./terminal_copy"
import { pickLang, languageIdForPath } from "./editor_lang.mjs"
export { pickLang, languageIdForPath }

export const SEND_AGENT_MAX_BYTES = 32 * 1024

export function copyEditorText(text) {
  const ok = copyTextWithFallback(text)
  showClipboardToast(ok ? "Copied" : "Copy failed", { kind: ok ? "info" : "error" })
  return ok
}

// Base extension set shared by every editor instance. `onUpdate` is a CodeMirror
// updateListener extension; `onSave` (if given) is bound to Mod-s (Cmd/Ctrl+S).
export function editorExtensions({ onUpdate, onSave } = {}) {
  const saveBinding = onSave
    ? [{ key: "Mod-s", preventDefault: true, run: () => (onSave(), true) }]
    : []

  const exts = [
    lineNumbers(),
    highlightActiveLine(),
    history(),
    keymap.of([...saveBinding, ...defaultKeymap, ...historyKeymap])
  ]

  if (onUpdate) exts.push(onUpdate)
  return exts
}

export function makeEditorState(doc, path, opts = {}) {
  return EditorState.create({
    doc: doc || "",
    extensions: [...editorExtensions(opts), ...pickLang(path)]
  })
}

// Reveal + focus a 1-based line in a view (used after opening a file at a line).
export function revealLine(view, line) {
  if (typeof line !== "number" || line <= 0) return
  const doc = view.state.doc
  const target = Math.min(line, doc.lines)
  const pos = doc.line(target).from
  view.dispatch({
    selection: { anchor: pos },
    effects: EditorView.scrollIntoView(pos, { y: "center" })
  })
  view.focus()
}

// Execute a context-menu action against a CodeMirror view. Handles the editor
// actions common to every surface (clipboard + save). Returns true when handled,
// false for actions the caller must handle (e.g. send_to_agent). `ctxSelection`
// is the text snapshotted when the menu opened; `onSave` runs the save action.
export function runEditorCtxAction(view, action, { ctxSelection = "", onSave } = {}) {
  const sel = view.state.selection.main

  switch (action) {
    case "copy":
      if (ctxSelection) copyEditorText(ctxSelection)
      return true

    case "cut":
      if (ctxSelection && copyEditorText(ctxSelection)) {
        view.dispatch({ changes: { from: sel.from, to: sel.to, insert: "" } })
        view.focus()
      }
      return true

    case "paste":
      if (!navigator.clipboard?.readText) {
        showClipboardToast("Clipboard read is not available in this browser", { kind: "error" })
        return true
      }
      navigator.clipboard
        .readText()
        .then((text) => {
          if (!text) return
          view.dispatch({
            changes: { from: sel.from, to: sel.to, insert: text },
            selection: { anchor: sel.from + text.length }
          })
          view.focus()
        })
        .catch(() => showClipboardToast("Clipboard read blocked by the browser", { kind: "error" }))
      return true

    case "select_all":
      view.dispatch({ selection: { anchor: 0, head: view.state.doc.length } })
      view.focus()
      return true

    case "save":
      if (onSave) onSave()
      return true

    default:
      return false
  }
}
