# Walk manifest schema

A walk manifest is the **app-owned contract** for a UI smoke walk (default
read-only; optional gated interactions).

| Layer | Owns | Lives in |
|-------|------|----------|
| **Product** | paths, login, safety, runtime probes, page steps | target repo `.devide/preview-walk.json` |
| **DevIDE** | drivers, skill, this schema, fictional example | `.claude/skills/preview-ui-walk/` |

Machine-readable schema: [`preview-walk.schema.json`](./preview-walk.schema.json) (JSON Schema draft-07).
Shape example (fictional): [`authed-admin-example.json`](./authed-admin-example.json).

**Do not** check product-specific manifests into the DevIDE skill tree.

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
| `wait_for` / `wait_for_selector` | no | CSS selector |
| `assert_selector` / `assert_text` / `assert_url` | no | always allowed |
| `settle` | no | fixed sleep |
| `click` / `fill` / `type` / `press` / `select` / `check` / `hover` | **yes** | needs `safety.allow_interactions: true` + non-prod `env_check` |

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

Override Tidewave URL with `DEVIDE_TIDEWAVE_MCP_URL` or `--tidewave-url`.

Safety for runtime:

- Dev / preview-env only — never prod Tidewave
- SQL: `SELECT` only (driver rejects multi-statement / write keywords)
- Probes: soft reject of `Repo.insert` / `File.write` / `System.cmd` patterns
- Artifact: assign **keys** + small derived facts — not full socket assigns (PII)
- Email-like field values redacted as `[redacted-email]`

### Host hints (prefer launch env)

- **`workspace`** — `~/.devide/agent-mcp/<name>/env.sh`; omit from product files when the agent already has workspace context.
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
# example with check-jsonschema if installed
check-jsonschema --schemafile references/preview-walk.schema.json \
  /path/to/app/.devide/preview-walk.json
```

Or any draft-07 validator. Drivers should fail closed on schema-invalid manifests once validation is wired into the skill entrypoint.
