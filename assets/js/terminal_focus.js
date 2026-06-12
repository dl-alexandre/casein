const FOCUS_RETRY_DELAYS = [0, 25, 75, 150, 300, 600, 1000]

function visible(el) {
  if (!el || !el.isConnected) return false

  const style = window.getComputedStyle(el)
  return style.display !== "none" && style.visibility !== "hidden" && el.getClientRects().length > 0
}

function terminalInput(root) {
  return root?.querySelector(
    "textarea[data-ghostty-input='true'], textarea[aria-label='Governed terminal input'], textarea"
  )
}

function terminalRootWithin(root) {
  if (!root) return null

  if (root.matches?.('[phx-hook="GhosttyTerminal"], [phx-hook="GhosttyGovernedTerminal"]')) {
    return root
  }

  return root.querySelector?.('[phx-hook="GhosttyTerminal"], [phx-hook="GhosttyGovernedTerminal"]')
}

function pushRoot(roots, root) {
  if (root && visible(root) && !roots.includes(root)) roots.push(root)
}

function rootsForDataPaneId(paneId) {
  if (!paneId) return []

  return Array.from(document.querySelectorAll("[data-pane-id]")).flatMap((el) => {
    if (el.dataset.paneId !== paneId) return []
    const root = terminalRootWithin(el)
    return root ? [root] : []
  })
}

function candidateTerminalRoots(payload) {
  const roots = []

  rootsForDataPaneId(payload?.pane_id).forEach((root) => pushRoot(roots, root))
  rootsForDataPaneId(payload?.tmux_pane_id).forEach((root) => pushRoot(roots, root))

  document
    .querySelectorAll('[phx-hook="GhosttyTerminal"][data-autofocus="true"]')
    .forEach((root) => pushRoot(roots, root))

  document
    .querySelectorAll(
      '[data-pane-active="true"] [phx-hook="GhosttyGovernedTerminal"], [data-pane-active="true"] [phx-hook="GhosttyTerminal"]'
    )
    .forEach((root) => pushRoot(roots, root))

  document
    .querySelectorAll('[phx-hook="GhosttyGovernedTerminal"], [phx-hook="GhosttyTerminal"]')
    .forEach((root) => pushRoot(roots, root))

  return roots
}

function focusRoot(root) {
  const input = terminalInput(root)
  if (!input || input.disabled) return false

  input.focus({ preventScroll: true })
  return document.activeElement === input
}

function focusActiveTerminal(payload = {}) {
  return candidateTerminalRoots(payload).some(focusRoot)
}

window.addEventListener("phx:terminal:focus_active", (event) => {
  const payload = event.detail?.payload || event.detail || {}
  let attempt = 0

  const tryFocus = () => {
    if (focusActiveTerminal(payload)) return

    const delay = FOCUS_RETRY_DELAYS[attempt]
    attempt += 1

    if (delay !== undefined) window.setTimeout(tryFocus, delay)
  }

  window.requestAnimationFrame?.(tryFocus) || window.setTimeout(tryFocus, 0)
})
