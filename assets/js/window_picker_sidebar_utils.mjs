// Shared filter text for window-picker sidebar rows (index + label).
// Kept separate from the LiveView hook so node:test can cover it.

export function itemFilterText(el) {
  const label = el.querySelector("[data-picker-label]")?.textContent || ""
  const index = el.querySelector(".font-mono")?.textContent || ""
  return `${index} ${label}`.toLowerCase()
}

export function matchesPickerFilter(el, query) {
  const normalized = (query || "").toLowerCase()
  return normalized === "" || itemFilterText(el).includes(normalized)
}
