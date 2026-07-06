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
//   * The server owns the tab list + active path (tab strip is LV-rendered in
//     the hook root, OUTSIDE the phx-update="ignore" editor div); the client
//     owns dirty buffers — a per-tab EditorState cache preserves undo history
//     and unsaved edits across tab switches. Content reaches the server only
//     on save (`pane:input` type:"save" with {path, content, version}).
//   * Focus model is direct (no click shield): CodeMirror is same-DOM, so the
//     capture-phase leader/palette keys still win. Focusing the editor when
//     the pane isn't tmux-active pushes the existing UI-only tmux:select_pane
//     (loop-guarded); Ghostty never attaches to the holder pane.

import { EditorView } from "@codemirror/view"
import { makeEditorState, revealLine } from "./editor_core"
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
  },

  updated() {
    // Tab-strip re-renders reach the root (the editor div is ignored):
    // re-apply geometry, re-mark dirty dots the diff wiped, re-measure.
    this.applyRect()
    this.reapplyDirtyMarkers()
    this.view.requestMeasure()
  },

  destroyed() {
    this._sectionGeometryObserver?.disconnect()
    this._sectionGeometryObserver = null
    this.el.removeEventListener("focusin", this._onFocusIn)
    this.el.removeEventListener("devide:file-pane:close-tab", this._onCloseTab)
    this.view?.destroy()
  },

  // --- server payload -> editor state ---------------------------------------

  load(payload) {
    const { path, content, version, line, error } = payload
    if (!path) return

    if (error) {
      showClipboardToast(`Could not load ${path}: ${error}`, { kind: "error" })
      return
    }
    if (typeof content !== "string") return

    // Park the outgoing tab's state (undo history + unsaved edits) first.
    if (this.activePath && this.activePath !== path) {
      const parked = this.tabCache.get(this.activePath)
      if (parked) parked.state = this.view.state
    }

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

  syncDirty() {
    const entry = this.activePath && this.tabCache.get(this.activePath)
    if (!entry) return

    const dirty = this.view.state.doc.toString() !== entry.savedDoc
    if (dirty !== entry.dirty) {
      entry.dirty = dirty
      this.setTabDot(this.activePath, dirty)
    }
  },

  setTabDot(path, dirty) {
    for (const tab of this.el.querySelectorAll("[data-file-pane-tab]")) {
      if (tab.dataset.path !== path) continue
      tab.querySelector("[data-dirty-dot]")?.classList.toggle("hidden", !dirty)
    }
  },

  // LV re-renders rebuild the tab strip with every dot hidden; restore the
  // client-owned dirty markers from the cache.
  reapplyDirtyMarkers() {
    for (const [path, entry] of this.tabCache) {
      if (entry.dirty) this.setTabDot(path, true)
    }
  },

  // --- geometry (borrowed from preview_pane_overlay.js) --------------------------

  applyRect() {
    const rect = resolveOverlayRect(this.el)
    applyOverlayRect(this.el, rect)
  },

  makeState(doc, path) {
    return makeEditorState(doc, path, {
      onUpdate: this._onUpdate,
      onSave: () => this.save()
    })
  }
}
