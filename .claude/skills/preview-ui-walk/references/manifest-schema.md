# Walk manifest schema

A walk manifest is the **app-owned contract** for one UI smoke **workflow**
(default read-only; optional gated interactions). Apps may ship many workflows.

| Layer | Owns | Lives in |
|-------|------|----------|
| **Product** | paths, login, safety, runtime probes, page steps | `.casein/preview-walk.json` **and/or** `.casein/preview-walks/<id>.json` |
| **Casein** | drivers, skill, this schema, fictional example | `.claude/skills/preview-ui-walk/` |

Machine-readable schema: [`preview-walk.schema.json`](./preview-walk.schema.json) (JSON Schema draft-07).
Shape example (fictional): [`authed-admin-example.json`](./authed-admin-example.json).

**Do not** check product-specific manifests into the Casein skill tree.

## Multi-workflow layout

```text
<product-repo>/
  .casein/
    preview-walk.json                 # optional default (back-compat)
    preview-walks/
      README.md                       # optional index
      superadmin-smoke.json
      facility-parity.json
      login-only.json
```

Each JSON file is a full manifest (same schema). Drivers accept any path via
`--manifest`. Prefer a unique `report.name` per workflow so artifact slugs do not
collide. Superadmin smoke is **one** workflow among many — not the skill’s only use.

## Layers in one file

```text
┌──────────────────────────────────────────────────────────┐
│ login + pages + report     MACHINE (drivers enforce)     │
│ pages[].steps              ASSERT / gated INTERACT       │
│ safety.*                   AGENT POLICY (preflight/gate) │
│ runtime.*                  SERVER EVIDENCE (Tidewave)    │
│ workspace / app_surface    HOST HINTS (prefer env)       │
│ _note / note / role_gated  ANNOTATIONS (ignored)         │
└──────────────────────────────────────────────────────────┘
```

**Browser baseline (wired):** screenshot, load ms, console/network counts,
`lands_on`, optional `steps` (assert always; click/fill when opted in).

**Server evidence (wired when Tidewave is up):**
1. availability + env safety strip + app cwd/SHA
2. per-page `get_logs` **delta** for `log_levels`
3. walk-level + page-level `project_eval` probes
4. per-page SELECT-only SQL (`expect` / `expect_min`)
5. LiveView assign **keys** (+ optional small `fields`)

If Tidewave is unreachable: **still walk the browser path**, mark runtime as
`skipped: tidewave_unavailable` — never pretend the evidence packet is complete.

## Minimal product shape

```jsonc
{
  "version": 1,
  "login": {
    "kind": "redirect_cookie",         // preferred; or legacy type: "cookie"
    "path": "/dev/login",
    "params": { "role": "admin" },
    "params_from_env": ["WALK_LOGIN_EMAIL"],
    "lands_on": "/admin"
  },
  "pages": [
    {
      "name": "Dashboard",
      "path": "/admin",
      "lands_on": "/admin",
      "budget_ms": 8000,
      "steps": [
        { "action": "assert_text", "text": "Dashboard" },
        { "action": "assert_selector", "selector": "main" }
      ]
    }
  ],
  "safety": {
    "read_only": true,
    "allow_interactions": false,
    "env_check": ["APP_API_URL", "AUTH_API_URL"],
    "deny_events": ["delete", "confirm_delete", "save"]
  },
  "runtime": {
    "tidewave": true,
    "log_levels": ["error", "warning"],
    "probes": [
      { "name": "admin_role", "eval": "… small read-only Elixir …", "expect": "ok" }
    ],
    "liveview": { "enabled": true, "assign_keys": true },
    "per_page": {
      "Themes": {
        "sql": "SELECT count(*) FROM themes",
        "expect_min": 1
      }
    }
  },
  "report": { "name": "admin-smoke" }
}
```

## Field notes

### Machine (drivers)

- **`login.kind`** (preferred) / **`login.type`** (legacy)
  - `redirect_cookie` / `cookie` → `playwright_walk.mjs` (MCP blocks 302s; see SKILL “Auth reality”)
  - `session` / `session_inject` → `walk.py` only when login has **no** redirect
  - `none` → public pages
- **`pages[].path` / `lands_on`** — navigate + anti false-green (bounce to `/login` fails).
- **`pages[].budget_ms`** — load budget (includes settle + steps).
- **`pages[].steps`** — ordered assertions / interactions (see below).
- **`report.name`** — artifact slug.
- **`strict_errors` / `noise_patterns`** — CSP noise filter controls (Playwright).

### Page steps

| Action | Mutating? | Notes |
|--------|-----------|--------|
| `wait_for` / `wait_for_selector` | no | CSS selector; optional `frame` |
| `assert_selector` / `assert_text` / `assert_url` | no | always allowed; `frame`/`iframe` scopes into embeds |
| `assert_iframe` | no | **embed loaded** — body length / text / URL (kills shell-only false greens) |
| `assert_http` | no | session cookie GET (path status + optional body text) |
| `settle` | no | fixed sleep |
| `click` / `fill` / `type` / `press` / `select` / `check` / `hover` | **yes** | needs `safety.allow_interactions: true` + non-prod `env_check` |

**Anti false-green:** pages that wrap an iframe (LiveDashboard, HexDocs) must use
`assert_iframe` (and usually `assert_http` on the raw embed path). Shell title alone is not enough.

Mutating steps also check `step.event` against `safety.deny_events`. If interactions
are blocked, a required mutating step **FAIL**s (so the walk does not greenwash
as navigate-only). Set `"required": false` to SKIP instead.

### Agent policy

- **`safety.read_only`** — default true; keep it unless you deliberately interact.
- **`safety.allow_interactions`** — opt-in for click/fill/type/… (still fail-closed on prod_like env).
- **`safety.env_check`** — keys for prod-write risk; surface in report; gate interactions.
- **`safety.deny_events`** — never fire these event names.

### Runtime / Tidewave (evidence packet)

Collection status in `playwright_walk.mjs` + `runtime_evidence.mjs`:

1. Tidewave availability + env safety strip — **wired**
2. Per-page `get_logs` delta for `log_levels` — **wired**
   (page FAILs if *new* error lines since previous page &gt; 0)
3. Walk-level + page-level **`probes`** (`project_eval`) — **wired**
4. **`per_page` / `page.runtime` SQL** (SELECT-only) — **wired**
5. LiveView assign keys / optional fields — **wired**

Override Tidewave URL with `CASEIN_TIDEWAVE_MCP_URL` or `--tidewave-url`.

Safety for runtime:

- Dev / preview-env only — never prod Tidewave
- SQL: `SELECT` only (driver rejects multi-statement / write keywords)
- Probes: soft reject of `Repo.insert` / `File.write` / `System.cmd` patterns
- Artifact: assign **keys** + small derived facts — not full socket assigns (PII)
- Email-like field values redacted as `[redacted-email]`

### Host hints (prefer launch env)

- **`workspace`** — `~/.casein/agent-mcp/<name>/env.sh`; omit from product files when the agent already has workspace context.
- **`app_surface`** — preview surface name for `walk.py` only.

## Report shape

Per page (HTML + `results.json`):

```text
Dashboard  PASS  3120ms
  browser:  console=0/0 network=0/0 lands_on=/admin  HTTP 200
  tidewave: error_logs=0  lv=1 keys=[current_user, flash, …]
  probes:   admin_role=PASS
  sql:      (none or PASS → 12)
  steps:    assert_text=PASS  assert_selector=PASS
```

Top strip: Tidewave yes/no + MCP URL, app cwd/SHA, `env_check` results,
walk-level probes, server log delta total.
`actionable/raw` console counts remain for CSP noise transparency.

## Validation

```bash
# default or named workflow
check-jsonschema --schemafile references/preview-walk.schema.json \
  /path/to/app/.casein/preview-walk.json

check-jsonschema --schemafile references/preview-walk.schema.json \
  /path/to/app/.casein/preview-walks/facility-parity.json
```

Or any draft-07 validator. Drivers should fail closed on schema-invalid manifests once validation is wired into the skill entrypoint.

## Authoring checklist (new or improved workflow)

1. Copy a sibling walk or the fictional example (shape only).
2. Derive `pages[].path` from the product router / LiveView routes — never guess.
3. Keep `safety.read_only: true` until env_check is proven non-prod.
4. Unique `report.name`; document intent in `_note` or `preview-walks/README.md`.
5. Schema-validate; run once; tighten asserts/probes from real failures.

## Normalized result classes (v1.1)

Every page keeps its **diagnostic status** (`PASS`, `PASS_SLOW`, `BOUNCED`,
`CRASHED`, `RUNTIME_ERROR`, `ASSERT_FAILED`, `TIMEOUT`, `SKIPPED`, `BLOCKED`)
and additionally reports a **normalized class** that consumers may reason about:

| Class | Meaning | Sources |
|-------|---------|---------|
| `PASS` | Assertions ran and held | `PASS`, `PASS_SLOW` |
| `FAILED` | Assertions ran and lost | `FAIL`, `ASSERT_FAILED`, `CRASHED`, `RUNTIME_ERROR`, `TIMEOUT`, auth `BOUNCED` |
| `BLOCKED` | A precondition or **required evidence** was unavailable, so nothing was proved | `BLOCKED` |
| `NOT_TESTED` | Deliberately not exercised | `SKIPPED` (interactions gate), tolerated access `BOUNCED` |

`resultClass/3` and `RESULT_CLASSES` live in `walk_verdict.mjs` and are
fixture-tested in `selftest.mjs`. Two rules worth internalising:

* A **tolerated access bounce is `NOT_TESTED`, not `PASS`.** The page never
  landed, so its assertions never ran — reporting it green is the false-green
  failure mode this taxonomy exists to prevent. It is not `FAILED` either,
  because `isHardFailStatus` intentionally tolerates access gating on role
  sweeps. An **auth** bounce (→ `/login`) is always `FAILED`.
* **`BLOCKED` fails the run by default** (`isHardFailStatus("BLOCKED") === true`).
  That is the fail-closed contract: a walk that could not collect what it was
  told to collect must not exit green. `--soft-blocked` downgrades it for
  exploratory runs only.

## Required evidence (fail closed)

```json
{ "require_evidence": ["har", "a11y", "cleanup"] }
```

Declare collectors that MUST produce evidence, walk-level and/or per page
(`pages[].require_evidence`, merged). `evidenceGuard/2` returns a `BLOCKED`
verdict naming exactly what was missing, evaluated **before** any assertion, so
"collector produced nothing" can never be reported as a pass. Empty objects,
empty arrays and `false` all count as *no evidence*.

The browser driver attaches required collectors to each physical page visit;
preflight proving a collector on a scratch fixture is not a substitute for
capturing its per-page output. HAR and other recorded URLs omit userinfo,
queries and fragments before they reach evidence.

Enum: `har`, `a11y`, `dom`, `server_timing`, `ws`, `resource_metrics`,
`db_before_after`, `audit_actor`, `cleanup`, `downloads`, `api`,
`visual_baseline`.

Omitting `require_evidence` preserves v1 behaviour exactly: nothing is required.

## Visual baseline (pixel regression against an accepted baseline)

```json
{
  "require_evidence": ["visual_baseline"],
  "visual_baseline": {
    "source_identity": "one@fdfd5d45b",
    "store": "visual-baselines-admin-smoke",
    "viewport": "desktop"
  }
}
```

Compares every required page's screenshot against an **explicitly accepted**
baseline stored in the **durable Casein Artifact store** (a git-committed
artifact worktree written via the artifact MCP — never a local-only cache).
The stable baseline key is
`workflow (report.name) + page path + named viewport + accepted source identity`;
baselines accepted under a different workflow, viewport, or source identity are
never compared. Page paths in keys and stored metadata are **redacted to the
path only** — query strings, fragments and session material are dropped.

Rules (all fail closed):

* **Walks never bless pixels.** A walk only compares. Creating or updating a
  baseline is the explicit acceptance action:
  `node visual_baseline.mjs accept --run <outdir> --manifest <m.json> --source-identity <id>`
  (only PASS/PASS_SLOW pages — or pages BLOCKED solely on the missing baseline
  itself — are acceptable as baselines).
* **Exact geometry.** Width, height **and DPR** must match the accepted
  baseline exactly; any mismatch is a hard visual failure (`ASSERT_FAILED`),
  not a fuzzy comparison.
* **0.1% threshold.** Changed pixels **exceeding** 0.1% of the image fail;
  exactly 0.1% passes. Engine: pinned `pixelmatch` + `pngjs`
  (`scripts/ensure-preview-walk-deps.sh`).
* **Missing store / missing baseline / unreachable artifact MCP → `BLOCKED`**,
  at preflight (when visual evidence is required) and per page at walk time.
  Preflight proves the diff engine on a scratch fixture and checks accepted
  baselines read-only — it never touches product pages and never creates or
  updates a baseline.

Evidence persisted per page: candidate + accepted baseline + diff PNGs
(`shot-NN.png`, `visual-NN-baseline.png`, `visual-NN-diff.png`), changed-pixel
count and ratio, dimensions, DPR, the stable key, the accepted source identity,
and the collector version — in `results.json` and the report.

Store env (same trio the artifact MCP pairing already provides):
`CASEIN_ARTIFACT_MCP_URL`, `CASEIN_API_TOKEN`, `CASEIN_WORKSPACE_ID`.

## Named viewports (responsive coverage)

```json
{ "viewports": [
    { "name": "mobile",  "width": 390,  "height": 844 },
    { "name": "desktop", "width": 1280, "height": 720 }
  ] }
```

Pages walk every declared viewport unless they narrow it with
`pages[].viewports: ["desktop"]`. Names are stable labels used in the report and
in screenshot filenames. Keep `device_scale_factor` at `1` unless capturing for
visual diffing — screenshot pixels and DOM bounds only align at DPR 1. Omitting
`viewports` keeps the single default viewport (v1).

Preflight expands logical pages into physical viewport visits and reports both
counts. Any declared viewport makes viewport application a required capability;
the walk records requested and observed width, height and DPR per visit, and
blocks a visit when they do not match. The driver pools authenticated browser
contexts by DPR because Playwright fixes DPR at context creation; widths and
heights can still vary per visit without repeating login.

## Retries and flakiness (wired in the driver since batch 4)

```json
{ "retries": { "max_attempts": 2, "retry_on": ["TIMEOUT"], "record_flakiness": true } }
```

`max_attempts: 1` (the default) is v1 behaviour. Hard rules the manifest cannot
override:

* Only **read-only** pages retry. A page whose `steps` or `cleanup_steps`
  contain mutating actions is pinned to one attempt and **never replayed** —
  replaying a half-applied mutation manufactures fixtures and corrupts the
  evidence the walk exists to collect.
* Only **`TIMEOUT` and `RUNTIME_ERROR`** are honored. Other statuses listed in
  `retry_on` are dropped (and recorded as dropped): retrying `ASSERT_FAILED`
  hides defects, `BOUNCED` hides access regressions, `BLOCKED` hides missing
  evidence.
* Every attempt's status and duration is recorded
  (`results.json → pages[].flakiness.attempts`); attempts that disagree mark
  the page **⚑ FLAKY** in the report even when the final attempt passes —
  absorbed timeouts are still observations. `record_flakiness: false` opts out
  of the report note (the retry bounds still apply).

## API-request and download evidence (batch 4)

```json
{ "require_evidence": ["api", "downloads"] }
```

With `api` required, every XHR/fetch response the page issues is captured —
**sanitized URL (origin+path only, query dropped), method, status, timing** —
into `results.json → pages[].api` and the report's Browser column (≥400s
listed). No request/response bodies, ever. A page that issues no API traffic
yields `api: null`, which fails closed (BLOCKED) when the evidence is required.

With `downloads` required, `page.download` events are recorded (suggested
filename + sanitized source URL; never file contents). Trigger the download via
gated `steps` (e.g. clicking an export button).

## Cleanup / finally evidence for gated mutations (batch 4)

```json
{
  "pages": [{
    "name": "Create pen",
    "path": "/pens/new",
    "steps": [{ "action": "fill", "selector": "#name", "text": "walk-fixture" },
              { "action": "click", "selector": "#save", "event": "save" }],
    "cleanup_steps": [{ "action": "click", "selector": "[data-role=delete-walk-fixture]", "event": "delete" }],
    "require_evidence": ["cleanup"]
  }]
}
```

`cleanup_steps` run **after** the page's steps, screenshot, and evidence
capture, regardless of the page's outcome — teardown for the fixtures the gated
steps created. They pass through the same interactions gate
(`safety.allow_interactions` + non-prod `env_check`). A cleanup step that ran
and failed turns the page `ASSERT_FAILED` (fixtures may be left behind);
`require_evidence: ["cleanup"]` additionally BLOCKS the page when cleanup never
ran at all. Cleanup evidence (`pages[].cleanup`) records each step's status.

## Schema ⟷ driver drift policy

The schema must describe what the driver actually reads. `selftest.mjs` asserts
this contract, because drift is a real defect in both directions:

* `login.steps`, `login.budget_ms`, `page.asset` were **driver/tooling features
  missing from the schema** — product manifests that worked failed validation.
* `login.form` is **inert**: the driver never reads it. It is retained as
  `deprecated` so v1 manifests validate, and must be migrated to `login.steps`.
* `login.path`/`login.lands_on` are required for every kind **except `"none"`**
  (a public walk has no login route to assert).

## Preflight (`--preflight-only`)

Answers *"can this walk run, and will its evidence mean anything?"* **without
touching product data**. Preflight performs no product mutations — checks are
reads, probes, or capability tests against a scratch page — and the JSON matrix
asserts `mutationsPerformed: 0`.

```bash
node playwright_walk.mjs --manifest m.json --base http://127.0.0.1:PORT --preflight-only
node playwright_walk.mjs --manifest m.json --base … --preflight-only --json > readiness.json
node playwright_walk.mjs --manifest m.json --base … --health-url http://127.0.0.1:PORT/health --preflight-only
```

### Presweep health attestation (batch 4)

`--health-url <url>` (or `WALK_HEALTH_URL`) points at a **GET-only** deployment
endpoint. The identity row then attests the **exact environment string and full
40-char revision** parsed from the response (fields: `environment`/`env`/
`mix_env` + `revision`/`git_sha`/`sha`/`commit`). A short sha, a version label,
or non-JSON is refused with a named reason — an identity a regression can't be
pinned to is not attested. URLs in the matrix are sanitized (query dropped).

To **verify** (not merely record) the deployment, supply the operator's
expectations — the exact invocation:

```bash
node playwright_walk.mjs --manifest m.json --base http://127.0.0.1:PORT \
  --preflight-only \
  --health-url http://127.0.0.1:PORT/health \
  --expect-environment dev \
  --expect-revision 0123456789abcdef0123456789abcdef01234567
# or via env: WALK_EXPECT_ENVIRONMENT=dev WALK_EXPECT_REVISION=<40-char sha>
```

With either expectation supplied the check **fails closed**: exact string
equality for the environment, full 40-char hex equality (case-insensitive) for
the revision, and **BLOCKED (exit 2)** for any mismatch, a missing/unreachable
health URL, an unparseable deployed identity, or a malformed expectation (a
short expected sha is refused before any network I/O). Health traffic remains
GET-only in both modes.

Batch 4 also made preflight's probes REAL instead of configuration nods:

* **Tidewave** — an actual MCP initialize round-trip (read-only RPC), not
  "url is set". Required-but-unreachable → **BLOCKED**.
* **Preview cookie/storage** — a cookie + localStorage round-trip in a scratch
  browser context, proving the session-injection mechanics cookie login relies
  on. No product page involved.
* **Artifact store** — a read-only `artifact_list` round-trip with the
  env-provided store. Required-but-unavailable → **BLOCKED**.
* **Collector probe** — `--preflight-only` now runs the scratch collector probe
  (HAR/DOM/Server-Timing/ws/a11y/resource-metrics/visual/api/downloads) so
  required evidence is PROVEN, not assumed. Scratch fixtures only: preflight
  still never navigates a product page, never mutates, never touches a
  baseline.
* **Required collector gaps are BLOCKED (exit 2)** — a manifest that requires
  evidence preflight cannot prove no longer degrades to exit 1; running anyway
  would produce a report that silently lacks promised evidence.
* Credentials are demanded only for the manifests **selected on the command
  line**, never for other walks that happen to live in the repo.

### Login failure always leaves evidence (batch 4)

When login fails (bad selector, wrong credentials, gate blocked, cookie mint
failed), the driver no longer dies with a bare stderr line: it writes the
readiness **matrix** (`preflight.json`/`.txt`), a **screenshot** of where the
browser actually was (`login-failure.png`), **results.json** with every page
`BLOCKED` (`login failed: …`), and the **report.html** — then exits 2. Failure
messages never contain credential values.

### Exit codes

| Code | Verdict | Meaning |
|------|---------|---------|
| `0` | `READY` | Everything required and optional is present |
| `1` | `DEGRADED` | Required present, **optional** evidence missing — read-only walks may proceed; affected pages report `BLOCKED`, never a false `PASS` |
| `2` | `BLOCKED` | A **required** capability is missing, or an explicit blocker (e.g. disk full). Do not run |
| `3` | `UNSAFE` | Target looks production-like, or a mutating walk was requested where mutation is prohibited. Never run |

Severity is strictly ordered: **UNSAFE > BLOCKED > DEGRADED > READY**, so a
prod-looking target can never be downgraded to "just missing evidence". A
mutating walk additionally requires an affirmatively safe environment — an
*unproven* env (no `MIX_ENV`) is `UNSAFE` for mutation, never assumed safe.

### Matrix categories

Required: schema/manifests, environment safety, role credentials, app health &
assets, Chromium/playwright-core, screenshot collector, disk space.
Optional: deployed/source/workflow identity, Preview MCP & cookie injection,
Tidewave/logs/correlation/LiveView, HAR, WebSocket, DOM, accessibility,
viewport, visual baseline, resource metrics, API requests, downloads, DB read,
audit actor, artifact publishing/durable URL, fixture cleanup, leaked sessions.

"Optional" describes the category, not required evidence: any collector a
selected manifest lists in `require_evidence` that cannot be proven is
**BLOCKED (exit 2)**, not DEGRADED.

`SKIP` (not applicable — e.g. no roles configured) never worsens the verdict.

### Secret hygiene

Credential checks report **resolution only**: `set` / `unset` and which env
prefix it came from. Never the value, never a prefix of it, and never its
length — a length leaks entropy for short secrets. `redact/1` is the single
funnel and is fixture-tested to expose no `length` key.

## Collector batch 1: HAR, DOM, Server-Timing

Real collectors, proved by preflight rather than merely declared:

* **HAR** (`attachHar`) — accumulates from response events (Playwright's own
  `recordHar` only writes at context close, too late for per-page evidence).
  Captures url/method/status/resourceType/timing. **Bodies are deliberately not
  captured** — walk reports are shareable and bodies routinely carry PII and
  session material.
* **Server-Timing** (`collectServerTiming`) — parsed from the main document
  response header. An absent header yields `null`, i.e. honest "no evidence",
  not an empty object that would read as "collected, nothing interesting".
* **DOM snapshot** (`collectDomSnapshot`) — trimmed, sanitized serialized DOM.
  Input `value=` attributes and the CSRF meta/token are redacted before the
  snapshot ever reaches an artifact.

Contract for every collector: return evidence or `null`, **never throw into the
walk** (a collector defect must not fail an otherwise-passing page), and perform
no mutation. Turning "required but `null`" into `BLOCKED` is `evidenceGuard`'s
job, so fail-closed behaviour lives in exactly one place.

## Payload pack tool

The driver body ships gzip+base64 sharded across `playwright_walk_payload.pl*`.
`payload_pack.mjs` is the committed, **deterministic** unpack/repack tool
(previously the generator lived in `/tmp` and was lost):

```bash
node payload_pack.mjs unpack --out /tmp/driver.mjs
node payload_pack.mjs repack /tmp/driver.mjs
node payload_pack.mjs verify     # selftest calls this
```

Determinism is explicit: gzip level 9, `mtime=0`, and the OS byte normalised to
`0xFF`, so identical source always yields byte-identical shards and a rebuild is
never a spurious diff. `verify` asserts the committed shards both decode and
repack identically.

### `--preflight-only` CLI

```bash
node playwright_walk.mjs --manifest a.json --manifest b.json --base URL --preflight-only
node playwright_walk.mjs --manifest a.json --base URL --out ./run --preflight-only --json
```

Loads **every** selected manifest and emits ONE merged matrix: role prefixes,
required evidence and mutation intent fan in across all of them, so a sweep is
assessed as the sweep it is. `--out` is optional here (matrix goes to stdout);
when given, `preflight.json` and `preflight.txt` are written there. `--json`
switches stdout to the machine matrix.

**No-navigation is structural, not a promise.** The driver branches into
preflight *before* `chromium.launch` and before the walk loop, so nothing below
it can run. The only network preflight performs is a single `GET` of `--base`
for health — never a manifest page path, never a non-GET. Both properties are
asserted: a recording-fetch fixture pins request count/method/URL, and a
selftest reads the packed driver to confirm the preflight branch precedes the
browser launch (so a bad repack that drops the wiring fails the suite).
