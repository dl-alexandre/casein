# Walk manifest schema

A walk manifest describes ONE app's read-only smoke walk. It lives in the target
repo at `.devide/preview-walk.json` (the app owns it). The `preview-ui-walk` skill
reads it and drives the preview accordingly.

```jsonc
{
  "workspace": "dalexandre-reports",   // agent-mcp env.sh dir name → scoped MCP + token
  "app_surface": "app",                // preview_surfaces name to reuse (usually "app")

  "login": {
    "type": "session_inject",          // session_inject | click | none
    "path": "/auth/superadmin/mock",   // dev bypass route that sets the session
    "params": { "email": "you@example.com", "role": "superadmin" },
    "lands_on": "/superadmin"          // expected post-login path (sanity check)
  },

  "pages": [
    {
      "name": "Dashboard",
      "path": "/superadmin",
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
- **login.type** — `session_inject` (navigate a dev bypass route, preferred),
  `click` (drive the real logo/login UI — only if no bypass), or `none`.
- **pages[].budget_ms** — generous; these apps often lack `assign_async`, so first
  render can be slow and a blank dead-render precedes the WS connect.
- **safety.deny_events** — the skill must never trigger these; they mutate and may
  route to prod APIs. Read-only nav/screenshot only.
- Keep the manifest app-truth: derive it from the app's router + existing smoke
  harness, not guesses.
