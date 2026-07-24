/**
 * Terminal themes follow the app appearance by default. Users can pin a
 * dark or light terminal with localStorage["casein:terminal-scheme"].
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
      "--casein-term-bg": "#1e1e2e",
      "--casein-term-fg": "#cdd6f4",
      "--casein-term-border": "#313244",
      "--casein-term-selection": "rgba(137, 180, 250, 0.35)",
      "--casein-term-cursor": "#f5e0dc",
      "--casein-term-prompt": "#94e2d5",
      "--casein-term-muted": "#6c7086",
      "--casein-term-success": "#a6e3a1",
      "--casein-term-warning": "#f9e2af",
      "--casein-term-error": "#f38ba8",
      "--casein-term-info": "#89b4fa",
      "--casein-term-scrollbar-track": "rgba(30, 30, 46, 0.55)",
      "--casein-term-scrollbar-thumb": "rgba(108, 112, 134, 0.55)",
      "--casein-term-scrollbar-active": "rgba(137, 180, 250, 0.9)",
      "--casein-term-focus-ring": "#89b4fa",
      "--casein-term-prompt-border": "#313244"
    },
    palette: buildCatppuccin256(MOCHA_ANSI, MOCHA_GRAYS, hexToRgb("#89b4fa"))
  },
  catppuccin_latte: {
    id: "catppuccin_latte",
    chrome: {
      "--casein-term-bg": "#eff1f5",
      "--casein-term-fg": "#4c4f69",
      "--casein-term-border": "#ccd0da",
      "--casein-term-selection": "rgba(30, 102, 245, 0.28)",
      "--casein-term-cursor": "#dc8a78",
      "--casein-term-prompt": "#179299",
      "--casein-term-muted": "#8c8fa1",
      "--casein-term-success": "#40a02b",
      "--casein-term-warning": "#df8e1d",
      "--casein-term-error": "#d20f39",
      "--casein-term-info": "#1e66f5",
      "--casein-term-scrollbar-track": "rgba(220, 224, 232, 0.75)",
      "--casein-term-scrollbar-thumb": "rgba(140, 143, 161, 0.55)",
      "--casein-term-scrollbar-active": "rgba(30, 102, 245, 0.75)",
      "--casein-term-focus-ring": "#1e66f5",
      "--casein-term-prompt-border": "#dce0e8"
    },
    palette: buildCatppuccin256(LATTE_ANSI, LATTE_GRAYS, hexToRgb("#1e66f5"))
  }
}

/** Zinc-dark fallbacks for first paint before JS applies a preset. */
export const ZINC_CHROME = {
  "--casein-term-bg": "#0a0a0a",
  "--casein-term-fg": "#e4e4e7",
  "--casein-term-border": "#27272a",
  "--casein-term-selection": "rgba(137, 180, 250, 0.35)",
  "--casein-term-cursor": "#e4e4e7",
  "--casein-term-prompt": "#67e8f9",
  "--casein-term-muted": "#64748b",
  "--casein-term-success": "#4ade80",
  "--casein-term-warning": "#fbbf24",
  "--casein-term-error": "#f87171",
  "--casein-term-info": "#67e8f9",
  "--casein-term-scrollbar-track": "rgba(24, 24, 27, 0.55)",
  "--casein-term-scrollbar-thumb": "rgba(113, 113, 122, 0.55)",
  "--casein-term-scrollbar-active": "rgba(137, 180, 250, 0.9)",
  "--casein-term-focus-ring": "#3b82f6",
  "--casein-term-prompt-border": "#18181b"
}

export const BASELINE_PALETTE = buildXterm256Palette()

let baselineIndexByRgb = null
let currentPreset = TERMINAL_PRESETS.catppuccin_mocha
let currentPalette = currentPreset.palette
let serverThemeBundle = null
let schemeReporter = null
let presetReporter = null

const PRESET_STORAGE_KEY = "casein:terminal-preset"
const SCHEME_STORAGE_KEY = "casein:terminal-scheme"
const APP_THEME_STORAGE_KEY = "phx:theme"
const DEFAULT_PRESET_ID = "catppuccin"
const DEFAULT_SCHEME = "system"
const SCHEME_VALUES = new Set(["dark", "light", "system"])

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

function relativeLuminance(rgb) {
  const channel = (value) => {
    const c = value / 255
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
  }

  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
}

function contrastRatio(a, b) {
  const l1 = relativeLuminance(a)
  const l2 = relativeLuminance(b)
  const lighter = Math.max(l1, l2)
  const darker = Math.min(l1, l2)
  return (lighter + 0.05) / (darker + 0.05)
}

function parseRgb(value) {
  if (!value) return null

  const hex = value.trim().match(/^#([0-9a-f]{6})$/i)
  if (hex) return hexToRgb(hex[0])

  const rgb = value.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i)
  if (!rgb) return null

  return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])]
}

export function terminalBackgroundRgb() {
  return parseRgb(termVar("--casein-term-bg")) || hexToRgb("#0a0a0a")
}

export function terminalForegroundRgb() {
  return parseRgb(termVar("--casein-term-fg")) || hexToRgb("#e4e4e7")
}

export function readableTerminalColor(fg, bg) {
  // TUIs commonly paint a per-cell background while leaving the foreground
  // unspecified. In that case the browser would inherit the terminal's
  // default foreground, which can be illegible when a light terminal hosts a
  // dark input/composer surface (and vice versa). Contrast-check the inherited
  // color exactly as we do an explicit cell color.
  const foreground = fg || terminalForegroundRgb()

  const background = bg || terminalBackgroundRgb()
  if (!background || contrastRatio(foreground, background) >= 3) return foreground

  const candidates = [
    terminalForegroundRgb(),
    [245, 245, 245],
    [24, 24, 27]
  ]

  return candidates
    .filter(Boolean)
    .sort((a, b) => contrastRatio(b, background) - contrastRatio(a, background))[0] || foreground
}

export function termVar(name) {
  if (typeof document === "undefined") return ""
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

function systemPrefersDark() {
  return typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
}

function storedAppTheme() {
  if (typeof localStorage === "undefined") return DEFAULT_SCHEME

  try {
    const stored = localStorage.getItem(APP_THEME_STORAGE_KEY)
    return SCHEME_VALUES.has(stored) ? stored : DEFAULT_SCHEME
  } catch (_) {
    return DEFAULT_SCHEME
  }
}

function appThemeSchemeName() {
  if (typeof document !== "undefined") {
    const theme = document.documentElement.getAttribute("data-theme")
    if (theme === "dark" || theme === "light") return theme
  }

  const stored = storedAppTheme()
  if (stored === "dark" || stored === "light") return stored

  return systemPrefersDark() ? "dark" : "light"
}

function schemeName() {
  const stored = getStoredTerminalScheme()
  if (stored === "dark" || stored === "light") return stored
  return appThemeSchemeName()
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

export function getStoredTerminalScheme() {
  if (typeof localStorage === "undefined") return DEFAULT_SCHEME

  try {
    const stored = localStorage.getItem(SCHEME_STORAGE_KEY)
    return SCHEME_VALUES.has(stored) ? stored : DEFAULT_SCHEME
  } catch (_) {
    return DEFAULT_SCHEME
  }
}

export function setStoredTerminalScheme(scheme) {
  if (typeof localStorage === "undefined") return
  if (!SCHEME_VALUES.has(scheme)) return

  try {
    localStorage.setItem(SCHEME_STORAGE_KEY, scheme)
    applyResolvedTerminalTheme()
  } catch (_) {
    /* Storage can be disabled; the system-following default still applies. */
  }
}

/**
 * Apply a server theme bundle (dark/light chrome + 256 LUT).
 * When `bundle.preview` is true, skip localStorage so palette highlight
 * previews do not persist until the user confirms with Enter.
 */
export function applyServerThemeBundle(bundle) {
  if (!bundle || typeof bundle !== "object") return
  serverThemeBundle = bundle
  const preview = bundle.preview === true || bundle.preview === "true"
  if (bundle.preset && !preview) setStoredTerminalPreset(bundle.preset)
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
    new CustomEvent("casein:terminal-theme", { detail: { presetId: preset.id } })
  )
}

function applyResolvedTerminalTheme() {
  applyTerminalTheme(resolveTerminalTheme())
  reportTerminalScheme()
}

let _initialized = false

export function initTerminalThemes() {
  if (_initialized || typeof window === "undefined") return
  _initialized = true

  const bundle = readServerThemeBundle()
  if (bundle) applyServerThemeBundle(bundle)
  else applyTerminalTheme(resolveTerminalTheme())

  const onScheme = () => {
    applyResolvedTerminalTheme()
  }

  window.addEventListener("storage", (event) => {
    if (event.key === APP_THEME_STORAGE_KEY || event.key === SCHEME_STORAGE_KEY) {
      onScheme()
    }
  })

  window.addEventListener("phx:set-theme", () => {
    window.requestAnimationFrame(onScheme)
  })

  if (typeof window.matchMedia !== "function") return

  const mq = window.matchMedia("(prefers-color-scheme: dark)")

  if (typeof mq.addEventListener === "function") {
    mq.addEventListener("change", onScheme)
  } else if (typeof mq.addListener === "function") {
    mq.addListener(onScheme)
  }
}
