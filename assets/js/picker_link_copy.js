import {copyTextSync, showClipboardToast} from "./terminal_copy"

export function pickerLinkToastDetail(url) {
  if (!url) return null

  try {
    const u = new URL(url, window.location.origin)
    const session = u.searchParams.get("session")
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

export function copyPickerLink(url, kind = "session") {
  if (!url) return false

  const detail = pickerLinkToastDetail(url)
  const base =
    kind === "window" ? "Window link copied" : kind === "view" ? "Link copied" : "Session link copied"
  const message = detail ? `${base} · ${detail}` : base
  const error =
    kind === "window"
      ? "Could not copy window link"
      : kind === "view"
        ? "Could not copy link"
        : "Could not copy session link"

  if (copyTextSync(url)) {
    showClipboardToast(message)
    return true
  }

  showClipboardToast(error, {kind: "error"})
  return false
}

export function installPickerLinkCopy() {
  if (installPickerLinkCopy._installed) return
  installPickerLinkCopy._installed = true

  document.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-copy-session-link]")
    if (!btn) return

    e.preventDefault()
    e.stopPropagation()

    const kind = btn.dataset.copyLinkKind || "session"
    copyPickerLink(btn.dataset.copySessionLink, kind)
  })
}