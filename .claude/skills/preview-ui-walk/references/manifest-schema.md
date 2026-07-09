# Walk manifest schema

A walk manifest describes ONE app's read-only smoke walk. It lives in the target
repo at `.devide/preview-walk.json` (the app owns it). The `preview-ui-walk` skill
reads it and drives the preview accordingly.

```jsonc
{
  "workspace": "dalexandre-reports",   // agent-mcp env.sh dir name → scoped MCP + token
  "app_surface": "app",                // preview_surfaces name to reuse (usually "app")

  "login": {
    "type": "cookie",                  // cookie | session_inject | click | none
                                       // cookie = redirect login (most admin apps) → playwright_walk.mjs
                                       // session_inject = no-redirect bypass only → walk.py / preview MCP
    "path": "/auth/superadmin/mock",   // dev bypass route that sets the session cookie
    "params": { "email": "you@example.com", "role": "superadmin" },
    "lands_on": "/superadmin"          // expected post-login path (sanity check)
  },

  "pages": [
    {
      "name": "Dashboard",
      "path": "/superadmin",
      "lands_on": "/superadmin",       // expected landed path — a bounce to /login FAILS
      "budget_ms": 8000,               // PASS if loaded+rendered under this
      "role_gated": false,             // informational
      "note": "landing"
    }
    // …one per screen, in nav order
  ],

  "safety": {
    "read_only": true,                 // v1 is always true
    "env_check": ["ONE_API_URL", "ANIMAL_API_URL", "FEED_API_URL"],
    // ↑ if any is unset/points at prod, the app's writes hit prod → stay read-only.
    "deny_events": [                   // NEVER fire these phx events / clicks
      "trigger_migration", "send_email", "delete", "confirm_delete",
      "deactivate", "delete_photo", "delete_theme", "reset_token",
      "clear_issue", "request_refresh", "save"
    ]
  },

  "report": {
    "name": "superadmin-smoke",        // artifact slug
    "baseline": false                  // true → compare_snapshots vs prior run
  }
}
```

Field notes:
- **workspace** — used to `source ~/.devide/agent-mcp/<workspace>/env.sh` for the
  scoped `DEVIDE_PREVIEW_MCP_URL` + `DEV_IDE_API_TOKEN`.
- **login.type** — `session_inject` (navigate a dev bypass route via the preview
  MCP, preferred when there's no redirect); `cookie` (a redirect/cookie login the
  MCP can't follow — mint the cookie server-side and drive Chromium directly with
  `references/playwright_walk.mjs`; see SKILL.md "Auth reality"); `click` (drive the
  real logo/login UI — only if no bypass); or `none`.
- **pages[].lands_on** — expected landed path (defaults to `path`). Both drivers
  read the browser's *actual* final URL and FAIL the page if it doesn't match — a
  gated page that bounced to `/login` must never PASS on a 200 + screenshot alone
  (the "false green"). See `references/authed-admin-example.json` for the cookie shape.
- **pages[].budget_ms** — generous; these apps often lack `assign_async`, so first
  render can be slow and a blank dead-render precedes the WS connect.
- **Error noise (playwright_walk.mjs)** — by default CSP blocks of third-party
  badges (`shields.io`, GitHub badge SVGs), nested-iframe CSP
  (`ERR_BLOCKED_BY_CSP`), and nonce inline style/script noise do **not** fail a
  page. They still appear as raw counts; the report shows `actionable/raw`.
  Override with `strict_errors: true` (page or manifest) to fail on any
  console/network error, or extend filters via `noise_patterns: ["regex", …]`.
  Main-document HTTP ≥400 always fails.
- **safety.deny_events** — the skill must never trigger these; they mutate and may
  route to prod APIs. Read-only nav/screenshot only.
- Keep the manifest app-truth: derive it from the app's router + existing smoke
  harness, not guesses.
