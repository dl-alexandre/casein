// Picker preview column (#951). Renders the terminal:picker_preview reply
// client-side so an open rail is not LiveView-patched. The header names the
// capture source explicitly — live, cached, empty, or forbidden — because a
// preview that silently shows stale scrollback is indistinguishable from live.

export const PREVIEW_DEBOUNCE_MS = 200

const SOURCE_LABEL = {
  live: "live capture",
  cached: "cached capture",
  empty: "empty capture",
  forbidden: "unavailable",
}

export function previewTarget(el) {
  if (!el) return null
  const session = el.getAttribute("phx-value-tmux-session")
  const windowId = el.getAttribute("phx-value-window-id")
  const paneId = el.getAttribute("phx-value-pane-id")
  const payload = {}
  if (session) payload["tmux-session"] = session
  if (windowId) payload["window-id"] = windowId
  if (paneId) payload["pane-id"] = paneId
  return Object.keys(payload).length > 0 ? payload : null
}

export function previewCacheKey(payload) {
  return `${payload["tmux-session"] || ""}\x00${payload["window-id"] || ""}\x00${payload["pane-id"] || ""}`
}

export function findPreviewRoot(el) {
  return el?.closest?.("[data-terminal-picker-overlay]") || el
}

export function renderPickerPreview(root, reply, {cached = false} = {}) {
  const scope = findPreviewRoot(root)
  const pane = scope?.querySelector?.("[data-picker-preview]")
  const header = scope?.querySelector?.("[data-picker-preview-header]")
  if (!pane || !header) return

  if (!reply) {
    clearPreview(pane, header)
    return
  }

  const source = cached ? "cached" : reply.source || "live"
  header.hidden = false
  header.dataset.pickerPreviewSource = source
  if (reply.session) header.dataset.pickerPreviewSession = reply.session
  else delete header.dataset.pickerPreviewSession
  if (reply.window) header.dataset.pickerPreviewWindow = reply.window
  else delete header.dataset.pickerPreviewWindow
  if (reply.pane) header.dataset.pickerPreviewPane = reply.pane
  else delete header.dataset.pickerPreviewPane
  if (reply.cwd) header.dataset.pickerPreviewCwd = reply.cwd
  else delete header.dataset.pickerPreviewCwd
  if (reply.runtime) header.dataset.pickerPreviewRuntime = reply.runtime
  else delete header.dataset.pickerPreviewRuntime

  const chrome = reply.chrome || {}
  if (chrome.known) {
    header.dataset.pickerPreviewState = chrome.state || ""
  } else {
    delete header.dataset.pickerPreviewState
  }

  header.replaceChildren()
  const identity = [reply.session, reply.window, reply.pane, reply.cwd, reply.runtime]
    .filter((part) => typeof part === "string" && part !== "")
    .join(" · ")

  const identityLine = document.createElement("div")
  identityLine.dataset.pickerPreviewIdentity = ""
  identityLine.className =
    "whitespace-normal break-words font-mono text-density-label leading-snug text-base-content/80"
  identityLine.textContent = identity
  identityLine.title = identity
  header.appendChild(identityLine)

  const meta = document.createElement("div")
  meta.className = "mt-0.5 flex min-w-0 flex-wrap items-center gap-1.5"
  const sourceEl = document.createElement("span")
  sourceEl.dataset.pickerPreviewSourceLabel = source
  sourceEl.className = sourceClass(source)
  sourceEl.textContent = SOURCE_LABEL[source] || source
  meta.appendChild(sourceEl)

  if (typeof reply.quiet_for_seconds === "number" && reply.quiet_for_seconds > 0) {
    const quiet = document.createElement("span")
    quiet.dataset.pickerPreviewQuiet = String(reply.quiet_for_seconds)
    quiet.className = "font-mono text-density-label text-base-content/50"
    quiet.textContent = `quiet ${formatQuiet(reply.quiet_for_seconds)}`
    meta.appendChild(quiet)
  }

  if (chrome.known) {
    if (chrome.dot_class) {
      const dot = document.createElement("span")
      dot.dataset.pickerPreviewDot = chrome.state || ""
      dot.className = ["size-1.5 shrink-0 rounded-full", chrome.dot_class].join(" ")
      dot.title = chrome.label || ""
      meta.appendChild(dot)
    }
    if (chrome.chip_text) {
      const chip = document.createElement("span")
      chip.dataset.pickerPreviewChip = chrome.state || ""
      chip.className = [
        "shrink-0 rounded-full px-1.5 text-density-badge font-semibold",
        chrome.chip_class || "",
      ].join(" ")
      chip.textContent = chrome.chip_text
      chip.title = chrome.label || chrome.chip_text
      meta.appendChild(chip)
    }
  }

  header.appendChild(meta)

  const text = reply.text || ""
  pane.textContent = text
  pane.hidden = text === ""
  if (reply.scroll_to_prompt && text !== "") {
    scrollPreviewToPrompt(pane, reply.prompt_line)
  } else {
    pane.scrollTop = pane.scrollHeight
  }
}

export function clearPickerPreview(root) {
  const scope = findPreviewRoot(root)
  const pane = scope?.querySelector?.("[data-picker-preview]")
  const header = scope?.querySelector?.("[data-picker-preview-header]")
  if (!pane || !header) return
  clearPreview(pane, header)
}

export function bindPickerPreview(hook) {
  hook._previewCache = new Map()
  hook._onPreviewFocusin = () => schedulePickerPreview(hook)
  hook.el.addEventListener("focusin", hook._onPreviewFocusin)
}

export function unbindPickerPreview(hook) {
  clearTimeout(hook._previewTimer)
  hook.el.removeEventListener("focusin", hook._onPreviewFocusin)
}

export function resetPickerPreview(hook) {
  hook._previewCache?.clear()
  clearTimeout(hook._previewTimer)
  clearPickerPreview(hook.el)
}

export function schedulePickerPreview(hook) {
  clearTimeout(hook._previewTimer)
  const item = hook.currentItem?.()
  const payload = item && previewTarget(item)
  if (!payload) {
    clearPickerPreview(hook.el)
    return
  }

  const key = previewCacheKey(payload)
  if (hook._previewCache.has(key)) {
    renderPickerPreview(hook.el, hook._previewCache.get(key), {cached: true})
    return
  }

  clearPickerPreview(hook.el)
  hook._previewTimer = setTimeout(() => {
    hook.pushEvent("terminal:picker_preview", payload, (reply) => {
      hook._previewCache.set(key, reply)
      const current = hook.currentItem?.()
      if (current && previewCacheKey(previewTarget(current) || {}) === key) {
        renderPickerPreview(hook.el, reply, {cached: false})
      }
    })
  }, PREVIEW_DEBOUNCE_MS)
}

function clearPreview(pane, header) {
  pane.textContent = ""
  pane.hidden = true
  header.hidden = true
  header.replaceChildren()
  delete header.dataset.pickerPreviewSource
  delete header.dataset.pickerPreviewSession
  delete header.dataset.pickerPreviewWindow
  delete header.dataset.pickerPreviewPane
  delete header.dataset.pickerPreviewCwd
  delete header.dataset.pickerPreviewRuntime
  delete header.dataset.pickerPreviewState
}

function sourceClass(source) {
  if (source === "live") return "font-mono text-density-label text-status-ok-fg"
  if (source === "cached") return "font-mono text-density-label text-status-warning-fg"
  return "font-mono text-density-label text-base-content/50"
}

function formatQuiet(seconds) {
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  return `${Math.floor(minutes / 60)}h`
}

function scrollPreviewToPrompt(pane, promptLine) {
  if (typeof promptLine !== "number" || promptLine < 0) {
    pane.scrollTop = 0
    return
  }
  const lines = pane.textContent.split("\n")
  if (promptLine >= lines.length) {
    pane.scrollTop = 0
    return
  }
  const ratio = promptLine / Math.max(lines.length, 1)
  pane.scrollTop = Math.floor(pane.scrollHeight * ratio)
}
