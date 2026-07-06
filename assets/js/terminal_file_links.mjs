// Client-side store for server-detected terminal file links.
//
// PaneWorker scans changed rows server-side and attaches
// `payload.file_links = [{row, from, to, path, line}]` to the ghostty:render
// frame, so link state is transactionally consistent with row content. This
// module keeps the per-hook `Map(row -> links[])` in step with each accepted
// frame: repainted rows are cleared first (all rows on a full frame), then the
// frame's links are applied. Pure functions — DOM/overlay concerns live in
// ghostty_terminal.js.

function fullFramePayload(payload) {
  return payload?.full_frame === true || payload?.["full_frame?"] === true
}

// Update `store` (a Map) from an accepted ghostty:render payload.
//
// - full frame: every row repainted — reset the store.
// - incremental frame: clear exactly the repainted row indexes
//   (`payload.rows` — present even after cell hydration).
// - metadata-only frames (scrollbar ticks, synthetic theme repaints): leave
//   the store alone; they repaint nothing.
function updateFileLinkStore(store, payload) {
  if (!(store instanceof Map)) return

  if (fullFramePayload(payload)) {
    store.clear()
  } else if (Array.isArray(payload?.rows)) {
    for (const row of payload.rows) {
      if (Number.isInteger(row?.index)) store.delete(row.index)
    }
  } else {
    return
  }

  const links = Array.isArray(payload?.file_links) ? payload.file_links : []
  for (const link of links) {
    if (!validFileLink(link)) continue
    const list = store.get(link.row)
    if (list) list.push(link)
    else store.set(link.row, [link])
  }
}

function validFileLink(link) {
  return (
    Number.isInteger(link?.row) &&
    Number.isInteger(link?.from) &&
    Number.isInteger(link?.to) &&
    link.from >= 0 &&
    link.to >= link.from &&
    typeof link.path === "string" &&
    link.path !== ""
  )
}

// The link covering cell {row, col}, or null.
function fileLinkAt(store, row, col) {
  if (!(store instanceof Map)) return null
  const links = store.get(row)
  if (!Array.isArray(links)) return null
  return links.find((link) => col >= link.from && col <= link.to) || null
}

export { fileLinkAt, updateFileLinkStore }
