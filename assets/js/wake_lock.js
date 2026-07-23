// Screen wake lock while an agent is actively working, so the phone doesn't
// sleep mid-task and drop you.
//
// Driven by terminal OUTPUT activity: pingWakeLock() is called on each painted
// frame. While frames keep arriving (an agent producing output) the lock is
// held; after HOLD_MS of quiet — or as soon as the tab is hidden — it releases,
// so a static screen you're reading still sleeps normally and the battery isn't
// drained. Mobile/standalone only; a no-op where the API is missing (older iOS).
//
// The OS releases a wake lock automatically when the page is hidden, so we
// re-acquire on return to the foreground if we're still within an active window.

const HOLD_MS = 45_000

let sentinel = null
let releaseTimer = null
let lastPingAt = 0
let listenerBound = false

function supported() {
  return typeof navigator !== "undefined" && "wakeLock" in navigator
}

function preferredSurface() {
  try {
    return (
      window.matchMedia("(pointer: coarse)").matches ||
      window.matchMedia("(display-mode: standalone)").matches
    )
  } catch (_) {
    return false
  }
}

async function acquire() {
  if (sentinel || document.visibilityState !== "visible") return
  try {
    sentinel = await navigator.wakeLock.request("screen")
    // The API auto-releases on hide; clear our handle so the next ping re-acquires.
    sentinel.addEventListener?.("release", () => {
      sentinel = null
    })
  } catch (_) {
    // Denied / not allowed in this state — try again on the next ping.
    sentinel = null
  }
}

function release() {
  if (!sentinel) return
  const s = sentinel
  sentinel = null
  try {
    s.release?.()
  } catch (_) {
    /* already released */
  }
}

function bindOnce() {
  if (listenerBound || typeof document === "undefined") return
  listenerBound = true
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && Date.now() - lastPingAt < HOLD_MS) {
      acquire()
    } else if (document.visibilityState !== "visible") {
      release()
    }
  })
}

// Signal that the agent is producing output right now. Cheap to call per frame.
export function pingWakeLock() {
  if (!supported() || !preferredSurface()) return
  bindOnce()
  lastPingAt = Date.now()
  acquire()
  clearTimeout(releaseTimer)
  releaseTimer = setTimeout(release, HOLD_MS)
}
