---
name: preview-ui-walk
description: >
  Drive automated UI smoke walks of any DevIDE workspace app via product-owned
  workflow manifests (default read-only; optional gated interactions). Log in,
  walk pages with screenshot + console/network errors + timing + Tidewave
  evidence (logs, probes, SQL, LiveView keys) + assert/click steps, publish one
  Artifact report with a durable login-gated public URL. Use for any app surface
  (superadmin, facility, feed, login, kiosk, …) — not only one panel. Create or
  improve workflows by editing manifests under .casein/. NOT for driving
  dev_ide's own UI (use `verify`). Pair product agents first with
  workspace-agent-pair when MCP/skills are missing.
---

# Preview UI walk

A **generic** UI walk engine for product apps on Casein. Default is **read-only**
(navigate + assert + screenshot). Product workflows may opt into **gated
interactions** (`safety.allow_interactions`) when env_check is non-prod.

| Layer | Owns |
|-------|------|
| **This skill + drivers** | How to walk, assert, collect evidence, publish reports |
| **Product repo** | *Which* pages/login/safety/probes — one **workflow manifest** per scenario |

Output: one Artifact report per workflow run (screenshots + timings + browser/server
evidence + pass/fail) with a durable login-gated `public_url`.

## Workflows (app-owned catalog — not a single hard-coded flow)

A **workflow** is one JSON walk manifest. Products can ship **many** and improve
them over time without changing this skill.

| Path | Role |
|------|------|
| `.casein/preview-walk.json` | **Default** workflow (back-compat; optional once named walks exist) |
| `.casein/preview-walks/<id>.json` | **Named** workflows (`superadmin-smoke`, `facility-parity`, `login-only`, …) |
| `.casein/preview-walks/README.md` | Optional human index (ids, when to run, risk notes) |

`id` = `^[a-z0-9][a-z0-9._-]*$` (matches `report.name` style). Drivers take any path:

```bash
node …/playwright_walk.mjs --manifest .casein/preview-walks/facility-parity.json --base http://127.0.0.1:<port> --out ./run
python3 …/walk.py --manifest .casein/preview-walk.json --out ./run
```

### Resolve which workflow to run

1. User named a workflow → `.casein/preview-walks/<id>.json` (or an explicit path).
2. Else list candidates: default file (if present) + every `preview-walks/*.json`.
3. One candidate → run it. Multiple → list ids + `report.name` / `_note` and ask, or
   prefer `preview-walk.json` only when the user said “the default walk”.
4. **None** → author a first workflow (below); do not invent product routes in the skill tree.

### Author or improve a workflow

1. Prefer **copying** an existing walk in the same repo (or
   `references/authed-admin-example.json` for shape only — fictional).
2. Set unique `report.name` (artifact slug) and a clear `_note` (when to run).
3. Fill `login`, `pages[]` (paths from the **product router**, not guesses),
   `safety` (env_check + deny_events), optional `runtime` probes.
4. Validate: `check-jsonschema --schemafile <skill>/references/preview-walk.schema.json <manifest>`.
5. Dry-run once read-only; fix probes/login before expanding pages.
6. Commit the manifest in the **product** repo under `.casein/` — never under
   `.claude/skills/preview-ui-walk/`.

Improving a walk = edit the product JSON (pages, asserts, probes, budgets). The
engine stays stable; **workflows are product data**.

## ⚠️ Safety gate — READ THIS FIRST, every run

A workspace app can be backed by **production upstream APIs even when its local DB
is throwaway**. The app's own walk manifest documents that risk under `safety`. So:

1. **Default to strictly read-only**: navigate + screenshot + error collection +
   optional **assert** steps (`assert_text`, `assert_selector`, …). Page *loads*
   fire the app's normal reads — fine.
2. **Mutating steps** (`click` / `fill` / `type` / …) require
   `safety.allow_interactions: true` **and** a clean non-prod `env_check` strip.
   Drivers fail closed if either is missing. Still honor `deny_events` (matched
   against `step.event`).
3. The manifest carries the app's `safety` block. Honor it. Log what you skipped.
   When in doubt, screenshot; never click.

## What it produces

- **One Artifact report** (HTML): per-page thumbnail, load ms, browser
  actionable/raw errors, Tidewave column (logs / probes / SQL / LiveView keys),
  steps column, PASS/FAIL — plus a top strip for env_check + walk probes.
- **A durable, login-gated `public_url`** for that report (from publishing it as an
  artifact project — step 4). This is the actual deliverable you hand back: a link
  that survives workspace restarts and is safe to paste in a PR, where a teammate
  clicks through devbox Google login to see the report. **Close the live walk pane**
  afterward — it was just the execution surface.

## Prerequisites

- **Agent pairing** on the product workspace (MCP + this skill). If OpenCode/Claude
  cannot see DevIDE tools or this skill, run **`workspace-agent-pair`** first
  (`ensure-workspace-agent-pair.sh --workspace <name> --runtime … --verify`).
- **Target app running + preview reachable.** A stopped manager workspace often
  404s through the preview-router. Ensure it's `running` (manager
  `POST /api/workspaces/:id/start`, wait for loopback `:{ports.http}/health` → 200).
- **At least one workflow manifest** in the **target product repo** (see catalog
  above; schema in `references/manifest-schema.md` +
  `references/preview-walk.schema.json`). DevIDE only ships the generic engine
  (`walk.py` / `playwright_walk.mjs`) plus a fictional example
  (`references/authed-admin-example.json`). **Never** add product-specific
  manifests under this skill.

## 1. Resolve the target's scoped preview MCP

The DevIDE MCP tools are workspace-scoped, so to drive a *non-dev_ide* app you use
that workspace's own credentials. From the box:

```bash
source /home/devbox/.casein/agent-mcp/<workspace-name>/env.sh
# → DEVIDE_PREVIEW_MCP_URL (workspace-scoped, includes ?workspace_id&tmux_session)
# → CASEIN_API_TOKEN (64-char, workspace-scoped)
```

Drive tools over plain JSON-RPC (never echo the token):

```bash
curl -sS "$DEVIDE_PREVIEW_MCP_URL" \
  -H "Authorization: Bearer $CASEIN_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"<tool>","arguments":{...}}}'
```

The result JSON is in `result.content[0].text`. (When this skill runs *inside* the
target workspace's own agent, use the native `preview_*` MCP tools directly and
skip the token plumbing.) `references/walk.py` is a ready driver that wraps this —
but it only works for **unauthenticated / no-redirect** targets; for a cookie/redirect
login use `references/playwright_walk.mjs` instead (see Auth reality).

## Auth reality — the preview MCP cannot do redirect/cookie logins

Learned the hard way on real admin apps. **`preview_navigate` blocks 302
redirects** (an origin-safety guard in DevIDE's nav layer), so a redirect-based
login (`/auth/…/mock` → 302 that sets the session cookie → 302 to the panel) never
persists: the browser drops the cookie, every gated page 302s to `/login`, and the
screenshot silently stays on the previous page — **a false green**. `default_headers`
Cookie injection also did *not* carry the session through the block, and in-page
`window.location` bypasses are defeated by the per-click visible-ack timeout
(clicks serialize seconds apart, need <500ms).

**So pick the driver by auth model:**
- **No auth / no login redirect** → `references/walk.py` (preview MCP: navigate +
  screenshot + report_errors). Fine for public pages.
- **Cookie/redirect login (most admin panels)** → **`references/playwright_walk.mjs`**,
  which drives the box's cached Chromium directly via `playwright-core` with a
  server-minted cookie. It mints the cookie with `curl -c jar -L` (curl follows the
  login redirects and keeps the Set-Cookie the MCP block drops), auto-discovers
  `playwright-core` (npx cache) + the cached `chromium` build, injects the cookie,
  then navigates/screenshots/collects console+network per page. Use `login.type:
  "cookie"` in the manifest. This is the only path that actually authenticates today.
  Run it with `--base http://127.0.0.1:<port>` (the app's loopback), not the MCP.
- **Both drivers verify the landed URL per page** (`playwright_walk.mjs` reads
  `page.url()`, `walk.py` reads the observed current URL) and FAIL when it doesn't
  match the page's `lands_on`/`path` — a gated page bounced to `/login` never PASSes
  on a 200 + screenshot alone. Do not weaken this; it is what kills the false green.

A durable follow-up would be teaching DevIDE preview to carry an injected
cookie/storage-state so the MCP path works for authed apps too.

## 2. Reuse the running preview (do not open fresh)

Get the live app surface and its session, don't spin a new one:

- `preview_surfaces` → confirm the `app` surface `server_active: true`.
- Reuse the existing session for that origin (one pane per surface/origin). Only
  `preview_open_app` if none exists; pass `new_control_session` **only** when you
  deliberately want an isolated lane (see Parallelization).

## 3. Record → login → walk → stop

1. `preview_record_start(session_id)`.
2. **Login** per the manifest's `login` step — but heed *Auth reality* above: for a
   redirect/cookie login (`login.type: "cookie"`) hand off to
   `references/playwright_walk.mjs`, which mints the cookie server-side and drives
   Chromium directly (the `preview_navigate` session-inject will silently fail).
   Only for a no-redirect target does navigating the login path work via the MCP
   (`references/walk.py`). The "enter via the logo" gesture maps to hitting the login
   route, but the redirect-block still applies.
3. For each manifest page, in order:
   - `preview_navigate(session_id, path)`
   - wait for render (these apps often have **no `assign_async`** → budget generous
     per-page timeouts; expect a blank dead-render before the WS connects)
   - `preview_screenshot(session_id)` → keep the PNG bytes (data URI in the result)
   - `preview_report_errors(session_id)` → console + network error counts
   - record elapsed ms; mark PASS/FAIL against the manifest's per-page budget
4. `preview_record_stop(session_id)` → webm artifact path.

## 4. Publish the report → hand back a durable, PR-shareable link

Both drivers write a **self-contained** `report.html` (screenshots are inlined as
`data:` URIs). Publish it as an **artifact project** so it gets a durable,
login-gated URL a teammate can open straight from a PR — this is the deliverable,
not the ephemeral walk pane.

1. **Publish** via the artifact MCP — one file map, the report is self-contained:
   ```
   artifact_create(name: "<report.name>", kind: "html",
                   files: { "index.html": <report.html contents> })
   # iterate with artifact_update(artifact_id, files: {...}) on re-runs
   ```
2. **Read `public_url` from the response** — the artifact tools return the full
   payload, so `public_url` (durable, login-gated; e.g.
   `https://devide.devbox…/artifact-projects/<ws>/<id>/`) is right there, alongside
   `commit` (the report's git sha) and `retired` (false while live). **That URL is
   what you hand back** — paste it in the PR. The viewer hits devbox oauth2-proxy →
   Google login → the report. It survives workspace restarts and port churn.
   - `public_url` is **nil** only when `preview_app_url` isn't configured (local
     dev). Then fall back to `preview_open` with the returned `preview_open_arguments`
     for a live look, and say the durable link isn't available in this environment.
3. **Video** — the walk's webm lives in a separate recording artifact, so for the
   durable report either (a) co-locate it: include the webm in the `files` map as
   `walk.webm` and rewrite the report's `<video src>` to the relative `walk.webm`
   (it then plays same-origin under the artifact URL), or (b) keep the screenshot
   grid as the durable record and add a "▶ Open playback" link that fires
   `preview_playback_open(<webm-artifact>)` into a looping pane for a live viewing.
4. Close the live walk pane. The published artifact (its `public_url`) is the single
   conclusion surface.

### Fallback — publishing when the artifact MCP is down

The artifact MCP token can expire mid-session (`requires re-authorization`), which
blocks `artifact_create`/`artifact_update`. You do **not** need the MCP to publish:
an already-created artifact serves its files from a plain `http.server` on the
artifact worktree, and that server keeps running independent of the MCP token. So:

1. Find the artifact's worktree (returned as `worktree_path` when it was created,
   e.g. `/tmp/devide-agent-worktrees/artifacts/<ws>/<name>-<id>`).
2. Copy the report(s) into it and `git commit` — the running server picks up disk
   files immediately. Verify against the local preview port (`curl :PORT/…` → 200).
3. For a multi-surface sweep, write one `index.html` landing page that links each
   `surface.html`; that consolidated page under the existing `public_url` is the
   deliverable. (Reuse one already-published artifact's worktree rather than minting
   a new URL.)

The `public_url` stays valid because it proxies that same server. Caveat: this is
the workspace's local preview server, so the link lives only while that server is
up — re-register via the MCP once it's re-authed for a durable URL.

## 5. Parallelization (optional; default sequential)

Sequential is right for a small read-only walk — it yields one clean, ordered
video, one login, simple aggregation. When the page count grows or the slow pages
(e.g. Metrics/Symphony) dominate, shard across concurrent lanes: `preview_open`
with `new_control_session: true` + a distinct `isolation_key` per lane gives
separate browser/auth/storage contexts against the *same* origin (verified
supported). Each lane logs in independently; then either record one "narrator"
lane or produce per-lane clips the report tabs between. This is a config change to
the page-sharding, not a redesign.

## Notes

- Assert on the screenshot artifact + error counts, NOT on `observe_pane`'s
  `operator_visible`/`browser_loaded` (operator-iframe telemetry; wrong signal for
  a headless driver — see [[preview-pane-e2e-harness]]).
- **`playwright_walk.mjs` noise filter** — common CSP noise (third-party badge
  images, nested-iframe CSP, nonce inline style/script) does not fail the page by
  default; wrong `lands_on` / main-document 4xx still do. See
  `references/manifest-schema.md` (`strict_errors`, `noise_patterns`).
- **Runtime evidence (Tidewave, wired in `playwright_walk.mjs`)** — when the
  manifest sets `runtime.tidewave: true`, the driver:
  1. Probes `<base>/tidewave/mcp` (or `DEVIDE_TIDEWAVE_MCP_URL` / `--tidewave-url`)
  2. Surfaces an **env_check** strip via `project_eval` (app env, not agent host)
  3. Runs walk-level **`probes`** (`project_eval` + optional `expect`)
  4. After each page: `get_logs` **delta**, page probes, SELECT-only **sql**,
     LiveView assign **keys** (optional `fields`)
  5. Fails a page on server error-log deltas, failed probes/SQL, or failed steps
  If Tidewave is down, the browser walk still finishes and runtime is
  `skipped: tidewave_unavailable` (unless `require_tidewave: true`).
  See `references/runtime_evidence.mjs`, `page_steps.mjs`, and schema `runtime` /
  `pages[].steps`.
- Re-runnable: same workflow manifest → same walk. Use `preview_compare_snapshots`
  against a prior run's screenshots for visual-diff regression once a baseline
  exists (only meaningful for pages with stable content).
- **Boundary:** product routes, login, safety, and runtime probes stay in the
  target repo under `.casein/preview-walk.json` and/or `.casein/preview-walks/*.json`.
  This skill must stay app-agnostic — new product scenarios are new manifests, not
  skill forks.
