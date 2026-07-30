// Which server flash messages to hoist into the toast stack, and what to
// remember afterwards.
//
// Split out of flash_bridge.js because the hook itself cannot be imported by
// `node --test` (see assets/js hook constraints) — the DOM read stays in the
// hook, this owns the decision.
//
// The two rules that matter:
//
//   1. A re-render between "hoisted" and "flash cleared server-side" must not
//      toast the same message twice.
//   2. When a flash key disappears, forget it — otherwise the identical error
//      could never toast again for the life of the LiveView.

// Ids come from `assign_new(:id, "flash-#{kind}")` in CoreComponents.flash/1.
// Deliberately excludes #client-error / #server-error: those are connection
// state that must stay pinned while the socket is down, not toast-shaped events.
export const HOISTED_FLASHES = [
  {selector: "#flash-info", key: "info", kind: "info"},
  {selector: "#flash-error", key: "error", kind: "error"}
]

/**
 * @param present array of {key, kind, message} for flash nodes currently rendered
 * @param lastHoisted map of key -> message already hoisted
 * @returns {hoist, lastHoisted} — messages to show, and the next memo
 */
export function planHoist(present = [], lastHoisted = {}) {
  const byKey = new Map(present.map((entry) => [entry.key, entry]))
  const nextMemo = {...lastHoisted}
  const hoist = []

  for (const {key, kind} of HOISTED_FLASHES) {
    const entry = byKey.get(key)

    if (!entry) {
      nextMemo[key] = null
      continue
    }

    const message = `${entry.message || ""}`.trim()
    if (!message) continue

    if (nextMemo[key] === message) continue

    nextMemo[key] = message
    hoist.push({key, kind: entry.kind || kind, message})
  }

  return {hoist, lastHoisted: nextMemo}
}
