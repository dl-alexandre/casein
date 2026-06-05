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

function isManualPasteKey(event) {
  if (event.key === "Insert" && event.shiftKey) return true
  if ((event.key || "").toLowerCase() !== "v") return false
  // Ctrl+V normally produces a browser paste event. Meta/Super+V is common on
  // Linux window-manager setups and often needs the Async Clipboard fallback.
  return event.metaKey && !event.ctrlKey && !event.altKey
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

function textFromClipboardData(data) {
  return data?.getData("text/plain") || data?.getData("text") || ""
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

async function uploadFiles(files, uploadFile, callbacks) {
  const saved = []

  for (const file of files) {
    if (file.size > MAX_FILE_BYTES) {
      throw new Error(`file is too large (${formatBytes(file.size)})`)
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
    if (callbacks.onFileSaved) callbacks.onFileSaved(reply)
    else callbacks.onNotice?.(`saved ${reply.relative_path || reply.path}`)
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
    const uploadFile = opts.uploadFile || opts.uploadImage
    if (!uploadFile) throw new Error("file paste is not available in this terminal")

    const saved = await uploadFiles(files, uploadFile, opts)
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
  const target = document.createElement("div")
  target.contentEditable = "true"
  target.setAttribute("aria-hidden", "true")
  Object.assign(target.style, {
    position: "fixed",
    left: "-10000px",
    top: "0",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    opacity: "0",
    pointerEvents: "none",
    whiteSpace: "pre-wrap"
  })
  document.body.appendChild(target)
  return target
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
    const text = textFromClipboardData(event.clipboardData) || fallback.innerText || ""
    if (files.length === 0 && text === "") return

    event.preventDefault()
    event.stopImmediatePropagation()
    fallback.textContent = ""

    submitPayload({ text, files })
  }

  const onKeydown = (event) => {
    if (event.defaultPrevented || !active() || !isPasteKey(event)) return

    fallback.textContent = ""
    fallback.focus({ preventScroll: true })

    if (!isManualPasteKey(event) || !navigator.clipboard?.read) return

    event.preventDefault()
    event.stopImmediatePropagation()

    readClipboardPayload()
      .then((payload) => pastePayload(payload, { ...opts, sendText }))
      .catch(reportError)
      .finally(restoreFocus)
  }

  const dragHasFiles = (event) => Array.from(event.dataTransfer?.types || []).includes("Files")

  const onDragOver = (event) => {
    if (!active() || !dragHasFiles(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
    onDragState?.(true)
  }

  const onDragLeave = (event) => {
    if (!element || element.contains(event.relatedTarget)) return
    onDragState?.(false)
  }

  const onDrop = (event) => {
    if (!active()) return
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
