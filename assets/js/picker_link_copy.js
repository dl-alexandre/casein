import {copyTextSync, showClipboardToast} from "./terminal_copy"
import {pickerLinkToastDetail, resolvePickerCopyTarget} from "./picker_link_copy_url.mjs"

export {pickerLinkToastDetail, resolvePickerCopyTarget}

export function copyPickerLink(url, kind = "session") {
  if (!url) return false

  const detail = pickerLinkToastDetail(url)
  const base =
    kind === "agent"
      ? "Agent MCP link copied"
      : kind === "window"
        ? "Window link copied"
        : kind === "view"
          ? "Link copied"
          : "Session link copied"
  const message = detail ? `${base} · ${detail}` : base
  const error =
    kind === "agent"
      ? "Could not copy agent MCP link"
      : kind === "window"
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

    const {url, kind} = resolvePickerCopyTarget(btn.dataset, e)
    copyPickerLink(url, kind)
  })
}
