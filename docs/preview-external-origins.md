# External-origin previews (`preview_open mode=external`)

Every other preview lane resolves its URL **from the workspace**: a manager
domain, a declared port, a terminal-detected dev server. That is what makes the
workspace the security boundary — an agent can only point a browser at
something the workspace already owns.

A sibling product on its own host has no workspace surface here, so it is
unreachable through those lanes. `mode: "external"` is the deliberate, narrow
exception: an operator names the origins preview may open, and nothing else
passes.

## Enabling it

Off by default. Nothing an agent passes at call time widens the allowlist.

```bash
# /etc/devbox-manager.env (or the deployment's env file), then restart Casein
CASEIN_PREVIEW_EXTERNAL_ORIGINS=https://dev.example.com,https://staging.example.test
```

A single workspace can be granted its own origins through operator-managed
workspace metadata instead:

```elixir
%{metadata: %{"external_preview_origins" => ["https://dev.example.com"]}}
```

The effective allowlist is the union of the two. With both empty the lane is
off and every call is refused with `external_previews_not_configured`, naming
the env var.

## Matching rules

Same semantics as every other preview allowlist (`PreviewCtl.Origin`):

| Allowlisted | Matches | Does **not** match |
|---|---|---|
| `https://example.com` | `https://example.com`, `https://dev.example.com` | `http://example.com` (scheme), `https://example.com:8443` (port), `https://example.com.evil.test` (lookalike) |

Scheme and port are exact; host is exact-or-subdomain. A bare host
(`dev.example.com`) is read as `https://`.

## Using it

```json
{
  "name": "preview_open",
  "arguments": {
    "mode": "external",
    "url": "https://dev.example.com/login",
    "tmux_session": "casein_ws_agent"
  }
}
```

The response carries `preview_source: {"via": "external"}` plus the usual
`session_id` / `pane_id`. From there it is an ordinary preview session:
`preview_observe_live`, `preview_elements`, `preview_click`, `preview_type`,
`preview_screenshot`, `preview_report_errors`, `preview_record_start` /
`preview_record_stop`. `preview_navigate` stays inside the opened origin.

Refusals never open a pane:

| Error | Meaning |
|---|---|
| `external_previews_not_configured` | Allowlist empty — operator must opt in |
| `external_origin_not_allowed` | Origin not allowlisted; the error lists what is |
| `invalid_external_url` | Missing `url`, or not an absolute http(s) URL |

## Hosts without a tmux pane (native Windows)

Native Windows runs preview as a pure browser-control session and creates no
tmux pane (`CASEIN_WINDOWS_PREVIEW_CONTROL_ONLY`). The external lane is
supported there: the allowlisted origin is opened directly on the control
runtime, and the response reports it honestly rather than implying a pane —
`control_only: true`, `pane_id: null`, `preview_open_state: "agent_only"`,
`preview_source: "external"`.

The same reachability preflight runs first, and the same allowlist applies —
a host with no pane is *more* dependent on fail-closed policy, not less, since
there is no visible surface in which a wrong origin would be noticed.
Observe/click/type/press/screenshot/navigate all work against that session.

## Why an allowlist and not a proxy

The browser is pointed at the caller's URL **verbatim**. That is the whole
point, and it is why this lane is not built on the preview proxy.

Serving another app under a path prefix (`/preview-proxy/<ws>/<port>/…`)
reconnect-loops **every** LiveView app: the LiveView join `url` cannot match
the app's own router, the join is refused as `unauthorized`, and the client
falls back to an uncapped full-page reload every 1-2 seconds, forever — and
only inside an iframe, which makes it look like a preview bug. Keeping the real
origin keeps the app's router, cookies, CSRF token, and `wss://` join all
agreeing about who they are talking to.

## Authenticating without driving a login form

`preview_open` accepts `default_headers`, applied to preview fetches **and** to
the Playwright browser context, including WebSocket upgrade requests. For a
forward-auth deployment that is a complete session bootstrap:

```json
{
  "mode": "external",
  "url": "https://dev.example.com/",
  "default_headers": {"X-Auth-Request-Email": "qa-user@example.test"}
}
```

Pair it with `storage_profile: "profile"` + `storage_profile_name` to keep a
reusable logged-in browser state per workspace and origin, or
`isolation_key` to keep two walks' auth state apart on the same origin.
`preview_set_cookies` injects cookies into an already-open session.

## Proving a target works

`test/casein/agents/preview_tools/external_origin_e2e_test.exs` drives the real
stack (allowlist → pane registration → `:playwright` adapter → Chromium) and
asserts the browser stays on the target's own origin. It is excluded by default
and skipped unless a target is named:

```bash
CASEIN_TEST_EXTERNAL_PREVIEW_URL=https://dev.example.com/login \
  mix test --only preview_e2e test/casein/agents/preview_tools/external_origin_e2e_test.exs
```

Run that first when a walk against an external app misbehaves: it separates
"Casein cannot reach or hold the origin" from "the app itself is rejecting the
session", which otherwise look identical from inside a walk.
