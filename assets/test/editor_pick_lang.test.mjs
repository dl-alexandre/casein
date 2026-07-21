import assert from "node:assert/strict"
import test from "node:test"

import { languageIdForPath, pickLang } from "../js/editor_lang.mjs"

/** @type {Array<[string, string | null]>} */
const CASES = [
  ["src/app.js", "javascript"],
  ["src/app.jsx", "javascript"],
  ["src/app.ts", "javascript"],
  ["src/app.tsx", "javascript"],
  ["src/app.mjs", "javascript"],
  ["src/app.cjs", "javascript"],
  ["README.md", "markdown"],
  ["package.json", "json"],
  ["lib/dev_ide.ex", "elixir"],
  ["mix.exs", "elixir"],
  ["lib/dev_ide_web/components/layouts/root.html.heex", "html"],
  ["priv/static/index.html", "html"],
  ["page.htm", "html"],
  ["assets/css/app.css", "css"],
  ["scripts/deploy.py", "python"],
  [".github/workflows/ci.yml", "yaml"],
  ["config/compose.yaml", "yaml"],
  ["scripts/setup.sh", "shell"],
  ["bin/run.bash", "shell"],
  ["bin/run.zsh", "shell"],
  ["Makefile", null],
  ["", null],
  [null, null]
]

for (const [path, expected] of CASES) {
  test(`languageIdForPath(${JSON.stringify(path)}) → ${JSON.stringify(expected)}`, () => {
    assert.equal(languageIdForPath(path), expected)
  })
}

test("pickLang returns a LanguageSupport (or StreamLanguage) extension for mapped paths", () => {
  const mapped = CASES.filter(([, id]) => id != null)
  for (const [path, id] of mapped) {
    const exts = pickLang(path)
    assert.equal(exts.length, 1, `expected one extension for ${path} (${id})`)
    // LanguageSupport / StreamLanguage both expose a `.language` facet source.
    assert.ok(exts[0] && typeof exts[0] === "object", `extension object for ${path}`)
  }
})

test("pickLang returns [] for unmapped paths", () => {
  assert.deepEqual(pickLang("Makefile"), [])
  assert.deepEqual(pickLang(""), [])
  assert.deepEqual(pickLang(null), [])
  assert.deepEqual(pickLang(undefined), [])
})

test("case-insensitive extension matching", () => {
  assert.equal(languageIdForPath("Lib/Foo.EX"), "elixir")
  assert.equal(languageIdForPath("App.HEEX"), "html")
  assert.equal(languageIdForPath("Main.PY"), "python")
  assert.equal(languageIdForPath("Style.CSS"), "css")
})
