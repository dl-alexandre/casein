// Shared filter text for window-picker sidebar rows (index + label).
// Kept separate from the LiveView hook so node:test can cover it.

// Client-side persistence of each rail's sort mode (recency/name/liveness), so
// a chosen order survives page reloads. The server holds the mode in-session;
// these bridge it to localStorage. Guarded so a disabled/again-throwing Storage
// (private mode, quota) never breaks the picker.
const SORT_KEY = (col) => `devide:sidebar-sort:${col}`

export function persistSidebarSort(col, mode) {
  try {
    localStorage.setItem(SORT_KEY(col), mode)
  } catch (_) {
    // ignore
  }
}

export function restoreSidebarSort(hook, col) {
  let mode = null
  try {
    mode = localStorage.getItem(SORT_KEY(col))
  } catch (_) {
    // storage unavailable (private mode / disabled) — leave mode null
  }
  if (mode) hook.pushEvent("sidebar:restore_sort", {col, mode})
}

export function itemFilterText(el) {
  const label = el.querySelector("[data-picker-label]")?.textContent || ""
  const index = el.querySelector(".font-mono")?.textContent || ""
  return `${index} ${label}`.toLowerCase()
}

export function matchesPickerFilter(el, query) {
  const normalized = (query || "").toLowerCase()
  return normalized === "" || itemFilterText(el).includes(normalized)
}

export function pickerBranchId(el) {
  return (
    el.getAttribute("data-picker-sessions-id") ||
    el.getAttribute("data-picker-branch-id") ||
    el.id ||
    null
  )
}

export function buildPickerTree(items) {
  const childrenByParent = new Map()

  for (const el of items) {
    const parent = el.getAttribute("data-picker-parent")
    if (!parent) continue
    if (!childrenByParent.has(parent)) childrenByParent.set(parent, [])
    childrenByParent.get(parent).push(el)
  }

  return {childrenByParent}
}

export function itemSubtreeMatches(el, query, childrenByParent, matches, cache = new Map()) {
  if (cache.has(el)) return cache.get(el)

  const direct = matches(el, query)
  const branchId = pickerBranchId(el)
  const children = branchId ? childrenByParent.get(branchId) || [] : []
  const childMatch = children.some((child) =>
    itemSubtreeMatches(child, query, childrenByParent, matches, cache)
  )
  const result = direct || childMatch

  cache.set(el, result)
  return result
}

function restoreCollapsedBranches(rootEl) {
  rootEl.querySelectorAll("[data-picker-branch-children]").forEach((container) => {
    delete container.dataset.pickerFilterExpanded
    if (container.getAttribute("data-picker-collapsed") != null) {
      container.classList.add("hidden")
    } else {
      container.classList.remove("hidden")
    }
  })
}

function branchHasVisibleItem(branch) {
  return Array.from(branch.querySelectorAll("[data-picker-item]")).some(
    (el) => el.style.display !== "none"
  )
}

/**
 * Tree-aware picker filter: leaf matches keep ancestor rows visible and
 * auto-expand matching branches. Non-matching branches hide.
 */
export function applyTreePickerFilter(rootEl, query, {matches = matchesPickerFilter} = {}) {
  const normalized = (query || "").toLowerCase()
  const items = Array.from(rootEl.querySelectorAll("[data-picker-item]"))
  const display = rootEl.querySelector("[data-picker-filter]")

  if (display) {
    display.textContent = query ? `filter: ${query}` : ""
    display.style.display = query ? "block" : "none"
  }

  if (normalized === "") {
    items.forEach((el) => {
      el.style.display = ""
    })
    rootEl.querySelectorAll("[data-picker-tree-branch]").forEach((branch) => {
      branch.style.display = ""
    })
    restoreCollapsedBranches(rootEl)
    return items
  }

  const {childrenByParent} = buildPickerTree(items)
  const cache = new Map()

  items.forEach((el) => {
    const visible = itemSubtreeMatches(el, normalized, childrenByParent, matches, cache)
    el.style.display = visible ? "" : "none"
  })

  rootEl.querySelectorAll("[data-picker-tree-branch]").forEach((branch) => {
    branch.style.display = branchHasVisibleItem(branch) ? "" : "none"
  })

  rootEl.querySelectorAll("[data-picker-branch-children]").forEach((container) => {
    const anyVisibleChild = Array.from(container.querySelectorAll("[data-picker-item]")).some(
      (el) => el.style.display !== "none"
    )

    if (anyVisibleChild) {
      container.classList.remove("hidden")
      container.dataset.pickerFilterExpanded = "true"
    } else if (container.getAttribute("data-picker-collapsed") != null) {
      container.classList.add("hidden")
      delete container.dataset.pickerFilterExpanded
    }
  })

  return items.filter((el) => el.style.display !== "none")
}