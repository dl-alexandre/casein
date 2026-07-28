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

Enum: `har`, `a11y`, `dom`, `server_timing`, `ws`, `resource_metrics`,
`db_before_after`, `audit_actor`, `cleanup`, `downloads`, `api`,
`visual_baseline`.

Omitting `require_evidence` preserves v1 behaviour exactly: nothing is required.

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

## Retries and flakiness

```json
{ "retries": { "max_attempts": 2, "retry_on": ["TIMEOUT"], "record_flakiness": true } }
```

`max_attempts: 1` (the default) is v1 behaviour. `retry_on` is deliberately
opt-in per status: retrying a genuine `ASSERT_FAILED` hides defects, so nothing
is retried unless you name it. With `record_flakiness`, a page whose attempts
disagree is marked flaky in the report while still reporting its final class.

## Schema ⟷ driver drift policy

The schema must describe what the driver actually reads. `selftest.mjs` asserts
this contract, because drift is a real defect in both directions:

* `login.steps`, `login.budget_ms`, `page.asset` were **driver/tooling features
  missing from the schema** — product manifests that worked failed validation.
* `login.form` is **inert**: the driver never reads it. It is retained as
  `deprecated` so v1 manifests validate, and must be migrated to `login.steps`.
* `login.path`/`login.lands_on` are required for every kind **except `"none"`**
  (a public walk has no login route to assert).
