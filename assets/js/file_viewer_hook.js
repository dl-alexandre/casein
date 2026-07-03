import { EditorState } from "@codemirror/state"
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { javascript } from "@codemirror/lang-javascript"
import { markdown } from "@codemirror/lang-markdown"
import { json } from "@codemirror/lang-json"

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
    this.view?.destroy()
  }
}
