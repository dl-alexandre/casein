# Walk manifest schema

A walk manifest is the **app-owned contract** for a read-only UI smoke walk.

| Layer | Owns | Lives in |
|-------|------|----------|
| **Product** | paths, login, safety, runtime probes | target repo `.devide/preview-walk.json` |
| **DevIDE** | drivers, skill, this schema, fictional example | `.claude/skills/preview-ui-walk/` |

Machine-readable schema: [`preview-walk.schema.json`](./preview-walk.schema.json) (JSON Schema draft-07).
Shape example (fictional): [`authed-admin-example.json`](./authed-admin-example.json).

**Do not** check product-specific manifests into the DevIDE skill tree.

## Layers in one file

```text
┌──────────────────────────────────────────────────────────┐
│ login + pages + report     MACHINE (drivers enforce)     │
│ safety.*                   AGENT POLICY (preflight/report)│
│ runtime.*                  SERVER EVIDENCE (Tidewave)    │
│ workspace / app_surface    HOST HINTS (prefer env)       │
│ _note / note / role_gated  ANNOTATIONS (ignored)         │
└──────────────────────────────────────────────────────────┘
```

Browser baseline (today): screenshot, load ms, console/network counts, `lands_on`, recording.
Server slice (declared now; drivers collect when Tidewave is up): logs, allowlisted `project_eval` probes, optional SELECT-only SQL, LiveView assign **keys** (not full assigns).

If Tidewave is unreachable: **still walk the browser path**, mark runtime as `skipped: tidewave_unavailable` — never pretend the evidence packet is complete.

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
      "budget_ms": 8000
    }
  ],
  "safety": {
    "read_only": true,
    "env_check": ["APP_API_URL", "AUTH_API_URL"],
    "deny_events": ["delete", "confirm_delete", "save"]
  },
  "runtime": {
    "tidewave": true,
    "log_levels": ["error", "warning"],
    "probes": [
      { "name": "admin_role", "eval": "… small read-only Elixir …", "expect": "ok" }
    ],
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
- **`pages[].budget_ms`** — load budget.
- **`report.name`** — artifact slug.
- **`strict_errors` / `noise_patterns`** — CSP noise filter controls (Playwright).

### Agent policy

- **`safety.read_only`** — always `true` in v1.
- **`safety.env_check`** — keys for prod-write risk; surface in the report strip; agents must not click if prod.
- **`safety.deny_events`** — never fire these (drivers currently never click; skill must honor).

### Runtime / Tidewave (evidence packet)

Collection status in `playwright_walk.mjs` + `runtime_evidence.mjs`:

1. **Tidewave availability** + env safety strip — **wired**
2. **Per-page `get_logs` delta** for `log_levels` (default `error`) — **wired**
   (page FAILs if *new* error lines since previous page &gt; 0; not the cumulative tail size)
3. Walk-level **`probes`** (`project_eval`, allowlisted only) — schema only
4. **`per_page` SQL** (SELECT-only, capped rows) + LiveView assign keys — schema only

Override Tidewave URL with `DEVIDE_TIDEWAVE_MCP_URL` or `--tidewave-url`.

Safety for runtime:

- Dev / preview-env only — never prod Tidewave
- SQL: `SELECT` only (schema enforces prefix)
- No free-form eval outside `probes`
- Artifact: assign **keys** + small derived facts — not full socket assigns (PII)

### Host hints (prefer launch env)

- **`workspace`** — `~/.devide/agent-mcp/<name>/env.sh`; omit from product files when the agent already has workspace context.
- **`app_surface`** — preview surface name for `walk.py` only.

## Report shape (target)

Per page:

```text
Dashboard  PASS  3120ms
  browser:  console=0/0 network=0/0 lands_on=/admin  HTTP 200
  tidewave: error_logs=0  assign_keys=[current_user, cards, …]
  probes:   admin_role=ok
```

Top strip: Tidewave yes/no + MCP URL, app cwd/SHA, `env_check` results, walk-level server log delta.
`actionable/raw` console counts remain for CSP noise transparency.

## Validation

```bash
# example with check-jsonschema if installed
check-jsonschema --schemafile references/preview-walk.schema.json \
  /path/to/app/.devide/preview-walk.json
```

Or any draft-07 validator. Drivers should fail closed on schema-invalid manifests once validation is wired into the skill entrypoint.
