# Windows Preview MCP clean-host acceptance (#463)

**Authority:** workstream B tracking issue
[#463](https://github.com/dl-alexandre/casein/issues/463). Sibling tracks (do
not redefine their gates here):

| Issue | What it owns |
|---|---|
| [#376](https://github.com/dl-alexandre/casein/issues/376) | Production Authenticode + clean Windows 11 machine release gate |
| [#462](https://github.com/dl-alexandre/casein/issues/462) | Windows terminal/session core |
| [#803](https://github.com/dl-alexandre/casein/pull/803) | Package-smoke of shipped `preview_playwright.mjs` daemon action path |

This document is the **operator runbook and evidence contract** for the
remaining clean-host Preview MCP walk. A green source suite, Linux dry-run,
package smoke, or hosted Windows CI job is **not** clean-machine acceptance.

## What this box can and cannot prove

| Claim | Proven on Linux/devbox / CI? | Requires |
|---|---|---|
| Evidence JSON schema + fail-closed validator | Yes (`scripts/verify_windows_preview_mcp_clean_host.sh`) | — |
| Dry-run keeps `clean_host_exercised=false` | Yes (`--dry-run`) | — |
| `preview_bridge.js` esbuild IIFE on `file://` emits bridge signals under Playwright | Yes (`scripts/verify_preview_bridge_file_page.mjs`) | assets + priv/scripts node_modules |
| Packaged Node/Playwright/Chromium daemon observe/type/click/… on Windows package smoke | Yes (package smoke / #803) | Hosted Windows package job when billing allows |
| Agent inside **installed** Windows workspace drives Preview MCP discover→open→observe→click→type→press→screenshot→close | **No** | Disposable signed Win11 host + installed desktop package |

**Honest outcome for unattended runners on this devbox:**

```bash
bash scripts/verify_windows_preview_mcp_clean_host.sh --dry-run \
  --evidence /tmp/casein-463-dry-run.json
node scripts/verify_preview_bridge_file_page.mjs --json
```

Expect dry-run `verdict: lab_unreachable_on_this_host` with
`claims.clean_host_exercised=false`. That is a **successful lab definition
check**, not walk pass. Do not close #463 on dry-run or the file:// bridge walk
alone.

## Real browser verification without `/verify` (landed software)

`scripts/verify_preview_bridge_file_page.mjs`:

1. esbuilds `assets/js/preview_bridge.js` to a browser IIFE
2. writes a static HTML fixture beside the IIFE
3. launches Chromium via `priv/scripts` Playwright
4. opens `file://…/bridge_fixture.html?casein_preview=1`
5. asserts `casein:preview:bridge_ready` and `casein:preview:dom_loaded`

**Proves:** bridge module bundles, loads on a static page, and emits the parent
signal contract under a real Chromium. **Does not prove:** clean Win11, MCP
tooling, packaged Windows runtime, or agent-inside-workspace control.

Known host noise: `page.screenshot` can fail under load with
`Protocol error (Page.captureScreenshot)`. This walk does **not** require
screenshots for pass criteria.

## Prerequisites (operator, before the MCP walk)

1. **Disposable signed Windows 11 host** with the installed Casein desktop
   package (production Authenticode preferred; see #376).
2. **Exact package SHA** recorded as full 40-char git SHA (`package_sha` and
   usually `product_revision`).
3. **Agent launched inside the installed workspace** with Preview MCP wired
   (not a Linux agent remote-driving the host).
4. A reachable preview target the agent may open (local static server or
   workspace app surface).

## Forbidden evidence (automatic reject)

The validator fails closed if evidence contains any of:

- Bearer / API tokens, JWT-shaped strings, private keys, passwords
- `claims.clean_host_exercised=true` without completed `mcp_steps`
- `verdict: walk_passed` without `agent_inside_installed_workspace`,
  `host.kind=clean_win11_signed_install`, and `host.package_signed=true`
- Linux dry-run or package-smoke-only claims combined with `walk_passed`

## MCP steps (fixed order)

| id | Operator / agent action | Pass criteria |
|---|---|---|
| `discover` | Preview MCP surfaces/list discovers a usable surface | Surface listed; no auth secret in notes |
| `open` | open the surface into a control session | session id present (redact in notes) |
| `observe` | observe / observe_live | title or URL family recorded without secrets |
| `click` | click a visible control | ok / element resolved |
| `type` | type into a field | ok |
| `press` | press a key (e.g. Tab/Enter) | ok |
| `screenshot` | capture screenshot | artifact ref only (no raw base64 in JSON) |
| `close` | close session / pane | ok |

## Operator procedure

```bash
# 0) On the operator machine that can reach the Win11 host evidence path:
export PKG_SHA="<40-char-sha-of-installed-package>"
export EVIDENCE="$HOME/Desktop/casein-463-preview-mcp-${PKG_SHA:0:12}.json"

# 1) Linux definition check (devbox / CI) — not acceptance.
bash scripts/verify_windows_preview_mcp_clean_host.sh --dry-run \
  --evidence /tmp/casein-463-dry-run.json
node scripts/verify_preview_bridge_file_page.mjs

# 2) Print a template and fill it on the clean host after the agent walk:
bash scripts/verify_windows_preview_mcp_clean_host.sh --print-template > "$EVIDENCE"
# edit: operator, package_sha, host.*, claims.*, each mcp_steps[].outcome/at_utc/notes

# 3) Validate before attaching to #463:
bash scripts/verify_windows_preview_mcp_clean_host.sh --validate-evidence "$EVIDENCE"
```

Attach the validated JSON (and redacted screenshots by reference only) on issue
#463. Close the issue only when `verdict` is `walk_passed` after validation.

## Related software already on master

- Packaged preview runtime + repair diagnostics (#470, #518)
- Package-smoke diagnose (#545) and daemon action path (#803)
- Shared Preview MCP schemas (unchanged by this lab)
