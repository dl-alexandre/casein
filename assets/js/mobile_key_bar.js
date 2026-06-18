// MobileKeyBar hook
//
// Renders an accessory key row above the terminal on narrow viewports where
// the soft keyboard has no Ctrl / Alt / Esc / Tab / arrow keys. Tapping a key
// synthesizes a `keydown` KeyboardEvent on the *currently active* terminal
// input. The terminal frontend already listens for `keydown` and reads
// `event.key` + modifier flags (raw PTY pane: vendor GhosttyTerminal,
// input[data-ghostty-input]), so no server-side change is needed — the bar
// just drives the same path a physical keyboard would.
//
// Ctrl/Alt are sticky one-shot modifiers: one tap arms (applies to the next
// key then auto-clears), double-tap locks until tapped off.
import { pasteFromNavigatorClipboard } from "./terminal_clipboard"
import { copyTextSync, showClipboardToast } from "./terminal_copy"

const INPUT_SELECTOR = '[data-ghostty-input="true"]'

// key spec -> the KeyboardEvent.key value the terminals expect
const KEY_DEFS = {
  Escape: { key: "Escape", code: "Escape" },
  Tab: { key: "Tab", code: "Tab" },
  ArrowUp: { key: "ArrowUp", code: "ArrowUp" },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown" },
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft" },
  ArrowRight: { key: "ArrowRight", code: "ArrowRight" }
}

export const MobileKeyBar = {
  mounted() {
    // Modifier latch state: "off" | "armed" (one-shot) | "locked"
    this.mods = { Control: "off", Alt: "off" }

    this.onPointerDown = (e) => {
      const btn = e.target.closest("[data-keybar-key]")
      if (!btn) return
      // Keep the terminal input focused so the soft keyboard never dismisses
      // and the synthetic event lands on the right element.
      e.preventDefault()
    }

    this.onClick = (e) => {
      const btn = e.target.closest("[data-keybar-key]")
      if (!btn) return
      e.preventDefault()
      const spec = btn.dataset.keybarKey

      if (spec === "Control" || spec === "Alt") {
        this._cycleModifier(spec)
        return
      }

      if (spec === "CtrlC") {
        this._send({ key: "c", ctrlKey: true })
        return
      }

      if (spec === "Paste") {
        // This click is the user gesture iOS requires for clipboard read.
        this._paste()
        return
      }

      if (spec === "Select") {
        this._openSelectOverlay()
        return
      }

      if (spec === "Palette") {
        this.pushEvent("palette:open", {})
        return
      }

      if (spec === "FontDown" || spec === "FontUp") {
        window.dispatchEvent(new CustomEvent("devide:font-size", { detail: { delta: spec === "FontUp" ? 1 : -1 } }))
        return
      }

      const def = KEY_DEFS[spec]
      if (!def) return
      this._send(def)
    }

    // Capture-phase interceptor so an armed Ctrl/Alt also applies to keys typed
    // on the *system* soft keyboard — not just the bar's own keys. Without this,
    // arming Ctrl then tapping "b" on the OS keyboard sends a literal "b" (the
    // real keydown never sees our latch). We swallow the trusted event and
    // re-dispatch it with the modifier(s) applied.
    this.onCaptureKeydown = (e) => this._interceptKeydown(e)
    document.addEventListener("keydown", this.onCaptureKeydown, true)

    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
    this.keyButtons = Array.from(this.el.querySelectorAll("[data-keybar-key]"))
    this._renderModifierState()
    this._setupViewportTracking()
    this.onFocusIn = (e) => this._scrollFocusedInputIntoView(e)
    document.addEventListener("focusin", this.onFocusIn)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onCaptureKeydown, true)
    document.removeEventListener("focusin", this.onFocusIn)
    const vv = window.visualViewport
    if (vv && this.onViewport) {
      vv.removeEventListener("resize", this.onViewport)
      vv.removeEventListener("scroll", this.onViewport)
    }
    if (this.__viewportFrame) cancelAnimationFrame(this.__viewportFrame)
    document.documentElement.classList.remove("devide-keyboard-open")
    this.el.classList.remove("devide-keybar-app-mode")
    document.documentElement.style.removeProperty("--devide-mobile-keybar-bottom")
    document.documentElement.style.removeProperty("--devide-mobile-terminal-inset")
  },

  _interceptKeydown(e) {
    // Only rewrite genuine user keystrokes; let our own synthetic events pass.
    if (!e.isTrusted) return
    if (this.mods.Control === "off" && this.mods.Alt === "off") return

    // Only act on keystrokes headed for a terminal input.
    const t = e.target
    if (!t || !t.matches || !t.matches(INPUT_SELECTOR)) return

    const wantCtrl = this.mods.Control !== "off"
    const wantAlt = this.mods.Alt !== "off"

    // If the real event already carries the modifier (hardware keyboard), don't
    // double-apply — just consume the one-shot latch and let it through.
    if ((wantCtrl && e.ctrlKey) || (wantAlt && e.altKey)) {
      this._consumeOneShotModifiers()
      return
    }

    e.preventDefault()
    e.stopImmediatePropagation()

    const init = {
      key: e.key,
      code: e.code || "",
      bubbles: true,
      cancelable: true,
      ctrlKey: wantCtrl || e.ctrlKey,
      altKey: wantAlt || e.altKey,
      shiftKey: e.shiftKey,
      metaKey: e.metaKey
    }
    t.dispatchEvent(new KeyboardEvent("keydown", init))
    t.dispatchEvent(new KeyboardEvent("keyup", init))

    this._consumeOneShotModifiers()
    this._refocus()
  },

  // Pin the bar to the bottom of the *visual* viewport so it rides just above
  // the soft keyboard. When the keyboard opens, visualViewport.height shrinks
  // and offsetTop may grow; the gap between the layout viewport bottom and the
  // visual viewport bottom is the keyboard height.
  _setupViewportTracking() {
    const vv = window.visualViewport
    if (!vv) return // desktop / unsupported — bar stays at its CSS position

    const update = () => {
      this.__viewportFrame = null
      const gap = window.innerHeight - (vv.height + vv.offsetTop)
      // gap is approximately the soft-keyboard height when fixed elements are
      // laid out against the layout viewport. Ignore sub-pixel churn from the
      // keyboard animation so the bar does not visibly jitter.
      const next = Math.max(0, Math.round(gap))
      if (this.__lastViewportGap != null && Math.abs(this.__lastViewportGap - next) < 2) return

      this.__lastViewportGap = next
      const barHeight = Math.ceil(this.el.getBoundingClientRect().height || 0)
      const inset = next + barHeight

      const keyboardOpen = next > 40
      document.documentElement.classList.toggle("devide-keyboard-open", keyboardOpen)
      this.el.classList.toggle("devide-keybar-app-mode", keyboardOpen)
      document.documentElement.style.setProperty("--devide-mobile-keybar-bottom", `${next}px`)
      document.documentElement.style.setProperty("--devide-mobile-terminal-inset", `${inset}px`)
      window.dispatchEvent(new Event("resize"))
    }

    this.onViewport = () => {
      if (this.__viewportFrame) return
      this.__viewportFrame = requestAnimationFrame(update)
    }

    vv.addEventListener("resize", this.onViewport)
    vv.addEventListener("scroll", this.onViewport)
    this.onViewport()
  },

  // off -> armed -> locked -> off
  _cycleModifier(mod) {
    const next = { off: "armed", armed: "locked", locked: "off" }[this.mods[mod]]
    this.mods[mod] = next
    this._renderModifierState()
    this._refocus()
  },

  _consumeOneShotModifiers() {
    for (const mod of ["Control", "Alt"]) {
      if (this.mods[mod] === "armed") this.mods[mod] = "off"
    }
    this._renderModifierState()
  },

  // Read the system clipboard and inject it into the active terminal. Prefer a
  // single synthetic paste event; fall back to per-key dispatch for browsers
  // that don't support constructing clipboard data.
  async _paste() {
    try {
      await pasteFromNavigatorClipboard({
        sendText: (text) => this._injectText(text),
        uploadImage: (payload) => this._pushLiveEvent("terminal:paste_image", payload),
        uploadFile: (payload) => this._pushLiveEvent("terminal:paste_file", payload),
        pathFormat: "shell",
        onError: (message) => console.warn("terminal paste failed", message)
      })
    } catch (error) {
      console.warn("terminal paste failed", error)
    }
  },

  _injectText(text) {
    const input = this._activeInput()
    if (!input) return
    input.focus()

    if (this._dispatchPasteText(input, text)) {
      this._refocus()
      return
    }

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

    this._refocus()
  },

  _dispatchPasteText(input, text) {
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
  },

  _pushLiveEvent(event, payload) {
    return new Promise((resolve) => {
      this.pushEvent(event, payload, (reply) => resolve(reply || {}))
    })
  },

  // Locate the <pre> of the active terminal (focused pane, else any terminal)
  // so we can snapshot its visible text.
  _activeTerminalPre() {
    const container =
      document.querySelector('[data-pane-active="true"]') ||
      document.querySelector('[id^="ghostty-"]')
    return container ? container.querySelector("pre") : null
  },

  // Mobile copy-out that doesn't fight the live terminal. Snapshot the current
  // screen text into a static, fully-selectable overlay: iOS long-press selects
  // any part (no input-focus theft, no re-render wiping it), plus a Copy-all
  // shortcut. Inline styles only — no dependency on freshly-built CSS.
  _openSelectOverlay() {
    const pre = this._activeTerminalPre()
    const text = pre ? (pre.textContent || "") : ""
    if (!text.trim()) return

    const overlay = document.createElement("div")
    Object.assign(overlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "60",
      display: "flex",
      flexDirection: "column",
      background: "rgba(9,9,11,0.97)",
      paddingTop: "env(safe-area-inset-top)",
      paddingBottom: "env(safe-area-inset-bottom)"
    })

    const bar = document.createElement("div")
    Object.assign(bar.style, {
      display: "flex",
      gap: "0.5rem",
      alignItems: "center",
      justifyContent: "space-between",
      padding: "0.5rem 0.75rem",
      borderBottom: "1px solid #3f3f46",
      color: "#e4e4e7",
      font: "13px ui-sans-serif, system-ui, sans-serif"
    })
    const hint = document.createElement("span")
    hint.textContent = "Long-press to select · or"
    hint.style.opacity = "0.7"
    const btns = document.createElement("div")
    btns.style.display = "flex"
    btns.style.gap = "0.5rem"

    const copyBtn = document.createElement("button")
    copyBtn.type = "button"
    copyBtn.textContent = "Copy all"
    Object.assign(copyBtn.style, {
      border: "1px solid #3f3f46",
      borderRadius: "0.375rem",
      padding: "0.25rem 0.75rem",
      background: "#18181b",
      color: "#e4e4e7"
    })
    copyBtn.addEventListener("click", () => {
      if (copyTextSync(text)) {
        copyBtn.textContent = "Copied"
        showClipboardToast("Copied to clipboard")
        setTimeout(() => overlay.remove(), 500)
      } else {
        copyBtn.textContent = "Blocked"
        showClipboardToast("Copy blocked — long-press text and use Copy", { kind: "pending" })
      }
    })

    const doneBtn = document.createElement("button")
    doneBtn.type = "button"
    doneBtn.textContent = "Done"
    Object.assign(doneBtn.style, {
      border: "1px solid #3f3f46",
      borderRadius: "0.375rem",
      padding: "0.25rem 0.75rem",
      background: "#18181b",
      color: "#e4e4e7"
    })
    doneBtn.addEventListener("click", () => overlay.remove())

    btns.appendChild(copyBtn)
    btns.appendChild(doneBtn)
    bar.appendChild(hint)
    bar.appendChild(btns)

    const body = document.createElement("pre")
    body.textContent = text
    Object.assign(body.style, {
      margin: "0",
      flex: "1",
      overflow: "auto",
      padding: "0.75rem",
      color: "#e4e4e7",
      font: "13px ui-monospace, SFMono-Regular, Menlo, monospace",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word",
      userSelect: "text",
      webkitUserSelect: "text",
      webkitTouchCallout: "default"
    })

    overlay.appendChild(bar)
    overlay.appendChild(body)
    document.body.appendChild(overlay)
  },

  _send(extra) {
    const input = this._activeInput()
    if (!input) return

    const init = {
      key: extra.key,
      code: extra.code || "",
      bubbles: true,
      cancelable: true,
      ctrlKey: extra.ctrlKey || this.mods.Control !== "off",
      altKey: extra.altKey || this.mods.Alt !== "off",
      shiftKey: false,
      metaKey: false
    }

    input.focus()
    input.dispatchEvent(new KeyboardEvent("keydown", init))
    // Some listeners also key off keypress/keyup; keydown is sufficient for
    // both our terminals, but fire keyup too for any future consumers.
    input.dispatchEvent(new KeyboardEvent("keyup", init))

    this._consumeOneShotModifiers()
    this._refocus()
  },

  _activeInput() {
    const active = document.activeElement
    if (active && active.matches && active.matches(INPUT_SELECTOR)) return active

    // Prefer the input inside the active tmux pane tile.
    const focusedPane = document.querySelector('[data-pane-active="true"]')
    if (focusedPane) {
      const inFocused = focusedPane.querySelector(INPUT_SELECTOR)
      if (inFocused) return inFocused
    }

    return document.querySelector(INPUT_SELECTOR)
  },

  _refocus() {
    const input = this._activeInput()
    if (input) input.focus()
  },

  // Keep visible inputs (palette, search, etc.) above the soft keyboard.
  // Terminal inputs are hidden/offscreen — layout inset handles those.
  _scrollFocusedInputIntoView(e) {
    const t = e.target
    if (!t || !t.matches) return
    if (t.matches(INPUT_SELECTOR)) return

    const tag = t.tagName
    if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") return
    if (t.type === "hidden") return

    requestAnimationFrame(() => {
      if (document.activeElement !== t) return
      t.scrollIntoView({ block: "center", inline: "nearest" })
    })
  },

  _renderModifierState() {
    const buttons = this.keyButtons || this.el.querySelectorAll("[data-keybar-key]")

    buttons.forEach((btn) => {
      const spec = btn.dataset.keybarKey
      if (spec !== "Control" && spec !== "Alt") return
      const state = this.mods[spec]
      btn.dataset.modState = state
      btn.setAttribute("aria-pressed", state === "off" ? "false" : "true")
    })
  }
}
