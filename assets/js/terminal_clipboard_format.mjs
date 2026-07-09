// Pure path-format helpers for clipboard image/file paste into the PTY.

export function pathQuote(path) {
  return `'${String(path).replace(/'/g, `'\\''`)}'`
}

export function basename(path) {
  return String(path).split("/").pop() || "file"
}

/**
 * Resolve how saved clipboard paths should be typed into the terminal.
 *
 * Server path_format is an upgrade-only hint: when the focused pane is an
 * agent (role/command), it forces `@path`. A server `"shell"` answer does
 * **not** override client detection — panes often report `node` for the Grok
 * wrapper, and we still want viewport-based agent detection as a fallback.
 */
export function pathModeFor(saved, opts = {}) {
  const fromServer = (saved || []).find((file) => {
    const format = file?.path_format
    return typeof format === "string" && format !== "" && format !== "auto"
  })?.path_format
  if (fromServer === "agent") return "agent"

  const configured =
    typeof opts.pathFormat === "function" ? opts.pathFormat(saved) : opts.pathFormat
  if (configured && configured !== "auto") return configured
  return opts.detectPathFormat?.(saved) || "shell"
}

export function formatPath(file, mode) {
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

export function formatPaths(saved, opts = {}) {
  const mode = pathModeFor(saved, opts)
  // Use the resolved mode for every file. Per-file path_format is only an
  // input to pathModeFor (agent upgrade), not a per-item override that would
  // force shell-quoted paths when mode resolves to agent.
  return saved.map((file) => formatPath(file, mode)).join(" ")
}
