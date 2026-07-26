// First-run gesture coach-marks (mobile only).
//
// The mobile terminal has several invisible gestures. Once per device, show a
// small dismissible card that names them, so they're discoverable instead of
// secret. Purely client-side: a localStorage flag gates it, no server round
// trip. Bump COACH_VERSION to re-show after the gesture set changes.

const COACH_VERSION = "1"
const SEEN_KEY = `casein:gestures-seen:v${COACH_VERSION}`

const GESTURES = [
  {glyph: "↕", name: "One finger", desc: "scroll the buffer"},
  {glyph: "✌", name: "Two fingers", desc: "scroll the scrollback"},
  {glyph: "⇄", name: "Swipe left / right", desc: "switch window"},
  {glyph: "⊕", name: "Double-tap", desc: "reset zoom to fit"},
]

function isMobile() {
  try {
    return (
      window.matchMedia("(pointer: coarse)").matches ||
      window.matchMedia("(max-width: 639px)").matches
    )
  } catch (_) {
    return false
  }
}

function alreadySeen() {
  try {
    return localStorage.getItem(SEEN_KEY) === "1"
  } catch (_) {
    return false
  }
}

function markSeen() {
  try {
    localStorage.setItem(SEEN_KEY, "1")
  } catch (_) {
    /* localStorage unavailable — it'll show again next load, no harm */
  }
}

export const GestureCoach = {
  mounted() {
    // Only on a phone-shaped touch device, and only the first time. `?coach=1`
    // forces it back for testing.
    const forced = /(?:\?|&)coach=1(?:&|$)/.test(location.search || "")
    if (!forced && (!isMobile() || alreadySeen())) return

    this._build()
  },

  destroyed() {
    this._teardown()
  },

  _build() {
    const overlay = document.createElement("div")
    overlay.className = "gesture-coach"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-label", "Terminal gestures")

    const card = document.createElement("div")
    card.className = "gesture-coach__card"

    const title = document.createElement("div")
    title.className = "gesture-coach__title"
    title.textContent = "Terminal gestures"
    card.appendChild(title)

    const list = document.createElement("ul")
    list.className = "gesture-coach__list"
    for (const g of GESTURES) {
      const li = document.createElement("li")
      li.className = "gesture-coach__item"
      const glyph = document.createElement("span")
      glyph.className = "gesture-coach__glyph"
      glyph.setAttribute("aria-hidden", "true")
      glyph.textContent = g.glyph
      const text = document.createElement("span")
      text.className = "gesture-coach__text"
      const name = document.createElement("b")
      name.textContent = g.name
      text.appendChild(name)
      text.appendChild(document.createTextNode(` — ${g.desc}`))
      li.appendChild(glyph)
      li.appendChild(text)
      list.appendChild(li)
    }
    card.appendChild(list)

    const button = document.createElement("button")
    button.type = "button"
    button.className = "gesture-coach__dismiss"
    button.textContent = "Got it"
    card.appendChild(button)

    overlay.appendChild(card)
    document.body.appendChild(overlay)
    this._overlay = overlay

    this._dismiss = () => this._close()
    button.addEventListener("click", this._dismiss)
    // Tapping the dim backdrop (outside the card) also dismisses.
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) this._close()
    })

    // Enter animation on the next frame.
    requestAnimationFrame(() => overlay.setAttribute("data-open", "true"))
  },

  _close() {
    markSeen()
    const overlay = this._overlay
    if (!overlay) return
    overlay.removeAttribute("data-open")
    // Remove after the fade so it doesn't linger invisibly capturing taps.
    setTimeout(() => this._teardown(), 220)
  },

  _teardown() {
    if (this._overlay && this._overlay.parentNode) {
      this._overlay.parentNode.removeChild(this._overlay)
    }
    this._overlay = null
  },
}
