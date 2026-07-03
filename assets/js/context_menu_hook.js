/**
 * Global right-click / long-press dispatcher for the shared context menu.
 *
 * Mounted once on a hidden anchor in the workspace LiveView. Any element
 * carrying `data-ctx-menu="<menu-id>"` becomes a trigger: right-click (or a
 * 500ms touch long-press, unless `data-ctx-longpress="off"`) pushes `ctx:open`
 * with the menu id, the trigger's remaining `data-ctx-*` attributes as the ctx
 * payload, and the pointer's viewport coordinates. The server builds the item
 * list (policy-gated) and renders `#ctx-menu`; this hook then clamps it to the
 * viewport, moves focus into it, and provides menu keyboard semantics
 * (arrows/Home/End roving focus, Escape closes and restores focus).
 * Dismissal on outside click is `phx-click-away` on the menu itself; scroll
 * and resize close it here because a fixed-position menu would detach from
 * its trigger.
 */

const LONG_PRESS_MS = 500
const LONG_PRESS_SLOP_PX = 10
// One physical gesture can surface as both contextmenu and our long-press
// timer (iOS); a second open inside this window is the same gesture.
const REOPEN_DEBOUNCE_MS = 300

export const ContextMenu = {
  mounted() {
    this.lastOpenAt = 0
    this.longPress = null
    this.restoreFocusTo = null

    this.onContextMenu = (e) => {
      this.cancelLongPress()
      const trigger = e.target.closest?.("[data-ctx-menu]")
      if (!trigger) return
      e.preventDefault()
      e.stopPropagation()
      this.open(trigger, e.clientX, e.clientY)
    }

    this.onPointerDown = (e) => {
      if (e.pointerType !== "touch") return
      const trigger = e.target.closest?.("[data-ctx-menu]")
      if (!trigger || trigger.dataset.ctxLongpress === "off") return
      this.cancelLongPress()
      const {clientX, clientY} = e
      this.longPress = {
        startX: clientX,
        startY: clientY,
        timer: setTimeout(() => {
          this.longPress = null
          this.suppressNextClick()
          this.open(trigger, clientX, clientY)
        }, LONG_PRESS_MS)
      }
    }

    this.onPointerMove = (e) => {
      if (!this.longPress) return
      if (
        Math.abs(e.clientX - this.longPress.startX) > LONG_PRESS_SLOP_PX ||
        Math.abs(e.clientY - this.longPress.startY) > LONG_PRESS_SLOP_PX
      ) {
        this.cancelLongPress()
      }
    }

    this.onPointerEnd = () => this.cancelLongPress()
    this.onMenuMounted = () => this.menuDidOpen()

    document.addEventListener("contextmenu", this.onContextMenu, true)
    document.addEventListener("pointerdown", this.onPointerDown, true)
    document.addEventListener("pointermove", this.onPointerMove, true)
    document.addEventListener("pointerup", this.onPointerEnd, true)
    document.addEventListener("pointercancel", this.onPointerEnd, true)
    document.addEventListener("devide:ctx-menu-mounted", this.onMenuMounted)
  },

  destroyed() {
    this.cancelLongPress()
    this.teardownMenuListeners()
    document.removeEventListener("contextmenu", this.onContextMenu, true)
    document.removeEventListener("pointerdown", this.onPointerDown, true)
    document.removeEventListener("pointermove", this.onPointerMove, true)
    document.removeEventListener("pointerup", this.onPointerEnd, true)
    document.removeEventListener("pointercancel", this.onPointerEnd, true)
    document.removeEventListener("devide:ctx-menu-mounted", this.onMenuMounted)
  },

  open(trigger, x, y) {
    const now = Date.now()
    if (now - this.lastOpenAt < REOPEN_DEBOUNCE_MS) return
    this.lastOpenAt = now
    this.restoreFocusTo = document.activeElement

    // Let the owning hook refresh its data-ctx-* attrs synchronously before
    // we harvest them — e.g. the terminal snapshots its selection here,
    // because opening/clicking the menu will destroy that selection.
    trigger.dispatchEvent(new CustomEvent("devide:ctx-before-open"))

    const ctx = {}
    for (const [key, value] of Object.entries(trigger.dataset)) {
      if (key === "ctxMenu" || key === "ctxLongpress" || !key.startsWith("ctx")) continue
      const name = key.slice(3)
      ctx[name.charAt(0).toLowerCase() + name.slice(1)] = value
    }

    // The reply lands after the patch, so the menu is in the DOM by the time
    // the callback runs — this (not phx-mounted, which only fires on the
    // menu's *first* insert) is what re-clamps and re-focuses when the menu
    // is already open and the user right-clicks a different trigger.
    this.pushEvent("ctx:open", {menu: trigger.dataset.ctxMenu, ctx, x, y}, () =>
      this.menuDidOpen()
    )
  },

  menuDidOpen() {
    const menu = document.getElementById("ctx-menu")
    if (!menu) return

    const margin = 8
    const rect = menu.getBoundingClientRect()
    let left = rect.left
    let top = rect.top
    if (rect.right > window.innerWidth - margin) {
      left = Math.max(margin, window.innerWidth - margin - rect.width)
    }
    if (rect.bottom > window.innerHeight - margin) {
      top = Math.max(margin, window.innerHeight - margin - rect.height)
    }
    menu.style.left = `${left}px`
    menu.style.top = `${top}px`

    this.teardownMenuListeners()

    this.onMenuKeyDown = (e) => {
      const items = Array.from(menu.querySelectorAll('[role="menuitem"]:not([disabled])'))
      const idx = items.indexOf(document.activeElement)

      switch (e.key) {
        case "Escape":
          e.preventDefault()
          e.stopPropagation()
          this.close(true)
          break
        case "ArrowDown":
          e.preventDefault()
          items[(idx + 1) % items.length]?.focus()
          break
        case "ArrowUp":
          e.preventDefault()
          items[(idx - 1 + items.length) % items.length]?.focus()
          break
        case "Home":
          e.preventDefault()
          items[0]?.focus()
          break
        case "End":
          e.preventDefault()
          items[items.length - 1]?.focus()
          break
      }
    }
    menu.addEventListener("keydown", this.onMenuKeyDown)
    this.menuEl = menu

    this.onWindowScroll = (e) => {
      const open = document.getElementById("ctx-menu")
      if (!open) return this.teardownMenuListeners()
      if (open.contains(e.target)) return
      this.close()
    }
    this.onWindowResize = () => this.close()
    window.addEventListener("scroll", this.onWindowScroll, true)
    window.addEventListener("resize", this.onWindowResize)

    menu.querySelector('[role="menuitem"]:not([disabled])')?.focus()
  },

  close(restoreFocus = false) {
    this.teardownMenuListeners()
    this.pushEvent("ctx:close", {})
    if (restoreFocus && typeof this.restoreFocusTo?.focus === "function") {
      this.restoreFocusTo.focus()
    }
    this.restoreFocusTo = null
  },

  cancelLongPress() {
    if (this.longPress) {
      clearTimeout(this.longPress.timer)
      this.longPress = null
    }
  },

  // A long-press ends with the finger lifting, which fires a click on the
  // trigger — without this, opening the menu on a file row would also open
  // the file.
  suppressNextClick() {
    const cancel = (e) => {
      e.preventDefault()
      e.stopPropagation()
    }
    document.addEventListener("click", cancel, {capture: true, once: true})
    setTimeout(() => document.removeEventListener("click", cancel, true), 700)
  },

  teardownMenuListeners() {
    if (this.menuEl && this.onMenuKeyDown) {
      this.menuEl.removeEventListener("keydown", this.onMenuKeyDown)
    }
    this.menuEl = null
    this.onMenuKeyDown = null
    if (this.onWindowScroll) {
      window.removeEventListener("scroll", this.onWindowScroll, true)
      this.onWindowScroll = null
    }
    if (this.onWindowResize) {
      window.removeEventListener("resize", this.onWindowResize)
      this.onWindowResize = null
    }
  }
}
