import assert from "node:assert/strict"
import test from "node:test"

import {formatPath, formatPaths, pathModeFor} from "../js/terminal_clipboard_format.mjs"

const image = {
  path: "/data/workspaces/dalexandre/casein/.casein/clipboard/20260709T115407Z-I6B-clipboard-image.png",
  relative_path: ".casein/clipboard/20260709T115407Z-I6B-clipboard-image.png",
  content_type: "image/png"
}

test("server path_format agent upgrades over shell defaults", () => {
  const saved = [{...image, path_format: "agent"}]
  assert.equal(pathModeFor(saved, {pathFormat: "shell"}), "agent")
  assert.equal(formatPaths(saved, {pathFormat: "shell"}), `@${image.path}`)
})

test("server path_format shell does not block client agent detection", () => {
  // Grok often shows as `node` in pane_current_command; server then says shell.
  // Viewport detection must still be able to choose agent.
  const saved = [{...image, path_format: "shell"}]
  assert.equal(
    pathModeFor(saved, {pathFormat: "auto", detectPathFormat: () => "agent"}),
    "agent"
  )
})

test("agent mode prefixes @ so Grok attaches the image file", () => {
  assert.equal(formatPath(image, "agent"), `@${image.path}`)
})

test("shell mode quotes the path (legacy fallback)", () => {
  assert.equal(formatPath(image, "shell"), `'${image.path}'`)
})

test("without server hint, detectPathFormat is used", () => {
  assert.equal(
    pathModeFor([image], {
      pathFormat: "auto",
      detectPathFormat: () => "agent"
    }),
    "agent"
  )
  assert.equal(
    pathModeFor([image], {
      pathFormat: "auto",
      detectPathFormat: () => "shell"
    }),
    "shell"
  )
})
