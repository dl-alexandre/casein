// Pure helpers for file-pane status messaging, split out (like editor_lang.mjs)
// so they unit-test without dragging in the CodeMirror import chain.

// Human-readable reason a file could not be opened in the editor, from the
// server's `error` atom (arrives as a string). Used for the in-pane
// placeholder so an unopenable file reads as calm information, not an error.
// The server's read caps live in DevIDE.Files (2 MB, binary sniff).
export function fileErrorMessage(error) {
  switch (error) {
    case "binary":
      return "This is a binary file — it can't be shown in the editor."
    case "too_large":
      return "This file is too large to open (over the 2 MB editor limit)."
    case "not_a_file":
      return "This path isn't a regular file."
    case "not_found":
      return "This file no longer exists on disk."
    case "workspace_not_found":
      return "This workspace is currently unavailable."
    default:
      return `This file could not be opened${error ? ` (${error})` : ""}.`
  }
}
