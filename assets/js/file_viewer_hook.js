import { EditorState } from "@codemirror/state"
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { javascript } from "@codemirror/lang-javascript"
import { markdown } from "@codemirror/lang-markdown"
import { json } from "@codemirror/lang-json"
import { copyTextWithFallback, showClipboardToast } from "./terminal_copy"

const SEND_AGENT_MAX_BYTES = 32 * 1024

function copyEditorText(text) {
  const ok = copyTextWithFallback(text)
  showClipboardToast(ok ? "Copied" : "Copy failed", { kind: ok ? "info" : "error" })
  return ok
}

function pickLang(path) {
  if (!path) return []
  if (/\.(js|jsx|ts|tsx|mjs|cjs)$/.test(path)) return [javascript()]
  if (/\.md$/.test(path)) return [markdown()]
  if (/\.json$/.test(path)) return [json()]
  return []
}

function setDirty(dirty) {
  const el = document.getElementById("dirty-indicator")
  if (!el) return
  el.dataset.dirty = dirty ? "true" : "false"
  el.textContent = dirty ? "● unsaved" : "saved"
}

export const FileViewerHook = {
  mounted() {
    this.path = null
    this.version = null
    this.savedDoc = ""

    const onUpdate = EditorView.updateListener.of(u => {
      if (u.docChanged) {
        const cur = this.view.state.doc.toString()
        setDirty(cur !== this.savedDoc)
      }
    })

    this.view = new EditorView({
      state: EditorState.create({
        doc: "",
        extensions: [
          lineNumbers(),
          highlightActiveLine(),
          history(),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          onUpdate
        ]
      }),
      parent: this.el
    })
    this._onUpdate = onUpdate

    this.handleEvent("file:loaded", ({ path, content, version, line }) => {
      this.path = path
      this.version = version
      this.savedDoc = content
      this.view.setState(this.makeState(content, path))
      setDirty(false)

      if (typeof line === "number" && line > 0) {
        const doc = this.view.state.doc
        const target = Math.min(line, doc.lines)
        const pos = doc.line(target).from
        this.view.dispatch({
          selection: { anchor: pos },
          effects: EditorView.scrollIntoView(pos, { y: "center" })
        })
        this.view.focus()
      }
    })

    this.handleEvent("file:cleared", () => {
      this.path = null
      this.version = null
      this.savedDoc = ""
      this.view.setState(this.makeState("", null))
      setDirty(false)
    })

    this.handleEvent("save:ok", ({ version }) => {
      this.version = version
      this.savedDoc = this.view.state.doc.toString()
      setDirty(false)
    })

    this._onSave = () => {
      if (!this.path || !this.version) return
      this.pushEvent("file:save", {
        path: this.path,
        content: this.view.state.doc.toString(),
        version: this.version
      })
    }

    this._onRefresh = () => {
      const dirty = this.view.state.doc.toString() !== this.savedDoc
      if (dirty && !confirm("You have unsaved changes. Discard them and refresh?")) return
      this.pushEvent("file:refresh", {})
    }

    this.el.addEventListener("devide:save", this._onSave)
    this.el.addEventListener("devide:refresh", this._onRefresh)

    // Right-click menu integration (shared ContextMenu hook): declare the
    // trigger, refresh ctx state just before the menu opens, and execute the
    // client actions the menu dispatches back. The selection is snapshotted
    // at open time; CodeMirror keeps its selection range while blurred, so
    // range-based actions (cut/paste) re-read it at action time.
    this.el.dataset.ctxMenu = "editor"

    this._onCtxBeforeOpen = () => {
      const sel = this.view.state.selection.main
      this._ctxSelection = this.view.state.sliceDoc(sel.from, sel.to)
      this.el.dataset.ctxTargetId = this.el.id
      this.el.dataset.ctxHasFile = this.path ? "true" : "false"
      this.el.dataset.ctxHasSelection = this._ctxSelection ? "true" : "false"
    }

    this._onCtxAction = (e) => {
      const sel = this.view.state.selection.main

      switch (e?.detail?.action) {
        case "copy":
          if (this._ctxSelection) copyEditorText(this._ctxSelection)
          break
        case "cut":
          if (this._ctxSelection && copyEditorText(this._ctxSelection)) {
            this.view.dispatch({ changes: { from: sel.from, to: sel.to, insert: "" } })
            this.view.focus()
          }
          break
        case "paste":
          if (!navigator.clipboard?.readText) {
            showClipboardToast("Clipboard read is not available in this browser", {
              kind: "error"
            })
            break
          }
          navigator.clipboard
            .readText()
            .then((text) => {
              if (!text) return
              this.view.dispatch({
                changes: { from: sel.from, to: sel.to, insert: text },
                selection: { anchor: sel.from + text.length }
              })
              this.view.focus()
            })
            .catch(() =>
              showClipboardToast("Clipboard read blocked by the browser", { kind: "error" })
            )
          break
        case "select_all":
          this.view.dispatch({ selection: { anchor: 0, head: this.view.state.doc.length } })
          this.view.focus()
          break
        case "save":
          this._onSave()
          break
        case "send_to_agent":
          this.sendSelectionToAgent("send")
          break
        case "explain":
          this.sendSelectionToAgent("explain")
          break
      }
    }

    this.el.addEventListener("devide:ctx-before-open", this._onCtxBeforeOpen)
    this.el.addEventListener("devide:ctx-action", this._onCtxAction)
  },

  sendSelectionToAgent(intent) {
    const text = this._ctxSelection || ""
    if (!text) return

    if (new Blob([text]).size > SEND_AGENT_MAX_BYTES) {
      showClipboardToast("Selection too large to send to the agent (32 KB max)", {
        kind: "error"
      })
      return
    }

    this.pushEvent("terminal:send_agent_text", { text, path: this.path || "", intent })
  },

  makeState(doc, path) {
    return EditorState.create({
      doc,
      extensions: [
        lineNumbers(),
        highlightActiveLine(),
        history(),
        keymap.of([...defaultKeymap, ...historyKeymap]),
        this._onUpdate,
        ...pickLang(path)
      ]
    })
  },

  destroyed() {
    if (this._onSave) this.el.removeEventListener("devide:save", this._onSave)
    if (this._onRefresh) this.el.removeEventListener("devide:refresh", this._onRefresh)
    if (this._onCtxBeforeOpen) {
      this.el.removeEventListener("devide:ctx-before-open", this._onCtxBeforeOpen)
    }
    if (this._onCtxAction) this.el.removeEventListener("devide:ctx-action", this._onCtxAction)
    this.view?.destroy()
  }
}
