// Path → CodeMirror language extensions for every Casein editor surface.
// Kept as ESM (.mjs) so node --test can import it under assets/"type":"commonjs".

import { StreamLanguage } from "@codemirror/language"
import { javascript } from "@codemirror/lang-javascript"
import { markdown } from "@codemirror/lang-markdown"
import { json } from "@codemirror/lang-json"
import { html } from "@codemirror/lang-html"
import { css } from "@codemirror/lang-css"
import { python } from "@codemirror/lang-python"
import { yaml } from "@codemirror/lang-yaml"
import { elixir } from "codemirror-lang-elixir"
import { shell } from "@codemirror/legacy-modes/mode/shell"

// Extension → language id mapping used by pickLang. Exported so tests can
// assert path routing without constructing CodeMirror LanguageSupport values.
export function languageIdForPath(path) {
  if (!path) return null
  if (/\.(js|jsx|ts|tsx|mjs|cjs)$/i.test(path)) return "javascript"
  if (/\.md$/i.test(path)) return "markdown"
  if (/\.json$/i.test(path)) return "json"
  if (/\.(ex|exs)$/i.test(path)) return "elixir"
  // No maintained HEEx grammar for CM6; HTML is the closest first-party mode
  // (Elixir interpolations stay unhighlighted inside script/attrs).
  if (/\.heex$/i.test(path)) return "html"
  if (/\.html?$/i.test(path)) return "html"
  if (/\.css$/i.test(path)) return "css"
  if (/\.py$/i.test(path)) return "python"
  if (/\.ya?ml$/i.test(path)) return "yaml"
  if (/\.(sh|bash|zsh)$/i.test(path)) return "shell"
  return null
}

export function pickLang(path) {
  switch (languageIdForPath(path)) {
    case "javascript":
      return [javascript()]
    case "markdown":
      return [markdown()]
    case "json":
      return [json()]
    case "elixir":
      return [elixir()]
    case "html":
      return [html()]
    case "css":
      return [css()]
    case "python":
      return [python()]
    case "yaml":
      return [yaml()]
    case "shell":
      return [StreamLanguage.define(shell)]
    default:
      return []
  }
}
