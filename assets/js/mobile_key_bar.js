// MobileKeyBar hook
//
// Renders an accessory key row above the terminal on narrow viewports where
// the soft keyboard has no Ctrl / Alt / Esc / Tab / arrow keys. Tapping a key
// synthesizes a `keydown` KeyboardEvent on the *currently active* terminal
// input. Both terminal frontends already listen for `keydown` and read
// `event.key` + modifier flags:
//   - raw PTY pane:    vendor GhosttyTerminal (input[data-ghostty-input])
//   - governed shell:  GhosttyGovernedTerminal (textarea[aria-label])
// so no server-side change is needed — the bar just drives the same path a
// physical keyboard would.
//
// Ctrl/Alt are sticky one-shot modifiers: one tap arms (applies to the next
// key then auto-clears), double-tap locks until tapped off.

const INPUT_SELECTOR =
  '[data-ghostty-input="true"], textarea[aria-label="Governed terminal input"]'

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
    this._renderModifierState()
    this._setupViewportTracking()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onCaptureKeydown, true)
    const vv = window.visualViewport
    if (vv && this.onViewport) {
      vv.removeEventListener("resize", this.onViewport)
      vv.removeEventListener("scroll", this.onViewport)
    }
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
  // visual viewport bottom is the keyboard height. We translate the fixed bar
  // up by exactly that gap.
  _setupViewportTracking() {
    const vv = window.visualViewport
    if (!vv) return // desktop / unsupported — bar stays at its CSS position

    this.onViewport = () => {
      const gap = window.innerHeight - (vv.height + vv.offsetTop)
      // gap ≈ keyboard height (0 when closed). Clamp negatives from rounding.
      this.el.style.transform = `translateY(-${Math.max(0, gap)}px)`
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

  // Read the system clipboard and inject it into the active terminal as
  // keystrokes. Soft keyboards can't reliably summon iOS's Paste menu on the
  // terminal's hidden 1px input, so we drive the same keydown path the bar's
  // other keys use — works for both the raw PTY (vendor pushes each "key" to
  // the PTY) and the governed line-editor. Newlines/tabs map to Enter/Tab.
  async _paste() {
    if (!navigator.clipboard || !navigator.clipboard.readText) return

    let text = ""
    try {
      text = await navigator.clipboard.readText()
    } catch (_) {
      return // permission denied or no gesture — nothing to do
    }
    if (!text) return

    const input = this._activeInput()
    if (!input) return
    input.focus()

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

    // Prefer the input inside the focused pane (raw multi-pane).
    const focusedPane = document.querySelector(".ring-primary")
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

  _renderModifierState() {
    this.el.querySelectorAll("[data-keybar-key]").forEach((btn) => {
      const spec = btn.dataset.keybarKey
      if (spec !== "Control" && spec !== "Alt") return
      const state = this.mods[spec]
      btn.dataset.modState = state
      btn.setAttribute("aria-pressed", state === "off" ? "false" : "true")
    })
  }
}
