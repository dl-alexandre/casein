// tmux choose-tree keyboard navigation for the session and window dropdowns.
//
// Mounted on any <details> whose entries carry [data-picker-item]. Opening
// the dropdown moves the selection to the [data-picker-active] entry — the
// session/window the terminal is attached to, exactly where tmux's own
// picker would start — so the highlighted entry is always what Enter (or
// releasing a held C-b s / C-b w) navigates to. This replaces tmux's
// choose-tree; the real picker is never invoked.
//
// ↓/↑ move across visible items (shell, sessions, expanded windows, links),
// → on a session with windows expands them and enters the first window,
// ← collapses back to the session — or, when there is nothing to collapse
// and the <details> carries data-picker-hop-left="#other-picker", hops to
// that sibling picker (window picker ← back out to the session picker).
// Typing filters the visible entries (tmux choose-tree's `f`); Backspace
// edits the filter, Escape clears it first and closes on the second press.
// In the session and window pickers: `o` opens the focused entry in a new tab
// and `l` copies its shareable link (session links always include `?session=`;
// window links include session + window when attached). In the window picker,
// `&` kills the focused top-level window row after the normal confirmation.
//
// Expansion stays client-side: → / ← click the same per-session toggle button
// the mouse uses (`#session-windows-toggle-<dom_id>`), so chevron rotation and
// display state never drift from pointer-driven toggles.

import {copyPickerLink} from "./picker_link_copy"

export const SessionPicker = {
  mounted() {
    this._filter = ""
    this._previewCache = new Map()
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)
    this._onFocusin = () => this.schedulePreview()
    this._onToggle = () => {
      if (this.el.open) {
        this.focusInitial()
      } else {
        if (this._filter) {
          this._filter = ""
          this.applyFilter()
        }
        // Captures go stale the moment the menu closes.
        this._previewCache.clear()
        clearTimeout(this._previewTimer)
        this.renderPreview(null)
      }
    }
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("click", this._onClick, true)
    this.el.addEventListener("toggle", this._onToggle)
    this.el.addEventListener("focusin", this._onFocusin)
  },

  destroyed() {
    clearTimeout(this._previewTimer)
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("click", this._onClick, true)
    this.el.removeEventListener("toggle", this._onToggle)
    this.el.removeEventListener("focusin", this._onFocusin)
  },

  handleClick(e) {
    const item = e.target?.closest?.('a[data-picker-item][href][phx-click]')
    if (!item || !this.el.contains(item)) return

    if (wantsBrowserNavigation(e)) {
      e.stopPropagation()
      return
    }

    // Picker rows are real links for copy/open/fallback, but an ordinary
    // same-tab click should behave like the tmux keybinding: send the LiveView
    // switch event and keep the current LiveView mounted.
    e.preventDefault()
  },

  isSessionPicker() {
    return this.el.id?.startsWith("session-dropdown-")
  },

  isWindowPicker() {
    return this.el.id?.startsWith("window-dropdown-")
  },

  pickerLinkKind() {
    return this.isWindowPicker() ? "window" : "session"
  },

  pickerShortcutsEnabled() {
    return this.isSessionPicker() || this.isWindowPicker()
  },

  openCurrentInNewTab() {
    const item = this.currentItem()
    const url = item && openUrlForItem(item)
    if (!url) return
    window.open(url, "_blank", "noopener,noreferrer")
  },

  copyCurrentLink() {
    const item = this.currentItem()
    if (!item) return

    const meta = copyMetaForItem(item)
    if (!meta?.url) return

    copyPickerLink(meta.url, meta.kind)
  },

  // Rename the focused entry inline. A top-level window row (window picker)
  // renames the window; a top-level session row renames the session. Nested
  // child rows (windows listed under a non-active session in the session
  // picker) are skipped — renaming there would target the wrong session.
  renameCurrentItem() {
    const item = this.currentItem()
    if (!item || item.hasAttribute("data-picker-parent")) return

    const windowId = item.getAttribute("phx-value-window-id")
    if (windowId) {
      this.pushEvent("tmux:rename_start", { "window-id": windowId })
      return
    }

    const sessionId = item.getAttribute("phx-value-session-id")
    if (sessionId) {
      this.pushEvent("terminal:rename_session_start", { "session-id": sessionId })
    }
  },

  killCurrentWindow() {
    const item = this.currentItem()
    if (!item || item.hasAttribute("data-picker-parent")) return

    const button = pickerRow(item)?.querySelector?.("[data-picker-window-kill]")
    if (!button || button.disabled) return

    button.click()
  },

  // The `open` attribute is browser-set, so it is not in the server-rendered
  // HTML and a LiveView patch of this <details> strips it, snapping the
  // dropdown shut. That bites constantly here because opening the picker
  // itself triggers a refresh (terminal:refresh_sessions /
  // tmux:refresh_topology) whose re-render — new data-version, activity
  // dots — patches this element one round-trip after it opens. Carry the
  // pre-patch open state across the morph.
  beforeUpdate() {
    this._wasOpen = this.el.open
  },

  updated() {
    if (this._wasOpen && !this.el.open) this.el.setAttribute("open", "")
    // A patch wipes inline styles, the filter line, and the preview pane;
    // re-impose them.
    if (this._filter) this.applyFilter()
    if (this.el.open) this.renderPreview(this._previewText)
    // A patch can also replace or remove the focused entry (a window died,
    // the list reordered), dropping focus to <body> and leaving the open
    // picker with no selection. Re-seat it on the active entry.
    if (this.el.open && !this.currentItem()) this.focusInitial()
  },

  // -- choose-tree preview -------------------------------------------------
  //
  // Focusing an entry shows a text capture of its tmux target below the list
  // (tmux choose-tree's preview pane). Entries identify their target through
  // the phx-value attrs they already carry: phx-value-tmux-session (session
  // entries; absent on window entries, where the server uses the attached
  // session) and phx-value-window-id. Entries with neither (links, refresh)
  // hide the preview. Replies render client-side via pushEvent's reply so an
  // open dropdown is never re-rendered; captures are debounced 200ms and
  // cached per target while the menu stays open.

  schedulePreview() {
    clearTimeout(this._previewTimer)
    if (!this.el.open) return

    const item = this.currentItem()
    const payload = item && previewTarget(item)
    if (!payload) {
      this.renderPreview(null)
      return
    }

    const key = `${payload["tmux-session"] || ""}\x00${payload["window-id"] || ""}`
    if (this._previewCache.has(key)) {
      this.renderPreview(this._previewCache.get(key))
      return
    }

    // Drop the prior entry's capture immediately so focus moves never flash
    // stale scrollback while the debounced fetch for the new target runs.
    this.renderPreview(null)

    this._previewTimer = setTimeout(() => {
      this.pushEvent("terminal:picker_preview", payload, (reply) => {
        const text = reply && reply.text ? reply.text : null
        this._previewCache.set(key, text)
        // Only render if the selection still points at this target.
        const current = this.currentItem()
        if (current && JSON.stringify(previewTarget(current)) === JSON.stringify(payload)) {
          this.renderPreview(text)
        }
      })
    }, 200)
  },

  renderPreview(text) {
    this._previewText = text
    const pane = this.el.querySelector("[data-picker-preview]")
    if (!pane) return

    pane.textContent = text || ""
    pane.style.display = text ? "block" : "none"
  },

  handleKeydown(e) {
    if (!this.el.open) return

    // An inline rename form lives inside the dropdown. While its field is
    // focused, every keystroke (printable keys, arrows, Escape) belongs to the
    // input — typing the new name, not type-to-filter or list navigation. Let
    // the input (and its own phx-keydown Escape→cancel) handle them.
    const target = e.target
    if (
      target &&
      (target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.isContentEditable)
    ) {
      return
    }

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.moveFocus(1)
        break
      case "ArrowUp":
        e.preventDefault()
        this.moveFocus(-1)
        break
      case "ArrowRight":
        e.preventDefault()
        this.expandCurrent()
        break
      case "ArrowLeft":
        e.preventDefault()
        this.collapseCurrent()
        break
      case "Escape":
        e.preventDefault()
        if (this._filter) {
          this._filter = ""
          this.applyFilter()
          break
        }
        this.el.removeAttribute("open")
        this.el.querySelector("summary")?.focus()
        break
      case "Backspace":
        if (this._filter) {
          e.preventDefault()
          this._filter = this._filter.slice(0, -1)
          this.applyFilter()
        }
        break
      case "o":
      case "l":
        if (this.pickerShortcutsEnabled()) {
          e.preventDefault()
          if (e.key === "o") this.openCurrentInNewTab()
          else this.copyCurrentLink()
        }
        break
      case "r":
        if (this.pickerShortcutsEnabled()) {
          e.preventDefault()
          this.renameCurrentItem()
        }
        break
      case "&":
        if (this.isWindowPicker()) {
          e.preventDefault()
          this.killCurrentWindow()
        }
        break
      default:
        // Type-to-filter: printable keys narrow the list. A leading space is
        // left alone so it keeps activating the focused button natively.
        if (
          e.key.length === 1 &&
          !e.ctrlKey &&
          !e.metaKey &&
          !e.altKey &&
          (this._filter !== "" || e.key !== " ")
        ) {
          e.preventDefault()
          this._filter += e.key
          this.applyFilter()
        }
    }
  },

  // Hide entries that don't match the typed filter and surface the query in
  // the menu's [data-picker-filter] line. Inline styles only — LiveView
  // patches wipe them, so updated() re-applies.
  applyFilter() {
    const query = this._filter.toLowerCase()
    const display = this.el.querySelector("[data-picker-filter]")

    if (display) {
      display.textContent = this._filter ? `filter: ${this._filter}` : ""
      display.style.display = this._filter ? "block" : "none"
    }

    this.el.querySelectorAll("[data-picker-item]").forEach((el) => {
      const match = query === "" || itemFilterText(el).includes(query)
      el.style.display = match ? "" : "none"
    })

    // Keep the selection on a matching entry while narrowing.
    const current = this.currentItem()
    if (query !== "" && (!current || current.style.display === "none")) {
      this.visibleItems()[0]?.focus()
    }
  },

  visibleItems() {
    return Array.from(this.el.querySelectorAll("[data-picker-item]")).filter(
      (el) => el.offsetParent !== null
    )
  },

  currentItem() {
    return document.activeElement?.closest?.("[data-picker-item]") || null
  },

  moveFocus(delta) {
    const items = this.visibleItems()
    if (items.length === 0) return

    const index = items.indexOf(this.currentItem())
    const next =
      index === -1
        ? delta > 0
          ? 0
          : items.length - 1
        : Math.min(Math.max(index + delta, 0), items.length - 1)

    items[next].focus()
  },

  focusInitial() {
    requestAnimationFrame(() => {
      // A patch while the picker is open re-fires toggle (open is stripped and
      // restored, see beforeUpdate/updated); don't yank the selection away
      // from an entry the user already navigated to.
      if (this.currentItem() && this.el.contains(document.activeElement)) return

      const items = this.visibleItems()
      const active = items.find((el) => el.hasAttribute("data-picker-active"))
      ;(active || items[0])?.focus()
    })
  },

  expandCurrent() {
    const group = this.ownedGroup(this.currentItem())
    if (!group?.container || !group.toggle) return

    if (!isVisible(group.container)) group.toggle.click()

    requestAnimationFrame(() => {
      group.container.querySelector("[data-picker-item]")?.focus()
    })
  },

  collapseCurrent() {
    const item = this.currentItem()

    // Inside a child list (window row → session, pane row → window): collapse
    // the parent group and refocus its owner row.
    const parent = this.parentGroup(item)
    if (parent) {
      if (parent.container && isVisible(parent.container)) parent.toggle?.click()
      this.el.querySelector(parent.owner)?.focus()
      return
    }

    // On a top-level row: collapse its own open child list, else back out to
    // the sibling picker (window picker ← session picker).
    const owned = this.ownedGroup(item)
    if (owned?.container && isVisible(owned.container)) {
      owned.toggle?.click()
      return
    }
    this.hopLeft()
  },

  // Resolve the collapsible child list a row owns, across both pickers:
  //   session row → its window list, named by data-picker-windows-id (a bare
  //     dom id; container is #session-windows-<id>)
  //   window row  → its pane list, named by data-picker-panes-id (the
  //     container element id itself, #window-panes-<frag>)
  ownedGroup(item) {
    const windowsId = item?.dataset.pickerWindowsId
    if (windowsId) {
      return this.group(`session-windows-${windowsId}`, `session-windows-toggle-${windowsId}`)
    }
    const panesId = item?.dataset.pickerPanesId
    if (panesId) {
      return this.group(panesId, panesId.replace(/^window-panes-/, "window-panes-toggle-"))
    }
    return null
  },

  // Resolve the parent group a child row sits in, plus a selector for its
  // owner row to refocus after collapsing. data-picker-parent is a bare
  // session dom id in the session picker and the pane-list element id in the
  // window picker; the matching owner row tells the two schemes apart.
  parentGroup(item) {
    const parentId = item?.dataset.pickerParent
    if (!parentId) return null

    const paneOwner = `[data-picker-panes-id="${cssEscape(parentId)}"]`
    if (this.el.querySelector(paneOwner)) {
      const toggleId = parentId.replace(/^window-panes-/, "window-panes-toggle-")
      return { ...this.group(parentId, toggleId), owner: paneOwner }
    }

    return {
      ...this.group(`session-windows-${parentId}`, `session-windows-toggle-${parentId}`),
      owner: `[data-picker-windows-id="${cssEscape(parentId)}"]`,
    }
  },

  group(containerId, toggleId) {
    return {
      container: this.el.querySelector(`#${cssEscape(containerId)}`),
      toggle: this.el.querySelector(`#${cssEscape(toggleId)}`),
    }
  },

  // Menu hop: ← with nothing left to collapse moves to the sibling picker
  // named by data-picker-hop-left (window picker → session picker), like
  // backing out of a submenu. Opening via the attribute fires its toggle,
  // so the target picker seats its own selection on the active entry.
  hopLeft() {
    const targetSelector = this.el.dataset.pickerHopLeft
    if (!targetSelector) return

    const target = document.querySelector(targetSelector)
    if (!target) return

    this.el.removeAttribute("open")
    target.setAttribute("open", "")
  },
}

// Filter matches the entry's name/detail spans ([data-picker-label]) so index
// digits, window-count badges, and kbd hints don't produce surprise matches.
// Entries without tagged labels fall back to their full text.
function itemFilterText(el) {
  const labels = el.querySelectorAll("[data-picker-label]")
  const text = labels.length
    ? Array.from(labels)
        .map((node) => node.textContent)
        .join(" ")
    : el.textContent
  return text.toLowerCase()
}

function previewTarget(el) {
  const session = el.getAttribute("phx-value-tmux-session")
  const windowId = el.getAttribute("phx-value-window-id")
  const payload = {}

  if (session) payload["tmux-session"] = session
  if (windowId) payload["window-id"] = windowId

  return Object.keys(payload).length > 0 ? payload : null
}

function isVisible(el) {
  return getComputedStyle(el).display !== "none"
}

function cssEscape(value) {
  return window.CSS?.escape ? CSS.escape(value) : value
}

function pickerRow(item) {
  return item?.closest?.(".group") || item
}

export function wantsBrowserNavigation(event) {
  return (
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey ||
    event.button === 1
  )
}

function openUrlForItem(item) {
  const row = pickerRow(item)
  const external = row?.querySelector?.('a[target="_blank"][href]')
  if (external?.href) return external.href
  const share = row?.querySelector?.("[data-copy-session-link]")
  if (share?.dataset.copySessionLink) return share.dataset.copySessionLink
  if (item.matches?.("a[href]") && item.href) return item.href
  return null
}

function copyMetaForItem(item) {
  const row = pickerRow(item)
  const btn = row?.querySelector?.("[data-copy-session-link]")
  const url = btn?.dataset.copySessionLink || (item.matches?.("a[href]") && item.href) || null
  if (!url) return null

  return {url, kind: btn?.dataset.copyLinkKind || "session"}
}
