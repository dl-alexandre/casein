// ESLint flat config for the hand-written LiveView hooks and terminal glue.
// Scope: js/ only — vendor/ is third-party and excluded.
import js from "@eslint/js"
import globals from "globals"

export default [
  js.configs.recommended,
  {
    files: ["js/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        ...globals.browser,
        // esbuild substitutes process.env.NODE_ENV at bundle time (used by
        // the phoenix_live_reload block in app.js).
        process: "readonly"
      }
    },
    rules: {
      // Phoenix hooks intentionally ignore some callback args and use
      // `catch (_) {}` guards; allow the underscore escape hatch.
      "no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_"
        }
      ],
      "no-empty": ["error", { allowEmptyCatch: true }],
      // This is a terminal app: matching ANSI escape sequences (\x1b...) in
      // strings is the whole point.
      "no-control-regex": "off"
    }
  },
  {
    ignores: ["vendor/**", "node_modules/**"]
  }
]
