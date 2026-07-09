// Pure URL/target helpers for the session copy-link buttons, split out from
// picker_link_copy.js so they can be unit-tested under `node --test` (the .js
// files are CommonJS from node's view; .mjs is ESM).

export function pickerLinkToastDetail(url) {
  if (!url) return null

  const origin = typeof window !== "undefined" ? window.location.origin : "http://localhost"

  try {
    const u = new URL(url, origin)
    const session = u.searchParams.get("session") || u.searchParams.get("tmux_session")
    const window = u.searchParams.get("window")
    const pane = u.searchParams.get("pane")
    const zoom = u.searchParams.get("zoom")
    const parts = []

    if (session) {
      const suffix = session.match(/-([a-z0-9]{6,8}|t[a-z0-9]{6})$/)?.[1] || session.slice(-8)
      parts.push(suffix)
    }

    if (window) parts.push(`window ${window}`)
    if (pane) parts.push(`pane ${pane}`)
    if (zoom) parts.push("zoomed")

    return parts.length ? parts.join(" · ") : null
  } catch (_) {
    return null
  }
}

// Choose which link a copy button yields. A held Ctrl/Cmd upgrades to the
// agent-centric MCP endpoint URL (workspace_id + tmux_session, for handing a
// session to another agent) when the button carries one; otherwise it copies
// the human viewer share link as usual.
export function resolvePickerCopyTarget(dataset = {}, event = {}) {
  const agentUrl = dataset.copySessionLinkAgent
  if ((event.ctrlKey || event.metaKey) && agentUrl) {
    return {url: agentUrl, kind: "agent"}
  }

  return {url: dataset.copySessionLink, kind: dataset.copyLinkKind || "session"}
}
