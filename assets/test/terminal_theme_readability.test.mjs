import assert from "node:assert/strict"
import {Buffer} from "node:buffer"
import path from "node:path"
import test from "node:test"
import {fileURLToPath} from "node:url"

import esbuild from "esbuild"

const assetsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

async function loadThemeModule() {
  const result = await esbuild.build({
    entryPoints: [path.join(assetsDir, "js", "terminal_themes.js")],
    bundle: true,
    format: "esm",
    write: false,
    logLevel: "silent"
  })

  const code = Buffer.from(result.outputFiles[0].contents).toString("base64")
  return import(`data:text/javascript;base64,${code}`)
}

test("unspecified foreground stays readable on a dark cell in a light terminal", async () => {
  const previousDocument = globalThis.document
  const previousGetComputedStyle = globalThis.getComputedStyle

  globalThis.document = {}
  globalThis.getComputedStyle = () => ({
    getPropertyValue(name) {
      return {
        "--casein-term-bg": "#eff1f5",
        "--casein-term-fg": "#4c4f69"
      }[name] || ""
    }
  })

  try {
    const {readableTerminalColor} = await loadThemeModule()
    assert.deepEqual(readableTerminalColor(null, [57, 57, 71]), [245, 245, 245])
  } finally {
    globalThis.document = previousDocument
    globalThis.getComputedStyle = previousGetComputedStyle
  }
})
