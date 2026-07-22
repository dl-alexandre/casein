// Shared CodeMirror wiring for every DevIDE editor surface: the single files-tab
// viewer (`file_viewer_hook.js`) and the per-pane file-pane overlays
// (`file_pane_overlay.js`). Keeps one source of truth for language selection,
// the base extension set (now including a `Mod-s` save binding), clipboard
// helpers, and the context-menu action executor so multiple CodeMirror instances
// stay consistent.

import { EditorState } from "@codemirror/state"
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import {
  HighlightStyle,
  syntaxHighlighting,
  bracketMatching,
  indentOnInput,
  foldGutter,
  codeFolding,
  foldKeymap
} from "@codemirror/language"
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete"
import { tags } from "@lezer/highlight"
import { copyTextWithFallback, showClipboardToast } from "./terminal_copy"
import { pickLang, languageIdForPath } from "./editor_lang.mjs"
import { fileErrorMessage } from "./editor_file_status.mjs"
export { pickLang, languageIdForPath, fileErrorMessage }

// Dark editor theme for surfaces on dark chrome (the file-pane overlay's
// zinc-950 wrapper). Without an explicit theme CodeMirror falls back to its
// light defaults — near-black tokens that vanish on the dark pane. The
// files-tab viewer sits on light chrome and keeps the light defaults.
const darkTheme = EditorView.theme(
  {
    "&": { backgroundColor: "transparent", color: "#e4e4e7" },
    ".cm-content": { caretColor: "#f4f4f5" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: "#f4f4f5" },
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground":
      { backgroundColor: "#2d3f5e" },
    ".cm-activeLine": { backgroundColor: "#27272a66" },
    ".cm-gutters": {
      backgroundColor: "transparent",
      color: "#52525b",
      border: "none"
    },
    ".cm-activeLineGutter": { backgroundColor: "#27272a66", color: "#a1a1aa" },
    // Matched-bracket highlight — CM's default is tuned for light backgrounds.
    ".cm-matchingBracket": {
      backgroundColor: "#3f6f4a80",
      color: "#e4e4e7",
      outline: "1px solid #4ade8066"
    },
    ".cm-nonmatchingBracket": { backgroundColor: "#7f1d1d80" },
    // Fold arrows in the gutter and the "…" placeholder shown for folded code.
    ".cm-foldGutter .cm-gutterElement": { color: "#52525b" },
    ".cm-foldPlaceholder": {
      backgroundColor: "#27272a",
      color: "#a1a1aa",
      border: "1px solid #3f3f46",
      borderRadius: "3px",
      padding: "0 3px"
    }
  },
  { dark: true }
)

// One-dark-ish token palette, picked for contrast on zinc-950.
const darkHighlight = HighlightStyle.define([
  { tag: [tags.keyword, tags.operatorKeyword, tags.modifier], color: "#c678dd" },
  { tag: [tags.string, tags.special(tags.string), tags.inserted], color: "#98c379" },
  { tag: [tags.comment, tags.lineComment, tags.blockComment], color: "#7f848e", fontStyle: "italic" },
  { tag: [tags.number, tags.bool, tags.atom, tags.null], color: "#d19a66" },
  { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: "#61afef" },
  { tag: [tags.typeName, tags.className, tags.namespace], color: "#e5c07b" },
  { tag: [tags.definition(tags.variableName), tags.propertyName], color: "#e06c75" },
  { tag: [tags.tagName, tags.deleted], color: "#e06c75" },
  { tag: [tags.attributeName], color: "#d19a66" },
  { tag: [tags.heading], color: "#61afef", fontWeight: "bold" },
  { tag: [tags.link, tags.url], color: "#61afef", textDecoration: "underline" },
  { tag: [tags.emphasis], fontStyle: "italic" },
  { tag: [tags.strong], fontWeight: "bold" },
  { tag: [tags.meta, tags.processingInstruction], color: "#7f848e" }
])

export const darkEditorExtensions = [darkTheme, syntaxHighlighting(darkHighlight)]

export const SEND_AGENT_MAX_BYTES = 32 * 1024

export function copyEditorText(text) {
  const ok = copyTextWithFallback(text)
  showClipboardToast(ok ? "Copied" : "Copy failed", { kind: ok ? "info" : "error" })
  return ok
}

// Editing-ergonomics extensions common to every surface: matching-bracket
// highlight, auto-close of brackets/quotes, re-indent on input, and a fold
// gutter with its keymap. Kept as one array so both surfaces stay in step.
const ergonomicExtensions = [
  bracketMatching(),
  closeBrackets(),
  indentOnInput(),
  codeFolding(),
  foldGutter()
]

// Base extension set shared by every editor instance. `onUpdate` is a CodeMirror
// updateListener extension; `onSave` (if given) is bound to Mod-s (Cmd/Ctrl+S);
// `dark` (if true) applies the dark theme + token palette above.
export function editorExtensions({ onUpdate, onSave, dark } = {}) {
  const saveBinding = onSave
    ? [{ key: "Mod-s", preventDefault: true, run: () => (onSave(), true) }]
    : []

  const exts = [
    lineNumbers(),
    highlightActiveLine(),
    history(),
    ...ergonomicExtensions,
    // closeBracketsKeymap first (backspace over an auto-pair), then fold keys,
    // save, and the defaults.
    keymap.of([
      ...closeBracketsKeymap,
      ...foldKeymap,
      ...saveBinding,
      ...defaultKeymap,
      ...historyKeymap
    ])
  ]

  if (dark) exts.push(...darkEditorExtensions)
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
