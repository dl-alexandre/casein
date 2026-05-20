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

      const def = KEY_DEFS[spec]
      if (!def) return
      this._send(def)
    }

    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
    this._renderModifierState()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
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
