# PreviewCtl

> A generic, in-repo browser/preview control library: origin guards, an ETS
> session registry, an adapter behaviour, and an optional Node Playwright
> bridge. It owns runtime control state only — never workspace allowlists,
> persistence, or human-iframe broadcasts.

## Responsibility

`PreviewCtl` is the standalone control library that drives a preview surface
(navigate, observe, click, type, press, screenshot, storage) behind a swappable
adapter. It is a boundary in the spirit of `TmuxCtl`: it provides generic
http(s) URL primitives and runtime session orchestration, and it stays
deliberately ignorant of the host application.

The host application (`DevIDE.PreviewControl`, in `lib/dev_ide/previews` and
`lib/dev_ide/preview_control*`) owns everything `PreviewCtl` does not:

- Ecto-persisted preview/control-session records, audit, and PubSub.
- Workspace surface discovery and the workspace URL allowlist
  (`DevIDE.Previews.Url`).
- Human-facing tmux preview panes and iframe-overlay broadcasts.

The DevIDE host drives `PreviewCtl.*` from the `DevIDE.PreviewControl`
(`lib/dev_ide/preview_control.ex`) facade, which selects an adapter via the
`:preview_control_adapter` config — `:memory` → `PreviewCtl.Test.FakeAdapter`,
`:playwright` → `PreviewCtl.Playwright.Adapter` (resolved by
`PreviewCtl.Session.adapter_for/1`). `DevIDE.PreviewControl.Registry`
`defdelegate`s into `PreviewCtl.Registry`.

This subsystem is distinct from `lib/dev_ide/previews`: that is the host
integration; this is the reusable control core.

## Module map

| Module | File | Role |
|--------|------|------|
| `PreviewCtl.Origin` | `lib/preview_ctl/origin.ex` | Generic http(s) URL primitives: loopback normalization, `http_url?/1`, `origin_of/1`, `within_origin?/3`, `resolve_against/2`, default dev-port origins. |
| `PreviewCtl.Registry` | `lib/preview_ctl/registry.ex` | GenServer-owned ETS table of live runtime entries; serialized writes, lock-free reads. |
| `PreviewCtl.Runtime` | `lib/preview_ctl/runtime.ex` | Adapter startup + registry wiring: resolves the adapter, builds the start payload and registry entry, applies default headers, decides session reuse. |
| `PreviewCtl.Session` | `lib/preview_ctl/session.ex` | Per-action orchestration: fetch entry, enforce origin/target guards, dispatch to the adapter, commit updated state/URL back to the registry. |
| `PreviewCtl.Adapter` | `lib/preview_ctl/adapter.ex` | Behaviour all preview-control adapters implement (start/navigate/observe/click/type/press/screenshot/storage/close). |
| `PreviewCtl.Playwright.Adapter` | `lib/preview_ctl/playwright/adapter.ex` | Production adapter: `Req`-based static HTTP observation plus optional Node Playwright for live DOM, interaction, storage, and screenshots. |
| `PreviewCtl.Playwright.Bridge` | `lib/preview_ctl/playwright/bridge.ex` | GenServer owning the long-lived Node helper port; newline-delimited JSON request/response, one command in flight at a time. |
| `PreviewCtl.Test.FakeAdapter` | `lib/preview_ctl/test/fake_adapter.ex` | In-memory DOM simulation adapter (the `:memory` adapter) for tests and browserless local/dev/prod. |

## Data flow / lifecycle

1. **Configure adapter (boot).** `DevIDE.Application.configure_preview_ctl!/0`
   copies `config :dev_ide, :preview_ctl` and maps the operator atom
   `:preview_control_adapter` (`:memory` | `:playwright`) to the resolved module
   under `config :preview_ctl, :adapter`. The Playwright script path maps from
   `:dev_ide :preview_playwright_script` to `:preview_ctl :playwright_script`.
   `PreviewCtl.Registry` and `PreviewCtl.Playwright.Bridge` are started in the
   DevIDE supervision tree (`lib/dev_ide/application.ex`).

2. **Start a session.** The host calls `PreviewCtl.Runtime.start/4` (or
   `ensure_registered/4`) with an integer `session_id`, an opaque `session`
   map (the host's Ecto struct/metadata), and a `preview` map. `Runtime`
   resolves the adapter module via `PreviewCtl.Session.adapter_for/1`, builds
   the start payload (`adapter_start_payload/2`: current url, allowed origins,
   default headers, storage profile/name/key/path), calls
   `adapter.start_session/1`, and stores the entry via `Registry.put/2`.

3. **Drive actions.** The host calls `PreviewCtl.Session.*` with the
   `session_id`: `navigate/2`, `observe/1`, `observe_live/1`, `click/2`,
   `type/4`, `press/2`, `go_back/1`, `go_forward/1`, `reload/1`,
   `screenshot/1`, `get_storage/1`, `clear_storage/1`. Each call fetches the
   registry entry, runs guards, dispatches to `entry.adapter_module`, then
   `commit_state/5` writes the new adapter state and resolved `current_url`
   back to the registry.

4. **Adapter execution (Playwright).** `PreviewCtl.Playwright.Adapter`:
   - `navigate`/`observe` do a redirect-disallowed `Req.get` against the URL
     with the session's default headers, then `summarize_html/2` (title,
     headings, links, `visible_text`, `byte_size`, `source_url` from
     `<base>`/canonical) and a `frame_blocked?` check on
     `X-Frame-Options`/CSP `frame-ancestors`.
   - `observe_live`, `click`, `type`, `press`, `screenshot`, `get_storage`,
     `clear_storage`, history, and `close` send a JSON action payload to
     `PreviewCtl.Playwright.Bridge.command/1`. If the bridge reports
     `:playwright_unavailable`, `observe_live`/`reload`/`screenshot` fall back
     to static HTTP observation; the other browser actions surface the error.

5. **Bridge port.** `Bridge` lazily spawns `node <script> --daemon` (resolved
   from `:preview_ctl :playwright_script`, searched in cwd then the priv dir of
   `:preview_ctl :priv_app`, default `:dev_ide`). It writes one JSON line per
   command, rejects concurrent commands with `:playwright_busy`, decodes the
   `{"ok": true|false, ...}` response line, and re-spawns the port on demand
   after an exit.

6. **Close.** `PreviewCtl.Session.close/1` calls `adapter.close/1` (which tells
   the bridge to close the browser context for that `browser_id`) and deletes
   the registry entry.

## Public surface

Functions/processes the host application calls:

- `PreviewCtl.Runtime.start/4`, `ensure_registered/4`, `with_default_headers/2`,
  `matches_reuse_opts?/2`, `entry/4`, `adapter_start_payload/2`.
- `PreviewCtl.Session.fetch/1`, `update_adapter_state/2`, `close/1`,
  `navigate/2`, `observe/1`, `observe_live/1`, `click/2`, `type/4`, `press/2`,
  `go_back/1`, `go_forward/1`, `reload/1`, `screenshot/1`, `get_storage/1`,
  `clear_storage/1`, `default_adapter/0`, `adapter_for/1`.
- `PreviewCtl.Origin.localhost_url?/1`, `normalize_localhost/1`,
  `trusted_embed?/2`, `http_url?/1`, `origin_of/1`, `within_origin?/3`,
  `resolve_against/2`, `localhost_origins/0`, `common_dev_ports/0`.
- `PreviewCtl.Registry.put/2`, `get/1`, `update/2`, `delete/1`, `clear/0`
  (registered process `PreviewCtl.Registry`).
- `PreviewCtl.Playwright.Bridge.command/1`, `script_path/0` (registered process
  `PreviewCtl.Playwright.Bridge`).
- `PreviewCtl.Adapter` — implement this behaviour to add an adapter.

## Invariants & gotchas

- **Adapter resolution is two-keyed.** `:preview_control_adapter` on `:dev_ide`
  is the operator atom; `:adapter` on `:preview_ctl` is the resolved module set
  at boot. `Session.default_adapter/0` falls back to
  `PreviewCtl.Test.FakeAdapter` when `:preview_ctl :adapter` is unset.
- **Origin allowlist is enforced only on `navigate`.** `Session.navigate/2`
  rejects URLs outside the entry's `allowed_origins` with
  `{:error, :origin_not_allowed}` (default allowlist is
  `Origin.localhost_origins/0` when none stored). Observe/click/etc. operate on
  the already-loaded page and do not re-check origin. The host is responsible
  for seeding `allowed_origins` in session metadata.
- **`session_id` is an integer.** `Registry` and most `Session`/`Runtime`
  functions guard on `is_integer(session_id)`.
- **Registry reads bypass the GenServer.** Reads hit the `:protected` ETS table
  directly; only `put`/`update`/`delete`/`clear` go through the owner. The table
  name is overridable via `:preview_ctl :registry_table`.
- **Bridge is single-flight.** Only one `command/1` runs at a time; a second
  concurrent call returns `{:error, :playwright_busy}`. The call timeout is
  60s (`@timeout`).
- **Graceful degradation, not failure.** Missing Node or helper script logs a
  warning and leaves the bridge port unstarted; Playwright-only actions then
  return `{:error, :playwright_unavailable}` and observe/screenshot/reload fall
  back to static HTTP. `redirect: false` means a 3xx becomes
  `{:error, {:redirect_blocked, status, location}}` rather than a follow — this
  is how forward-auth redirects are surfaced instead of chased.
- **Default headers are sanitized.** `Playwright.Adapter.normalize_headers/1`
  drops empty keys, CR/LF/`:` in keys, non-binary values, and CR/LF in values
  (header-injection guard); they are applied to both `Req` fetches and the
  Playwright payload.
- **Frame-block heuristic for embeddability.** `frame_blocked?` flags
  `X-Frame-Options: DENY|SAMEORIGIN` and any CSP `frame-ancestors` without a
  `*` wildcard so callers can fall back to a screenshot instead of an iframe.
- **`source_url` provenance.** Static observation reports the page's real origin
  from `<base href>` or a canonical `<link>` so a served snapshot can report the
  true site URL rather than the path it is served from.
- **`@moduledoc false` on facades.** The DevIDE-side facades in
  `lib/dev_ide/preview_control*` are out of this subsystem; do not edit them
  from here.

## See also

- [`../preview_mcp.md`](../preview_mcp.md) — the MCP JSON-RPC surface
  (`PreviewTools`) and the `DevIDE.PreviewControl` host layer that sits on top
  of this library, including adapter config keys, storage profiles, and
  default-headers env vars.
- [`../architecture.md`](../architecture.md) — overall DevIDE subsystem map and
  first principles.
