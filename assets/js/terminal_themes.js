/**
 * Terminal themes follow OS prefers-color-scheme (always system).
 * Sets CSS chrome variables and supplies ANSI palette LUT for raw Ghostty.
 */

function hexToRgb(hex) {
  const h = hex.replace("#", "")
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16)
  ]
}

function rgbKey(rgb) {
  if (!rgb) return null
  return `${rgb[0]},${rgb[1]},${rgb[2]}`
}

/** Canonical xterm 256-color RGB table (libghostty-vt baseline). */
export function buildXterm256Palette() {
  const palette = new Array(256)

  const vga = [
    [0, 0, 0], [128, 0, 0], [0, 128, 0], [128, 128, 0],
    [0, 0, 128], [128, 0, 128], [0, 128, 128], [192, 192, 192],
    [128, 128, 128], [255, 0, 0], [0, 255, 0], [255, 255, 0],
    [0, 0, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255]
  ]

  for (let i = 0; i < 16; i++) palette[i] = vga[i]

  for (let i = 0; i < 216; i++) {
    const r = Math.floor(i / 36)
    const g = Math.floor((i % 36) / 6)
    const b = i % 6
    const conv = (c) => (c === 0 ? 0 : 55 + c * 40)
    palette[16 + i] = [conv(r), conv(g), conv(b)]
  }

  for (let i = 0; i < 24; i++) {
    const v = 8 + i * 10
    palette[232 + i] = [v, v, v]
  }

  return palette
}

function blendRgb(a, b, t) {
  return [
    Math.round(a[0] * (1 - t) + b[0] * t),
    Math.round(a[1] * (1 - t) + b[1] * t),
    Math.round(a[2] * (1 - t) + b[2] * t)
  ]
}

/** Build a 256-color palette from Catppuccin ANSI + tinted cube/grays. */
function buildCatppuccin256(ansi16, grayRamp, cubeTint) {
  const palette = buildXterm256Palette()

  for (let i = 0; i < 16; i++) {
    palette[i] = hexToRgb(ansi16[i])
  }

  for (let i = 16; i < 232; i++) {
    palette[i] = blendRgb(palette[i], cubeTint, 0.42)
  }

  for (let i = 0; i < 24; i++) {
    palette[232 + i] = hexToRgb(grayRamp[Math.min(i, grayRamp.length - 1)])
  }

  return palette
}

const MOCHA_ANSI = [
  "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
  "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
  "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
  "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"
]

const MOCHA_GRAYS = [
  "#11111b", "#181825", "#1e1e2e", "#313244", "#45475a", "#585b70",
  "#6c7086", "#7f849c", "#9399b2", "#a6adc8", "#bac2de", "#cdd6f4",
  "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4",
  "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4", "#cdd6f4"
]

const LATTE_ANSI = [
  "#bcc0cc", "#d20f39", "#40a02b", "#df8e1d",
  "#1e66f5", "#ea76cb", "#179299", "#5c5f77",
  "#acb0be", "#d20f39", "#40a02b", "#df8e1d",
  "#1e66f5", "#ea76cb", "#179299", "#6c6f85"
]

const LATTE_GRAYS = [
  "#dce0e8", "#e6e9ef", "#eff1f5", "#ccd0da", "#bcc0cc", "#acb0be",
  "#9ca0b0", "#8c8fa1", "#7c7f93", "#6c6f85", "#5c5f77", "#4c4f69",
  "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69",
  "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69", "#4c4f69"
]

export const TERMINAL_PRESETS = {
  catppuccin_mocha: {
    id: "catppuccin_mocha",
    chrome: {
      "--devide-term-bg": "#1e1e2e",
      "--devide-term-fg": "#cdd6f4",
      "--devide-term-border": "#313244",
      "--devide-term-selection": "rgba(137, 180, 250, 0.35)",
      "--devide-term-cursor": "#f5e0dc",
      "--devide-term-prompt": "#94e2d5",
      "--devide-term-muted": "#6c7086",
      "--devide-term-success": "#a6e3a1",
      "--devide-term-warning": "#f9e2af",
      "--devide-term-error": "#f38ba8",
      "--devide-term-info": "#89b4fa",
      "--devide-term-scrollbar-track": "rgba(30, 30, 46, 0.55)",
      "--devide-term-scrollbar-thumb": "rgba(108, 112, 134, 0.55)",
      "--devide-term-scrollbar-active": "rgba(137, 180, 250, 0.9)",
      "--devide-term-focus-ring": "#89b4fa",
      "--devide-term-prompt-border": "#313244"
    },
    palette: buildCatppuccin256(MOCHA_ANSI, MOCHA_GRAYS, hexToRgb("#89b4fa"))
  },
  catppuccin_latte: {
    id: "catppuccin_latte",
    chrome: {
      "--devide-term-bg": "#eff1f5",
      "--devide-term-fg": "#4c4f69",
      "--devide-term-border": "#ccd0da",
      "--devide-term-selection": "rgba(30, 102, 245, 0.28)",
      "--devide-term-cursor": "#dc8a78",
      "--devide-term-prompt": "#179299",
      "--devide-term-muted": "#8c8fa1",
      "--devide-term-success": "#40a02b",
      "--devide-term-warning": "#df8e1d",
      "--devide-term-error": "#d20f39",
      "--devide-term-info": "#1e66f5",
      "--devide-term-scrollbar-track": "rgba(220, 224, 232, 0.75)",
      "--devide-term-scrollbar-thumb": "rgba(140, 143, 161, 0.55)",
      "--devide-term-scrollbar-active": "rgba(30, 102, 245, 0.75)",
      "--devide-term-focus-ring": "#1e66f5",
      "--devide-term-prompt-border": "#dce0e8"
    },
    palette: buildCatppuccin256(LATTE_ANSI, LATTE_GRAYS, hexToRgb("#1e66f5"))
  }
}

/** Zinc-dark fallbacks for first paint before JS applies a preset. */
export const ZINC_CHROME = {
  "--devide-term-bg": "#0a0a0a",
  "--devide-term-fg": "#e4e4e7",
  "--devide-term-border": "#27272a",
  "--devide-term-selection": "rgba(137, 180, 250, 0.35)",
  "--devide-term-cursor": "#e4e4e7",
  "--devide-term-prompt": "#67e8f9",
  "--devide-term-muted": "#64748b",
  "--devide-term-success": "#4ade80",
  "--devide-term-warning": "#fbbf24",
  "--devide-term-error": "#f87171",
  "--devide-term-info": "#67e8f9",
  "--devide-term-scrollbar-track": "rgba(24, 24, 27, 0.55)",
  "--devide-term-scrollbar-thumb": "rgba(113, 113, 122, 0.55)",
  "--devide-term-scrollbar-active": "rgba(137, 180, 250, 0.9)",
  "--devide-term-focus-ring": "#3b82f6",
  "--devide-term-prompt-border": "#18181b"
}

export const BASELINE_PALETTE = buildXterm256Palette()

let baselineIndexByRgb = null
let currentPreset = TERMINAL_PRESETS.catppuccin_mocha
let currentPalette = currentPreset.palette
let serverThemeBundle = null
let schemeReporter = null
let presetReporter = null

const PRESET_STORAGE_KEY = "devide:terminal-preset"
const DEFAULT_PRESET_ID = "catppuccin"

function rebuildBaselineIndex() {
  baselineIndexByRgb = new Map()
  BASELINE_PALETTE.forEach((rgb, index) => {
    baselineIndexByRgb.set(rgbKey(rgb), index)
  })
}

rebuildBaselineIndex()

export function getCurrentPreset() {
  return currentPreset
}

export function getCurrentPalette() {
  return currentPalette
}

/** Remap a cell RGB through the active preset LUT; pass through unknown colors. */
export function remapColor(rgb) {
  if (!rgb || !currentPalette) return rgb

  const index = baselineIndexByRgb.get(rgbKey(rgb))
  if (index === undefined) return rgb

  return currentPalette[index] || rgb
}

export function termVar(name) {
  if (typeof document === "undefined") return ""
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

function systemPrefersDark() {
  return typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
}

function schemeName() {
  return systemPrefersDark() ? "dark" : "light"
}

function normalizePalette(palette) {
  if (!Array.isArray(palette) || palette.length !== 256) return null
  return palette.map((rgb) => [rgb[0], rgb[1], rgb[2]])
}

function presetFromBundle(bundle, scheme) {
  const fallback =
    scheme === "light" ? TERMINAL_PRESETS.catppuccin_latte : TERMINAL_PRESETS.catppuccin_mocha
  const remote = bundle?.[scheme]
  if (!remote) return fallback

  return {
    id: remote.id || fallback.id,
    chrome: {...fallback.chrome, ...(remote.chrome || {})},
    palette: normalizePalette(remote.palette) || fallback.palette
  }
}

export function readServerThemeBundle() {
  const el =
    document.getElementById("workspace-leader-root") ||
    document.querySelector("[data-terminal-themes]")

  if (!el?.dataset?.terminalThemes) return null

  try {
    return JSON.parse(el.dataset.terminalThemes)
  } catch (_) {
    return null
  }
}

export function getStoredTerminalPreset() {
  if (typeof localStorage === "undefined") return DEFAULT_PRESET_ID
  return localStorage.getItem(PRESET_STORAGE_KEY) || DEFAULT_PRESET_ID
}

export function setStoredTerminalPreset(presetId) {
  if (typeof localStorage === "undefined") return
  if (!presetId) return
  localStorage.setItem(PRESET_STORAGE_KEY, presetId)
}

export function applyServerThemeBundle(bundle) {
  if (!bundle || typeof bundle !== "object") return
  serverThemeBundle = bundle
  if (bundle.preset) setStoredTerminalPreset(bundle.preset)
  applyTerminalTheme(resolveTerminalTheme())
}

export function resolveTerminalTheme() {
  const scheme = schemeName()

  if (serverThemeBundle) {
    return presetFromBundle(serverThemeBundle, scheme)
  }

  return scheme === "dark"
    ? TERMINAL_PRESETS.catppuccin_mocha
    : TERMINAL_PRESETS.catppuccin_latte
}

export function reportTerminalScheme() {
  if (typeof schemeReporter === "function") {
    schemeReporter(schemeName())
  }
}

export function setTerminalSchemeReporter(fn) {
  schemeReporter = typeof fn === "function" ? fn : null
  reportTerminalScheme()
}

export function reportTerminalPreset() {
  if (typeof presetReporter !== "function") return

  const bundle = readServerThemeBundle()
  const serverPreset = bundle?.preset || DEFAULT_PRESET_ID
  const stored = getStoredTerminalPreset()

  presetReporter(stored !== serverPreset ? stored : serverPreset)
}

export function setTerminalPresetReporter(fn) {
  presetReporter = typeof fn === "function" ? fn : null
  reportTerminalPreset()
}

export function applyTerminalTheme(preset) {
  preset = preset || resolveTerminalTheme()
  currentPreset = preset
  currentPalette = preset.palette

  const root = document.documentElement.style
  const tokens = preset.chrome || ZINC_CHROME

  for (const [key, value] of Object.entries(tokens)) {
    root.setProperty(key, value)
  }

  window.dispatchEvent(
    new CustomEvent("devide:terminal-theme", { detail: { presetId: preset.id } })
  )
}

let _initialized = false

export function initTerminalThemes() {
  if (_initialized || typeof window === "undefined") return
  _initialized = true

  const bundle = readServerThemeBundle()
  if (bundle) applyServerThemeBundle(bundle)
  else applyTerminalTheme(resolveTerminalTheme())

  if (typeof window.matchMedia !== "function") return

  const mq = window.matchMedia("(prefers-color-scheme: dark)")
  const onScheme = () => {
    applyTerminalTheme(resolveTerminalTheme())
    reportTerminalScheme()
  }

  if (typeof mq.addEventListener === "function") {
    mq.addEventListener("change", onScheme)
  } else if (typeof mq.addListener === "function") {
    mq.addListener(onScheme)
  }
}