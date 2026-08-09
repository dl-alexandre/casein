// Cockpit layout for the tablet range (#736), composed with #735.
//
// #735 rule (upstream): width → layout/density; pointer-coarse → hit targets,
// spacing, gestures. Wide coarse tablets already keep desktop pickers.
//
// #736 adds:
//   1. Physical-keyboard evidence (not pointer) + persisted client preference.
//   2. Explicit override auto | compact | desktop (sidebar-sort style).
//   3. data-cockpit-layout attribute only when override/keyboard must change
//      what #735 media queries would do — auto leaves the attribute unset so
//      #735 CSS alone decides the default.
//
// Soft-keyboard printables do not count as keyboard evidence. Pure module for
// node:test; DOM install lives in installCockpitLayout().

export const STORAGE_OVERRIDE_KEY = "casein:cockpit-layout"
export const STORAGE_KEYBOARD_KEY = "casein:cockpit-keyboard"

/** Phone / narrow viewport ceiling — matches Tailwind `sm` and ChromeWidth. */
export const NARROW_MAX_PX = 639

/** Tablet band sits between `sm` and `lg` (640–1023 CSS px). */
export const TABLET_MIN_PX = 640
export const TABLET_MAX_PX = 1023

const PHYSICAL_KEYS = new Set([
  "Tab",
  "Escape",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "Insert",
  "Delete",
  "Backspace",
  "Enter",
  "ContextMenu",
  "Meta",
  "Control",
  "Alt",
  "Shift",
  "CapsLock",
  "OS",
])

/**
 * @param {string | null | undefined} raw
 * @returns {"auto" | "compact" | "desktop"}
 */
export function parseOverride(raw) {
  if (raw === "compact" || raw === "desktop" || raw === "auto") return raw
  return "auto"
}

/**
 * Physical-keyboard evidence. Soft keyboards mostly emit plain printables into
 * focused fields; chords and navigation keys are the hardware signal (incl.
 * Smart Keyboard Folio — still pointer: coarse).
 *
 * @param {Pick<KeyboardEvent, "isTrusted" | "metaKey" | "ctrlKey" | "altKey" | "key" | "isComposing" | "repeat">} event
 */
export function isPhysicalKeyboardEvidence(event) {
  if (!event || event.isTrusted === false) return false
  if (event.isComposing) return false
  if (event.metaKey || event.ctrlKey || event.altKey) return true
  const key = event.key
  if (typeof key !== "string" || key.length === 0) return false
  if (PHYSICAL_KEYS.has(key)) return true
  if (/^F\d{1,2}$/.test(key)) return true
  return false
}

/**
 * Resolve an explicit data-cockpit-layout value, or null to leave the attribute
 * unset so #735 width media queries alone apply.
 *
 * @param {{
 *   override?: "auto" | "compact" | "desktop" | string | null,
 *   keyboardEvidence?: boolean,
 *   viewportWidth?: number,
 *   chromeNarrow?: boolean,
 * }} input
 * @returns {"compact" | "desktop" | null}
 */
export function resolveCockpitLayout(input = {}) {
  const override = parseOverride(input.override)
  if (override === "compact") return "compact"
  if (override === "desktop") return "desktop"

  const width = Number(input.viewportWidth)
  const narrow =
    input.chromeNarrow === true ||
    (Number.isFinite(width) && width > 0 && width <= NARROW_MAX_PX)

  // Phone / pane-squeezed chrome stays on #735 compact layout even with a
  // keyboard — pickers do not fit. Explicit desktop override is the hatch.
  if (narrow) return null

  // Wide + keyboard evidence: stamp desktop so chrome-narrow / future CSS that
  // still compact-treats the band can be overridden. Wide + no keyboard: leave
  // unset — #735 already keeps desktop layout on wide coarse devices.
  if (input.keyboardEvidence) return "desktop"

  return null
}

/**
 * @param {{
 *   width: number,
 *   height: number,
 *   orientation?: "portrait" | "landscape" | string,
 * }} dims
 */
export function describeTabletBand(dims) {
  const width = Number(dims?.width) || 0
  const height = Number(dims?.height) || 0
  const orientation =
    dims?.orientation === "landscape" || dims?.orientation === "portrait"
      ? dims.orientation
      : height > 0 && width > height
        ? "landscape"
        : "portrait"

  const inBand = width >= TABLET_MIN_PX && width <= TABLET_MAX_PX
  return {inBand, orientation, width, height}
}

export function readStoredOverride(storage = globalThis.localStorage) {
  try {
    return parseOverride(storage?.getItem?.(STORAGE_OVERRIDE_KEY))
  } catch (_) {
    return "auto"
  }
}

export function writeStoredOverride(mode, storage = globalThis.localStorage) {
  const parsed = parseOverride(mode)
  try {
    if (parsed === "auto") storage?.removeItem?.(STORAGE_OVERRIDE_KEY)
    else storage?.setItem?.(STORAGE_OVERRIDE_KEY, parsed)
  } catch (_) {
    // private mode / quota — preference is session-only
  }
  return parsed
}

export function readKeyboardEvidence(storage = globalThis.localStorage) {
  try {
    return storage?.getItem?.(STORAGE_KEYBOARD_KEY) === "1"
  } catch (_) {
    return false
  }
}

export function writeKeyboardEvidence(storage = globalThis.localStorage) {
  try {
    storage?.setItem?.(STORAGE_KEYBOARD_KEY, "1")
  } catch (_) {
    // ignore
  }
}

/**
 * Apply layout to <html> and keep it updated.
 * @param {Window} [win]
 */
export function installCockpitLayout(win = globalThis.window) {
  if (!win?.document?.documentElement) return () => {}

  const root = win.document.documentElement
  const storage = win.localStorage
  let keyboardEvidence = readKeyboardEvidence(storage)
  let override = readStoredOverride(storage)

  const measure = () => {
    const chromeNarrow = root.hasAttribute("data-chrome-narrow")
    const layout = resolveCockpitLayout({
      override,
      keyboardEvidence,
      viewportWidth: win.innerWidth,
      chromeNarrow,
    })
    if (layout) root.setAttribute("data-cockpit-layout", layout)
    else root.removeAttribute("data-cockpit-layout")
    root.setAttribute("data-cockpit-layout-override", override)
    root.toggleAttribute("data-cockpit-keyboard", keyboardEvidence)
    return layout
  }

  const onKeydown = (event) => {
    if (keyboardEvidence) return
    if (!isPhysicalKeyboardEvidence(event)) return
    keyboardEvidence = true
    writeKeyboardEvidence(storage)
    measure()
  }

  const onOverride = (event) => {
    const mode = event?.detail?.mode
    override = writeStoredOverride(mode, storage)
    measure()
  }

  const onStorage = (event) => {
    if (!event) return
    if (event.key === STORAGE_OVERRIDE_KEY) {
      override = parseOverride(event.newValue)
      measure()
    } else if (event.key === STORAGE_KEYBOARD_KEY) {
      keyboardEvidence = event.newValue === "1"
      measure()
    }
  }

  // ChromeWidth toggles data-chrome-narrow on the same root; observe it.
  const mo = new win.MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "attributes" && record.attributeName === "data-chrome-narrow") {
        measure()
        break
      }
    }
  })
  mo.observe(root, {attributes: true, attributeFilter: ["data-chrome-narrow"]})

  win.addEventListener("keydown", onKeydown, true)
  win.addEventListener("casein:cockpit-layout", onOverride)
  win.addEventListener("storage", onStorage)
  win.addEventListener("resize", measure)

  measure()

  return () => {
    mo.disconnect()
    win.removeEventListener("keydown", onKeydown, true)
    win.removeEventListener("casein:cockpit-layout", onOverride)
    win.removeEventListener("storage", onStorage)
    win.removeEventListener("resize", measure)
  }
}
