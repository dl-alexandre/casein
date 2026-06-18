// Reports terminal-focused user input to LiveView so topology-driven URL
// patches (e.g. external tmux zoom) wait until the operator is idle.
const ACTIVITY_DEBOUNCE_MS = 250

function isTerminalInteraction(target) {
  if (!target?.closest) return false

  return Boolean(
    target.closest(
      [
        "[data-terminal-surface]",
        '[phx-hook="GhosttyTerminal"]',
        '[phx-hook="GhosttyGovernedTerminal"]',
        '[phx-hook="TmuxPaneResize"]',
        "#workspace-leader-root",
        "#mobile-key-bar-scroll",
      ].join(", ")
    )
  )
}

export const TerminalActivity = {
  mounted() {
    this._lastPush = 0

    this._onActivity = (event) => {
      if (!isTerminalInteraction(event.target)) return

      const now = Date.now()
      if (now - this._lastPush < ACTIVITY_DEBOUNCE_MS) return

      this._lastPush = now
      this.pushEvent("terminal:user_interaction", {})
    }

    window.addEventListener("keydown", this._onActivity, true)
    window.addEventListener("pointerdown", this._onActivity, true)
    window.addEventListener("wheel", this._onActivity, {capture: true, passive: true})
  },

  destroyed() {
    window.removeEventListener("keydown", this._onActivity, true)
    window.removeEventListener("pointerdown", this._onActivity, true)
    window.removeEventListener("wheel", this._onActivity, true)
  },
}