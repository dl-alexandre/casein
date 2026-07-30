// The one transient-message surface.
//
// Everything ephemeral now lands here: clipboard results, editor errors, the
// keyboard-shortcut coach, and — via flash_bridge.js — the server's `put_flash`
// messages, which used to render as a separate never-auto-dismissing DaisyUI
// toast in the opposite corner.
//
// Scheduling lives in toast_queue.mjs (pure, unit-tested). This file owns only
// the DOM and the single timer that drives expiry.

import {
  LANE_HINT,
  LANE_MESSAGE,
  createQueue,
  dismiss,
  enqueue,
  nextDeadline,
  pendingCount,
  tick,
  visible
} from "./toast_queue.mjs"

const ROOT_ID = "casein-toast-stack"

let state = createQueue()
let timer = null
let root = null
const slots = {}

const clock = () => Date.now()

function buildSlot(lane, {live}) {
  const el = document.createElement("div")
  el.className = "casein-toast"
  el.dataset.lane = lane
  el.hidden = true

  if (live) {
    // Only real messages get announced. The hint fires on a click the operator
    // just made on purpose, so announcing it would be pure screen-reader spam —
    // it stays in the accessibility tree, just not as a live region.
    el.setAttribute("role", "status")
    el.setAttribute("aria-live", "polite")
  }

  const text = document.createElement("span")
  text.className = "casein-toast__text"
  el.appendChild(text)

  const meta = document.createElement("span")
  meta.className = "casein-toast__meta"
  meta.setAttribute("aria-hidden", "true")
  el.appendChild(meta)

  const actions = document.createElement("span")
  actions.className = "casein-toast__actions"
  el.appendChild(actions)

  el.addEventListener("click", () => {
    state = dismiss(state, lane, clock())
    render()
    schedule()
  })

  return el
}

function ensureRoot() {
  if (root && root.isConnected) return root

  root = document.createElement("div")
  root.id = ROOT_ID
  root.className = "casein-toast-stack"

  // Hint sits above the message so the message keeps the bottom-center spot the
  // old toast trained everyone to look at.
  slots[LANE_HINT] = buildSlot(LANE_HINT, {live: false})
  slots[LANE_MESSAGE] = buildSlot(LANE_MESSAGE, {live: true})
  root.appendChild(slots[LANE_HINT])
  root.appendChild(slots[LANE_MESSAGE])

  document.body.appendChild(root)
  return root
}

function renderSlot(lane, item, {backlog = 0} = {}) {
  const el = slots[lane]
  if (!el) return

  if (!item) {
    el.hidden = true
    el.classList.remove("casein-toast--visible")
    el.removeAttribute("data-kind")
    delete el.dataset.actionable
    return
  }

  el.hidden = false
  el.dataset.kind = item.kind
  el.querySelector(".casein-toast__text").textContent = item.text

  // "×3" for a grouped repeat, "+2" for a waiting backlog — both tell the
  // operator the surface is not dropping their actions on the floor.
  const parts = []
  if (item.count > 1) parts.push(`×${item.count}`)
  if (backlog > 0) parts.push(`+${backlog}`)
  el.querySelector(".casein-toast__meta").textContent = parts.join(" ")

  const actionsEl = el.querySelector(".casein-toast__actions")
  actionsEl.replaceChildren()
  const actions = (item.actions || []).filter(
    (action) => action && action.label && typeof action.onClick === "function"
  )

  for (const action of actions) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "casein-toast__action"
    button.textContent = action.label
    button.addEventListener("click", (event) => {
      // The click itself is the user activation that WebKit's clipboard and
      // share APIs require, so invoke the action synchronously.
      event.preventDefault()
      event.stopPropagation()
      action.onClick(event)
    })
    actionsEl.appendChild(button)
  }

  if (actions.length > 0) el.dataset.actionable = "true"
  else delete el.dataset.actionable

  // Next frame so the transition runs on first paint of a newly shown node. Re-
  // check `hidden`: the item can retire between this render and the callback.
  window.requestAnimationFrame(() => {
    if (!el.hidden) el.classList.add("casein-toast--visible")
  })
}

function render() {
  ensureRoot()
  const shown = visible(state)
  renderSlot(LANE_MESSAGE, shown[LANE_MESSAGE], {backlog: pendingCount(state)})
  renderSlot(LANE_HINT, shown[LANE_HINT])
}

function schedule() {
  if (timer) {
    window.clearTimeout(timer)
    timer = null
  }

  const deadline = nextDeadline(state)
  if (deadline === null) return

  // One timer for the whole surface, re-armed from the queue's next deadline.
  timer = window.setTimeout(() => {
    timer = null
    state = tick(state, clock())
    render()
    schedule()
  }, Math.max(0, deadline - clock()))
}

/**
 * Show a transient message.
 *
 * `kind` is one of "info" | "error" | "pending" | "shortcut"; "shortcut" routes
 * to the separate hint lane so coaching never delays a real message.
 */
export function showToast(message, {kind = "info", duration, actions} = {}) {
  if (!message) return

  state = enqueue(state, {text: message, kind, duration, actions}, clock())
  render()
  schedule()
}

/** Dismiss a visible toast only when it is the caller's own message. */
export function hideToast(message, {lane = LANE_MESSAGE} = {}) {
  const item = visible(state)[lane]
  if (!item || (message && item.text !== message)) return

  state = dismiss(state, lane, clock())
  render()
  schedule()
}

/** Test/debug seam: current visible items without reaching into the DOM. */
export function __toastState() {
  return state
}
