// Client-side store for server-detected terminal web links (http(s) URLs).
//
// Sibling to terminal_file_links.mjs: PaneWorker scans changed rows and
// attaches `payload.web_links = [{row, from, to, url}]` to the ghostty:render
// frame, so link state is transactionally consistent with row content. This
// module keeps the per-hook `Map(row -> links[])` in step with each accepted
// frame: repainted rows are cleared first (all rows on a full frame), then the
// frame's links are applied. Pure functions — DOM/overlay concerns live in
// ghostty_terminal.js.

function fullFramePayload(payload) {
  return payload?.full_frame === true || payload?.["full_frame?"] === true
}

// Update `store` (a Map) from an accepted ghostty:render payload. Same
// clearing rules as the file-link store (see updateFileLinkStore).
function updateWebLinkStore(store, payload) {
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

  const links = Array.isArray(payload?.web_links) ? payload.web_links : []
  for (const link of links) {
    if (!validWebLink(link)) continue
    const list = store.get(link.row)
    if (list) list.push(link)
    else store.set(link.row, [link])
  }
}

function validWebLink(link) {
  return (
    Number.isInteger(link?.row) &&
    Number.isInteger(link?.from) &&
    Number.isInteger(link?.to) &&
    link.from >= 0 &&
    link.to >= link.from &&
    typeof link.url === "string" &&
    /^https?:\/\//i.test(link.url)
  )
}

// The web link covering cell {row, col}, or null.
function webLinkAt(store, row, col) {
  if (!(store instanceof Map)) return null
  const links = store.get(row)
  if (!Array.isArray(links)) return null
  return links.find((link) => col >= link.from && col <= link.to) || null
}

export { webLinkAt, updateWebLinkStore }
