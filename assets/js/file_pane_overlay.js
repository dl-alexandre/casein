// File-pane overlay: a per-tmux-pane CodeMirror editor positioned over the
// pane's rectangle (the tmux pane itself runs a tiny holder script). One hook
// instance per `#file-pane-<id>` root rendered by terminal_chrome.ex.
//
// Contracts:
//   * Transport is broadcast-with-id like `ghostty:render`: the server pushes
//     "file-pane:loaded" %{pane_id, path, content, version, line, error} on
//     every active-tab change/load; each instance filters on its own paneId.
//     On mount the hook hydrates itself via a `pane:input` type:"hydrate"
//     reply so a reconnect doesn't wait for the next registry broadcast.
//   * The server owns the tab list + active path (the tab strip is LV-rendered
//     OUTSIDE this hook — in the header on desktop, in-pane on mobile — and
//     found via [data-file-pane-strip]). The client owns dirty buffers: a
//     per-tab EditorState cache preserves undo history and unsaved edits across
//     tab switches. Dirty is viewer-local state, so on each clean↔dirty
//     transition the hook pushes "file-pane:dirty" {pane-id, path, dirty} and
//     the server re-renders the dot in the strip (no client DOM toggling).
//     Content reaches the server only on save (`pane:input` type:"save").
//   * Focus model is direct (no click shield): CodeMirror is same-DOM, so the
//     capture-phase leader/palette keys still win. Focusing the editor when
//     the pane isn't tmux-active pushes the existing UI-only tmux:select_pane
//     (loop-guarded); Ghostty never attaches to the holder pane.

import { EditorView } from "@codemirror/view"
import {
  makeEditorState,
  revealLine,
  fileErrorMessage,
  runEditorCtxAction,
  SEND_AGENT_MAX_BYTES,
} from "./editor_core"
import {
  applyOverlayRect,
  bindPaneSectionGeometryObserver,
  resolveOverlayRect,
} from "./pane_overlay_rect.mjs"
import { showClipboardToast } from "./terminal_copy"

const FOCUS_PUSH_GUARD_MS = 500

export const FilePaneOverlay = {
  mounted() {
    this.paneId = this.el.dataset.paneId
    this.editorEl = this.el.querySelector("[data-file-pane-editor]")
    this.tabCache = new Map() // path -> { state, savedDoc, version, dirty }
    this.activePath = null
    this.focusPushAt = 0

    this.applyRect()
    this._sectionGeometryObserver = bindPaneSectionGeometryObserver(this.el, () => this.applyRect())

    this._onUpdate = EditorView.updateListener.of((update) => {
      if (update.docChanged) this.syncDirty()
    })

    this.view = new EditorView({
      state: this.makeState("", null),
      parent: this.editorEl
    })

    this.handleEvent("file-pane:loaded", (payload) => {
      if (!payload || payload.pane_id !== this.paneId) return
      this.load(payload)
    })

    // Hydrate on (re)mount: reconnects and late mounts must not wait for the
    // next registry broadcast to show content.
    this.pushEvent("pane:input", { "pane-id": this.paneId, type: "hydrate" }, (reply) => {
      if (reply?.active) this.load({ pane_id: this.paneId, ...reply.active })
    })

    // Direct focus model: entering the editor selects the pane (UI-only —
    // the server refuses real tmux focus for feature panes). Guarded so the
    // select_pane round trip re-focusing the editor can't loop.
    this._onFocusIn = () => {
      if (this.el.dataset.paneActive === "true") return
      const now = Date.now()
      if (now - this.focusPushAt < FOCUS_PUSH_GUARD_MS) return
      this.focusPushAt = now
      this.pushEvent("tmux:select_pane", { "pane-id": this.paneId })
    }
    this.el.addEventListener("focusin", this._onFocusIn)

    // Close-tab is client-first: only the client knows whether the buffer is
    // dirty, so the tab strip dispatches here and we confirm before pushing.
    this._onCloseTab = (event) => this.closeTab(event.detail?.path)
    this.el.addEventListener("devide:file-pane:close-tab", this._onCloseTab)

    // Right-click menus (shared ContextMenu hook). The editor body carries
    // data-ctx-menu="file_pane_editor"; refresh its dynamic ctx (selection,
    // active path) just before the menu opens, and execute the client actions
    // the menu dispatches back — the editor clipboard/save actions plus the
    // tab close/close-others and send-to-agent actions.
    this._onCtxBeforeOpen = () => {
      const sel = this.view.state.selection.main
      this._ctxSelection = this.view.state.sliceDoc(sel.from, sel.to)
      this.editorEl.dataset.ctxTargetId = this.el.id
      this.editorEl.dataset.ctxHasFile = this.activePath ? "true" : "false"
      this.editorEl.dataset.ctxHasSelection = this._ctxSelection ? "true" : "false"
      this.editorEl.dataset.ctxPath = this.activePath || ""
    }
    this.editorEl.addEventListener("devide:ctx-before-open", this._onCtxBeforeOpen)

    this._onCtxAction = (e) => {
      const { action, path } = e.detail || {}
      switch (action) {
        case "close_tab":
          this.closeTab(path)
          return
        case "close_others":
          this.closeOthers(path)
          return
        case "send_to_agent":
          this.sendSelectionToAgent("send")
          return
        case "explain":
          this.sendSelectionToAgent("explain")
          return
      }
      runEditorCtxAction(this.view, action, {
        ctxSelection: this._ctxSelection,
        onSave: () => this.save()
      })
    }
    this.el.addEventListener("devide:ctx-action", this._onCtxAction)
  },

  updated() {
    // Root re-renders reach here (the editor div is ignored): re-apply geometry
    // and re-measure. Dirty dots are server-rendered now, so nothing to restore.
    this.applyRect()
    this.view.requestMeasure()
  },

  reconnected() {
    // The server's viewer-local :file_pane_dirty resets on reconnect while this
    // hook (and its tabCache) survive — re-push every dirty buffer so the strip
    // dots come back.
    for (const [path, entry] of this.tabCache) {
      if (entry.dirty) this.pushDirty(path, true)
    }
  },

  destroyed() {
    this._sectionGeometryObserver?.disconnect()
    this._sectionGeometryObserver = null
    this.el.removeEventListener("focusin", this._onFocusIn)
    this.el.removeEventListener("devide:file-pane:close-tab", this._onCloseTab)
    this.editorEl.removeEventListener("devide:ctx-before-open", this._onCtxBeforeOpen)
    this.el.removeEventListener("devide:ctx-action", this._onCtxAction)
    this.placeholderEl?.remove()
    this.placeholderEl = null
    this.view?.destroy()
  },

  // --- server payload -> editor state ---------------------------------------

  load(payload) {
    const { path, content, version, line, error } = payload
    if (!path) return

    // Park the outgoing tab's live state (undo history + unsaved edits) before
    // switching away — whether the incoming tab is a real buffer or an error
    // placeholder. Must run before the error branch, or edits to the tab we're
    // leaving would be dropped when we later return to it.
    if (this.activePath && this.activePath !== path) {
      const parked = this.tabCache.get(this.activePath)
      if (parked) parked.state = this.view.state
    }

    if (error) {
      // Unopenable file (binary, too large, vanished): show a calm in-pane
      // placeholder over the editor rather than a transient error toast.
      this.showPlaceholder(path, error)
      this.activePath = path
      return
    }
    if (typeof content !== "string") return

    // A good load supersedes any placeholder from a prior unopenable tab.
    this.hidePlaceholder()

    const cached = this.tabCache.get(path)
    const switching = this.activePath !== path

    if (!cached) {
      const entry = { state: null, savedDoc: content, version, dirty: false }
      this.tabCache.set(path, entry)
      this.view.setState(this.makeState(content, path))
      entry.state = this.view.state
    } else if (switching) {
      // Returning to a previously opened tab: restore its parked state so undo
      // history and unsaved edits survive, then reconcile with fresh disk
      // content (only when the buffer is clean — a dirty buffer keeps its old
      // version so a save against a changed file conflicts instead of
      // clobbering).
      this.view.setState(cached.state || this.makeState(cached.savedDoc, path))
      this.reconcile(cached, content, version, path)
    } else {
      // Same tab refreshed (save round trip, reload, concurrent change).
      this.reconcile(cached, content, version, path)
    }

    this.activePath = path
    this.syncDirty()
    if (typeof line === "number" && line > 0) revealLine(this.view, line)
  },

  // Reconcile a tab entry with freshly read disk content.
  reconcile(entry, content, version, path) {
    const doc = this.view.state.doc.toString()

    if (doc === content) {
      // Buffer already matches disk (typical save ack): adopt the new version.
      entry.savedDoc = content
      entry.version = version
      entry.dirty = false
    } else if (!entry.dirty) {
      // Clean buffer, disk changed underneath: follow the disk.
      entry.savedDoc = content
      entry.version = version
      this.view.setState(this.makeState(content, path))
      entry.state = this.view.state
    }
    // Dirty buffer + disk changed: keep the user's edits AND the old version,
    // so the next save surfaces the optimistic-concurrency conflict.
  },

  // --- save -------------------------------------------------------------------

  save() {
    const path = this.activePath
    const entry = path && this.tabCache.get(path)
    if (!entry || !entry.version) return

    this.pushEvent(
      "pane:input",
      {
        "pane-id": this.paneId,
        type: "save",
        path,
        content: this.view.state.doc.toString(),
        version: entry.version
      },
      (reply) => {
        if (!reply || reply.ok) return
        const message =
          reply.error === "conflict"
            ? `Conflict: ${path} changed on disk. Your buffer is kept — copy your edits, then close and reopen the tab.`
            : `Save failed: ${reply.error}`
        showClipboardToast(message, { kind: "error" })
      }
    )
    // Success is confirmed by the registry broadcast ("file-pane:loaded" with
    // the fresh version), which reconcile() folds in without moving the cursor.
  },

  // --- tabs / dirty tracking ----------------------------------------------------

  closeTab(path) {
    if (!path) return
    const entry = this.tabCache.get(path)

    if (entry?.dirty) {
      const name = path.split("/").pop()
      if (!confirm(`Discard unsaved changes in ${name}?`)) return
    }

    this.tabCache.delete(path)
    this.pushEvent("pane:input", { "pane-id": this.paneId, type: "close_tab", path })
  },

  // Close every tab except `keepPath`. Tab paths come from the DOM (the
  // authoritative LV-rendered strip), not tabCache — a tab never visited has
  // no cache entry. The strip now lives OUTSIDE this hook (header on desktop,
  // in-pane on mobile), so gather tabs from every strip bound to this pane and
  // dedupe. One combined confirm if any of them is dirty.
  closeOthers(keepPath) {
    const paths = new Set()
    for (const strip of document.querySelectorAll("[data-file-pane-strip]")) {
      if (strip.dataset.filePaneStrip !== this.paneId) continue
      for (const tab of strip.querySelectorAll("[data-file-pane-tab]")) {
        if (tab.dataset.path) paths.add(tab.dataset.path)
      }
    }

    const others = Array.from(paths).filter((p) => p !== keepPath)
    if (!others.length) return

    if (
      others.some((p) => this.tabCache.get(p)?.dirty) &&
      !confirm("Discard unsaved changes in the other tabs?")
    ) {
      return
    }

    for (const p of others) {
      this.tabCache.delete(p)
      this.pushEvent("pane:input", { "pane-id": this.paneId, type: "close_tab", path: p })
    }
  },

  sendSelectionToAgent(intent) {
    const text = this._ctxSelection || ""
    if (!text) return

    if (new Blob([text]).size > SEND_AGENT_MAX_BYTES) {
      showClipboardToast("Selection too large to send to the agent (32 KB max)", { kind: "error" })
      return
    }

    this.pushEvent("terminal:send_agent_text", { text, path: this.activePath || "", intent })
  },

  syncDirty() {
    const path = this.activePath
    const entry = path && this.tabCache.get(path)
    if (!entry) return

    const dirty = this.view.state.doc.toString() !== entry.savedDoc
    if (dirty !== entry.dirty) {
      entry.dirty = dirty
      // Viewer-local: tell the server so it re-renders the dot in the strip
      // (which lives outside this hook). Only fires on transitions, not per
      // keystroke.
      this.pushDirty(path, dirty)
    }
  },

  pushDirty(path, dirty) {
    this.pushEvent("file-pane:dirty", { "pane-id": this.paneId, path, dirty })
  },

  // --- unopenable-file placeholder ----------------------------------------------

  // Lazily create an opaque panel covering the editor region. Client-owned —
  // appended to the hook root, not LV-rendered — so LV strip diffs never
  // clobber it. Fills the pane (chromeless); the mobile media query insets its
  // top below the in-pane strip, mirroring the editor.
  ensurePlaceholder() {
    if (this.placeholderEl?.isConnected) return this.placeholderEl

    const el = document.createElement("div")
    el.dataset.filePanePlaceholder = ""
    el.className =
      "absolute inset-0 z-20 flex flex-col items-center justify-center " +
      "gap-1 bg-zinc-950 px-6 text-center text-zinc-400"
    el.hidden = true

    const name = document.createElement("div")
    name.dataset.placeholderName = ""
    name.className = "font-mono text-sm text-zinc-200"

    const msg = document.createElement("div")
    msg.dataset.placeholderMessage = ""
    msg.className = "max-w-md text-xs leading-relaxed"

    el.append(name, msg)
    this.el.appendChild(el)
    this.placeholderEl = el
    return el
  },

  showPlaceholder(path, error) {
    const el = this.ensurePlaceholder()
    el.querySelector("[data-placeholder-name]").textContent = path.split("/").pop()
    el.querySelector("[data-placeholder-message]").textContent = fileErrorMessage(error)
    el.hidden = false
  },

  hidePlaceholder() {
    if (this.placeholderEl) this.placeholderEl.hidden = true
  },

  // --- geometry (borrowed from preview_pane_overlay.js) --------------------------

  applyRect() {
    const rect = resolveOverlayRect(this.el)
    applyOverlayRect(this.el, rect)
  },

  makeState(doc, path) {
    return makeEditorState(doc, path, {
      onUpdate: this._onUpdate,
      onSave: () => this.save(),
      // The overlay wrapper is zinc-950; light editor defaults vanish on it.
      dark: true
    })
  }
}
