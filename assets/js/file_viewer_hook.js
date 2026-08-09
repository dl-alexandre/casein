import { EditorView } from "@codemirror/view"
import { showClipboardToast } from "./terminal_copy"
import {
  SEND_AGENT_MAX_BYTES,
  makeEditorState,
  revealLine,
  runEditorCtxAction
} from "./editor_core"

function setDirty(dirty) {
  const el = document.getElementById("dirty-indicator")
  if (!el) return
  el.dataset.dirty = dirty ? "true" : "false"
  el.textContent = dirty ? "● unsaved" : "saved"
}

function setStale(stale) {
  const el = document.getElementById("stale-indicator")
  if (!el) return
  el.dataset.stale = stale ? "true" : "false"
  el.textContent = stale ? "● changed on disk" : ""
}

export const FileViewerHook = {
  mounted() {
    this.path = null
    this.version = null
    this.savedDoc = ""
    this.renderMode = "source"
    this.isMarkdown = false
    this.renderedHtml = ""

    this.sourceEl = document.createElement("div")
    this.sourceEl.className = "file-viewer-source"
    this.renderedEl = document.createElement("div")
    this.renderedEl.className = "casein-markdown hidden"
    this.el.append(this.sourceEl, this.renderedEl)

    this._onSave = () => {
      if (!this.path || !this.version) return
      this.pushEvent("file:save", {
        path: this.path,
        content: this.view.state.doc.toString(),
        version: this.version
      })
    }

    const onUpdate = EditorView.updateListener.of(u => {
      if (u.docChanged) {
        const cur = this.view.state.doc.toString()
        setDirty(cur !== this.savedDoc)
      }
    })
    this._onUpdate = onUpdate

    this.view = new EditorView({
      state: makeEditorState("", null, { onUpdate, onSave: () => this._onSave() }),
      parent: this.sourceEl
    })

    this.handleEvent("file:loaded", ({ path, content, version, line, markdown, render_mode, rendered_html }) => {
      this.path = path
      this.version = version
      this.savedDoc = content
      this.isMarkdown = !!markdown
      this.renderedHtml = rendered_html || ""
      this.renderMode = this.isMarkdown ? (render_mode || "source") : "source"
      this.view.setState(this.makeState(content, path))
      this.renderedEl.innerHTML = this.renderedHtml
      this.applyMode()
      setDirty(false)
      setStale(false)
      revealLine(this.view, line)
    })

    this.handleEvent("file:cleared", () => {
      this.path = null
      this.version = null
      this.savedDoc = ""
      this.renderMode = "source"
      this.isMarkdown = false
      this.renderedHtml = ""
      this.view.setState(this.makeState("", null))
      this.renderedEl.innerHTML = ""
      this.applyMode()
      setDirty(false)
      setStale(false)
    })

    this.handleEvent("save:ok", ({ version, rendered_html }) => {
      this.version = version
      this.savedDoc = this.view.state.doc.toString()
      if (typeof rendered_html === "string") {
        this.renderedHtml = rendered_html
        this.renderedEl.innerHTML = rendered_html
      }
      setDirty(false)
      setStale(false)
    })

    // Filesystem watch: reload clean buffers; surface a stale marker when dirty
    // so we never clobber unsaved edits (save path still uses version tokens).
    this.handleEvent("file:disk_changed", ({ path }) => {
      if (!this.path || path !== this.path) return
      const dirty = this.view.state.doc.toString() !== this.savedDoc
      if (dirty) {
        setStale(true)
      } else {
        this.pushEvent("file:refresh", {})
      }
    })

    this.handleEvent("file:render_mode", ({ mode, rendered_html }) => {
      this.renderMode = this.isMarkdown ? (mode || "source") : "source"
      if (typeof rendered_html === "string") {
        this.renderedHtml = rendered_html
        this.renderedEl.innerHTML = rendered_html
      }
      this.applyMode()
    })

    this._onRefresh = () => {
      const dirty = this.view.state.doc.toString() !== this.savedDoc
      if (dirty && !confirm("You have unsaved changes. Discard them and refresh?")) return
      this.pushEvent("file:refresh", {})
    }

    this._onFileMode = event => {
      const mode = event.detail?.mode || "source"
      if (!this.path || !this.version) return

      this.pushEvent("file:render_mode", {
        mode,
        path: this.path,
        content: this.view.state.doc.toString(),
        version: this.version
      })
    }

    this._onRenderedClick = event => {
      const link = event.target.closest?.("a[href]")
      if (!link) return

      const href = link.getAttribute("href") || ""
      const workspacePath = workspaceFilePath(href)

      if (workspacePath) {
        event.preventDefault()
        this.pushEvent("annotation:open", { path: workspacePath })
        return
      }

      const external = externalTarget(href)
      if (!external) return

      event.preventDefault()
      if (confirm(`Open external link?\n\n${external}`)) {
        window.open(external, "_blank", "noopener")
      }
    }

    this.el.addEventListener("casein:save", this._onSave)
    this.el.addEventListener("casein:refresh", this._onRefresh)
    this.el.addEventListener("casein:file-mode", this._onFileMode)
    this.renderedEl.addEventListener("click", this._onRenderedClick)

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
      const action = e?.detail?.action

      if (runEditorCtxAction(this.view, action, {
        ctxSelection: this._ctxSelection,
        onSave: this._onSave
      })) {
        return
      }

      switch (action) {
        case "send_to_agent":
          this.sendSelectionToAgent("send")
          break
        case "explain":
          this.sendSelectionToAgent("explain")
          break
        case "render_source":
          this._onFileMode({detail: {mode: "source"}})
          break
        case "render_rendered":
          this._onFileMode({detail: {mode: "rendered"}})
          break
      }
    }

    this.el.addEventListener("casein:ctx-before-open", this._onCtxBeforeOpen)
    this.el.addEventListener("casein:ctx-action", this._onCtxAction)
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
    return makeEditorState(doc, path, { onUpdate: this._onUpdate, onSave: () => this._onSave() })
  },

  applyMode() {
    const rendered = this.isMarkdown && this.renderMode === "rendered"
    this.sourceEl.classList.toggle("hidden", rendered)
    this.renderedEl.classList.toggle("hidden", !rendered)

    if (!rendered) {
      this.view.requestMeasure()
    }
  },

  destroyed() {
    if (this._onSave) this.el.removeEventListener("casein:save", this._onSave)
    if (this._onRefresh) this.el.removeEventListener("casein:refresh", this._onRefresh)
    if (this._onFileMode) this.el.removeEventListener("casein:file-mode", this._onFileMode)
    if (this._onRenderedClick) this.renderedEl.removeEventListener("click", this._onRenderedClick)
    if (this._onCtxBeforeOpen) {
      this.el.removeEventListener("casein:ctx-before-open", this._onCtxBeforeOpen)
    }
    if (this._onCtxAction) this.el.removeEventListener("casein:ctx-action", this._onCtxAction)
    this.view?.destroy()
  }
}

function workspaceFilePath(href) {
  try {
    const url = new URL(href, window.location.href)
    if (url.origin !== window.location.origin) return null

    const match = url.pathname.match(/^\/api\/workspaces\/[^/]+\/files\/(.+)$/)
    if (!match) return null

    return match[1].split("/").map(segment => decodeURIComponent(segment)).join("/")
  } catch (_error) {
    return null
  }
}

function externalTarget(href) {
  if (!/^https?:\/\//i.test(href)) return null

  try {
    const url = new URL(href, window.location.href)
    return url.origin !== window.location.origin ? url.href : null
  } catch (_error) {
    return null
  }
}
