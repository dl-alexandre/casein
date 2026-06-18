const MAX_FILE_BYTES = 25 * 1024 * 1024
const LARGE_TEXT_BYTES = 16 * 1024
const LARGE_FILE_BYTES = 5 * 1024 * 1024

function isPasteKey(event) {
  const key = (event.key || "").toLowerCase()
  return (
    (key === "v" && (event.metaKey || event.ctrlKey) && !event.altKey) ||
    (event.key === "Insert" && event.shiftKey)
  )
}

function canReadClipboard() {
  return !!(navigator.clipboard?.readText || navigator.clipboard?.read)
}

function isManualPasteKey(event) {
  // All standard paste shortcuts: hidden terminal inputs (Ghostty textarea)
  // often receive empty clipboardData on paste in Edge/Chrome.
  // Handle them on keydown via the Async Clipboard API while the gesture is live.
  return isPasteKey(event) && canReadClipboard()
}

function clipboardFiles(data) {
  const files = []

  if (data?.items) {
    for (const item of Array.from(data.items)) {
      if (item.kind === "file" && item.type?.startsWith("image/")) {
        const file = item.getAsFile()
        if (file) files.push(file)
      }
    }
  }

  if (data?.files) {
    for (const file of Array.from(data.files)) {
      if (file.type?.startsWith("image/") && !files.includes(file)) files.push(file)
    }
  }

  return files
}

function dropFiles(data) {
  return data?.files ? Array.from(data.files).filter((file) => file.size > 0) : []
}

function isImageFile(file) {
  return file.type?.startsWith("image/")
}

function uploadCallbackFor(file, opts) {
  if (isImageFile(file) && opts.uploadImage) return opts.uploadImage
  if (opts.uploadFile) return opts.uploadFile
  return null
}

function textFromClipboardData(data) {
  if (!data) return ""

  const plain = data.getData("text/plain")
  if (plain) return plain

  const text = data.getData("text")
  if (text) return text

  // Edge sometimes exposes only text/html for rich clipboard content.
  const html = data.getData("text/html")
  if (html) {
    const scratch = document.createElement("div")
    scratch.innerHTML = html
    return scratch.textContent || ""
  }

  return ""
}

function pathQuote(path) {
  return `'${String(path).replace(/'/g, `'\\''`)}'`
}

function basename(path) {
  return String(path).split("/").pop() || "file"
}

function base64FromArrayBuffer(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""

  for (let i = 0; i < bytes.length; i += 0x8000) {
    const chunk = bytes.subarray(i, i + 0x8000)
    binary += String.fromCharCode(...chunk)
  }

  return window.btoa(binary)
}

async function fileToBase64(file) {
  return base64FromArrayBuffer(await file.arrayBuffer())
}

function textBytes(text) {
  return new Blob([text || ""]).size
}

function totalFileBytes(files) {
  return files.reduce((sum, file) => sum + (file.size || 0), 0)
}

function formatBytes(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  if (bytes >= 1024) return `${Math.ceil(bytes / 1024)} KB`
  return `${bytes} B`
}

function payloadSummary({ text, files }) {
  const parts = []
  const bytes = textBytes(text)
  if (bytes > 0) parts.push(`${formatBytes(bytes)} text`)
  if (files.length > 0) parts.push(`${files.length} file${files.length === 1 ? "" : "s"} (${formatBytes(totalFileBytes(files))})`)
  return parts.join(" and ") || "empty paste"
}

function needsConfirmation({ text, files }) {
  return (
    textBytes(text) >= LARGE_TEXT_BYTES ||
    files.length > 1 ||
    totalFileBytes(files) >= LARGE_FILE_BYTES
  )
}

async function confirmPayload(payload, opts) {
  if (!needsConfirmation(payload)) return true
  if (opts.confirmPaste) return opts.confirmPaste(payloadSummary(payload), payload)
  return window.confirm(`Paste ${payloadSummary(payload)} into this terminal?`)
}

function bracketed(text, enabled) {
  if (!enabled) return text
  if (!text.includes("\n") && text.length < 256) return text
  return `\x1b[200~${text}\x1b[201~`
}

async function uploadFiles(files, opts) {
  const saved = []

  for (const file of files) {
    if (file.size > MAX_FILE_BYTES) {
      throw new Error(`file is too large (${formatBytes(file.size)})`)
    }

    const uploadFile = uploadCallbackFor(file, opts)
    if (!uploadFile) {
      const kind = isImageFile(file) ? "image" : "file"
      throw new Error(`${kind} paste is not available in this terminal`)
    }

    const reply = await uploadFile({
      name: file.name || "clipboard-file",
      type: file.type || "application/octet-stream",
      size: file.size,
      data: await fileToBase64(file)
    })

    if (!reply || reply.ok === false || !reply.path) {
      throw new Error(reply?.reason || "failed to save clipboard file")
    }

    saved.push(reply)
    if (opts.onFileSaved) opts.onFileSaved(reply)
    else opts.onNotice?.(`saved ${reply.relative_path || reply.path}`)
  }

  return saved
}

function pathModeFor(saved, opts) {
  const configured = typeof opts.pathFormat === "function" ? opts.pathFormat(saved) : opts.pathFormat
  if (configured && configured !== "auto") return configured
  return opts.detectPathFormat?.(saved) || "shell"
}

function formatPath(file, mode) {
  const path = file.path

  if (mode === "agent") return `@${path}`

  if (mode === "markdown") {
    const label = basename(file.relative_path || path)
    if (file.content_type?.startsWith("image/")) return `![${label}](${path})`
    return `[${label}](${path})`
  }

  if (mode === "plain") return path

  return pathQuote(path)
}

function formatPaths(saved, opts) {
  const mode = pathModeFor(saved, opts)
  return saved.map((file) => formatPath(file, mode)).join(" ")
}

async function pastePayload({ text = "", files = [] }, opts) {
  if (files.length === 0 && text === "") return false
  if (!(await confirmPayload({ text, files }, opts))) return false

  if (files.length > 0) {
    const saved = await uploadFiles(files, opts)
    if (saved.length > 0) {
      opts.sendText(formatPaths(saved, opts))
      return true
    }
  }

  if (text) {
    opts.sendText(bracketed(text, opts.bracketedPaste === true))
    return true
  }

  return false
}

async function readClipboardPayload() {
  const files = []
  let text = ""

  if (navigator.clipboard?.read) {
    const items = await navigator.clipboard.read()

    for (const item of items) {
      for (const type of item.types || []) {
        if (type.startsWith("image/")) {
          const blob = await item.getType(type)
          files.push(new File([blob], `clipboard-image.${type.split("/")[1] || "png"}`, { type }))
        } else if (type === "text/plain") {
          const blob = await item.getType(type)
          text += await blob.text()
        }
      }
    }
  } else if (navigator.clipboard?.readText) {
    text = await navigator.clipboard.readText()
  }

  return { text, files }
}

function createFallbackPasteTarget() {
  const target = document.createElement("textarea")
  target.setAttribute("aria-hidden", "true")
  target.setAttribute("tabindex", "-1")
  target.setAttribute("autocomplete", "off")
  target.setAttribute("autocorrect", "off")
  target.setAttribute("autocapitalize", "off")
  target.setAttribute("spellcheck", "false")
  Object.assign(target.style, {
    position: "fixed",
    left: "-10000px",
    top: "0",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    opacity: "0",
    whiteSpace: "pre-wrap"
  })
  document.body.appendChild(target)
  return target
}

function fallbackText(target) {
  return target.value || target.innerText || ""
}

function clearFallback(target) {
  if ("value" in target) target.value = ""
  else target.textContent = ""
}

async function legacyExecPaste(fallback) {
  clearFallback(fallback)
  fallback.focus({ preventScroll: true })

  try {
    if (!document.execCommand("paste")) return ""
  } catch {
    return ""
  }

  const text = fallbackText(fallback)
  clearFallback(fallback)
  return text
}

export function installTerminalClipboardPaste(opts) {
  const {
    element,
    input,
    isActive,
    sendText,
    onDragState,
    onError
  } = opts

  const active = () => (isActive ? isActive() : true)
  const fallback = createFallbackPasteTarget()

  const restoreFocus = () => {
    window.setTimeout(() => {
      if (input && document.activeElement === fallback) input.focus({ preventScroll: true })
    }, 0)
  }

  const reportError = (error) => {
    const message = error?.message || String(error || "clipboard paste failed")
    onError?.(message)
  }

  const submitPayload = (payload) => {
    pastePayload(payload, { ...opts, sendText }).catch(reportError).finally(restoreFocus)
  }

  const onPaste = (event) => {
    if (event.defaultPrevented || !active()) return

    const files = clipboardFiles(event.clipboardData)
    const text = textFromClipboardData(event.clipboardData) || fallbackText(fallback)
    if (files.length === 0 && text === "") return

    event.preventDefault()
    event.stopImmediatePropagation()
    clearFallback(fallback)

    submitPayload({ text, files })
  }

  const onKeydown = (event) => {
    if (event.defaultPrevented || !active() || !isPasteKey(event)) return

    if (!isManualPasteKey(event)) {
      clearFallback(fallback)
      fallback.focus({ preventScroll: true })
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()

    readClipboardPayload()
      .then((payload) => {
        if (payload.text || payload.files.length > 0) {
          return pastePayload(payload, { ...opts, sendText })
        }

        return legacyExecPaste(fallback).then((text) => {
          if (!text) throw new Error("clipboard is empty or paste was blocked")
          return pastePayload({ text, files: [] }, { ...opts, sendText })
        })
      })
      .catch(reportError)
      .finally(restoreFocus)
  }

  const dragHasFiles = (event) => Array.from(event.dataTransfer?.types || []).includes("Files")

  const onDragOver = (event) => {
    if (!dragHasFiles(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    onDragState?.(true)
  }

  const onDragLeave = (event) => {
    if (!element || element.contains(event.relatedTarget)) return
    onDragState?.(false)
  }

  const onDrop = (event) => {
    const files = dropFiles(event.dataTransfer)
    if (files.length === 0) return

    event.preventDefault()
    event.stopImmediatePropagation()
    onDragState?.(false)
    submitPayload({ text: "", files })
  }

  document.addEventListener("paste", onPaste, true)
  document.addEventListener("keydown", onKeydown, true)
  fallback.addEventListener("paste", onPaste, true)
  element?.addEventListener("paste", onPaste, true)
  input?.addEventListener("paste", onPaste, true)
  element?.addEventListener("dragenter", onDragOver)
  element?.addEventListener("dragover", onDragOver)
  element?.addEventListener("dragleave", onDragLeave)
  element?.addEventListener("drop", onDrop)

  return () => {
    document.removeEventListener("paste", onPaste, true)
    document.removeEventListener("keydown", onKeydown, true)
    fallback.removeEventListener("paste", onPaste, true)
    fallback.remove()
    element?.removeEventListener("paste", onPaste, true)
    input?.removeEventListener("paste", onPaste, true)
    element?.removeEventListener("dragenter", onDragOver)
    element?.removeEventListener("dragover", onDragOver)
    element?.removeEventListener("dragleave", onDragLeave)
    element?.removeEventListener("drop", onDrop)
  }
}

export async function pasteFromNavigatorClipboard(opts) {
  const payload = await readClipboardPayload()
  return pastePayload(payload, opts)
}
