import assert from "node:assert/strict"
import test from "node:test"

import { fileErrorMessage } from "../js/editor_file_status.mjs"

test("known server error atoms map to specific, calm messages", () => {
  assert.match(fileErrorMessage("binary"), /binary file/i)
  assert.match(fileErrorMessage("too_large"), /too large/i)
  assert.match(fileErrorMessage("too_large"), /2 MB/)
  assert.match(fileErrorMessage("not_a_file"), /regular file/i)
  assert.match(fileErrorMessage("not_found"), /no longer exists/i)
  assert.match(fileErrorMessage("workspace_not_found"), /workspace/i)
})

test("unknown errors fall back and surface the raw reason", () => {
  assert.match(fileErrorMessage("eacces"), /could not be opened/i)
  assert.match(fileErrorMessage("eacces"), /eacces/)
})

test("a missing/empty reason still yields a clean sentence", () => {
  const msg = fileErrorMessage(undefined)
  assert.match(msg, /could not be opened/i)
  // No dangling "(undefined)" parenthetical.
  assert.doesNotMatch(msg, /undefined|\(\)/)
})
