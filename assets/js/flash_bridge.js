// Hoist server `put_flash` messages into the shared toast stack.
//
// Flash used to render as its own DaisyUI toast in the top-right corner with no
// auto-dismiss, while every client-side message used a hand-rolled bottom-center
// node. Two systems, two corners, two lifetimes, both able to be on screen at
// once. This hook makes the server flash a producer for the one surface: read
// the rendered message, show it through toast.js, hide the original node, and
// clear the flash server-side so it does not linger or replay on navigation.
//
// Deliberately *not* hoisted: the `#client-error` / `#server-error` reconnect
// banners. Those are connection *state*, not events — they must stay pinned for
// as long as the socket is down, which is the opposite of a toast's contract.
//
// The original node is hidden here rather than by CSS so that dead renders and
// the non-live `Layouts.app` (where no hook ever runs) still show flash the old
// way. Decision logic lives in flash_bridge_plan.mjs so it can be unit-tested.

import {HOISTED_FLASHES, planHoist} from "./flash_bridge_plan.mjs"
import {showToast} from "./toast"

function readFlash(root) {
  return HOISTED_FLASHES.flatMap(({selector, key, kind}) => {
    const el = root.querySelector(selector)
    if (!el) return []

    const node = el.querySelector("[data-flash-message]")
    const message = ((node ? node.textContent : el.textContent) || "").trim()

    return [{key, kind, message, el}]
  })
}

export const FlashBridge = {
  mounted() {
    this._lastHoisted = {}
    this._drain()
  },

  updated() {
    this._drain()
  },

  _drain() {
    const present = readFlash(this.el)
    const {hoist, lastHoisted} = planHoist(present, this._lastHoisted)
    this._lastHoisted = lastHoisted

    // Hide every rendered flash we own, hoisted this pass or already handled —
    // the toast is now the only place it should appear.
    for (const {el} of present) el.style.display = "none"

    for (const {key, kind, message} of hoist) {
      showToast(message, {kind})

      // Built-in LiveView event: drops the key from the server's flash map so it
      // does not survive the next patch or navigation.
      this.pushEvent("lv:clear-flash", {key})
    }
  }
}
