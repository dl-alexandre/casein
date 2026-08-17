# Previews subsystem

> Opens, controls, observes, and embeds workspace-scoped browser previews — for both human operators and MCP agents — within the workspace-origin trust boundary.

This is the implementation reference for the preview stack. For the agent-facing
MCP tool surface and operator setup (Playwright install, env vars, storage
profiles, smoke tests), see the authoritative [`../preview_mcp.md`](../preview_mcp.md);
this doc does not duplicate it.

## Responsibility

A *preview* is a durable, workspace-scoped surface or URL
(`Casein.Previews.Preview`). A *control session* is one short-lived browser/runtime
attached to a preview (`Casein.Previews.ControlSession`). The subsystem:

- discovers and resolves named surfaces (`app`, `tidewave`, `api`, localhost
  ports) from manager metadata and terminal output;
- opens previews and control sessions, deduplicating by `workspace_id` +
  normalized surface key;
- drives browser actions (navigate/click/type/press/screenshot/observe/storage)
  through a swappable adapter and records every action + observation in Postgres
  for audit;
- broadcasts opens and observations to connected LiveView viewers so panes
  follow agent-driven browsing live;
- reverse-proxies frame-blocked loopback dev servers so they stay embeddable in
  an iframe.

Origin/port enforcement lives in `Casein.Previews.Url` and
`Casein.Previews.WorkspaceContext`; the generic browser primitives live in the
sibling `PreviewCtl.*` boundary (out of these paths), reached through Casein
facades.

## Module map

| Module | File | Role |
|---|---|---|
| `Casein.PreviewControl` | `lib/casein/preview_control.ex` | Agent-first control context: opens sessions, enforces origin boundary, dispatches actions via `PreviewCtl.Session`, persists actions/observations, audits, broadcasts. |
| `Casein.Previews` | `lib/casein/previews.ex` (sibling of paths) | Preview Broker context: `open/2`, `find_or_open/2`, `open_surface/3`; computes `trusted` flag and persists `Preview` rows. |
| `Casein.Previews.Preview` | `lib/casein/previews/preview.ex` | Ecto schema for a preview (url/title/mode/status/trusted/workspace/session/pane/metadata); validates URL against allowed origins. |
| `Casein.Previews.ControlSession` | `lib/casein/previews/control_session.ex` | Ecto schema for one browser runtime attached to a preview (adapter, current_url, storage profile, status). |
| `Casein.Previews.ControlAction` | `lib/casein/previews/control_action.ex` | Ecto schema for one audited control action (params/result/status/actor). |
| `Casein.Previews.ControlObservation` | `lib/casein/previews/control_observation.ex` | Ecto schema for a captured observation (kind: url/dom_summary/console_errors/network_errors/storage/screenshot). |
| `Casein.Previews.Surface` | `lib/casein/previews/surface.ex` | Struct for a named surface (name/url/title/port/source). |
| `Casein.Previews.SurfaceResolver` | `lib/casein/previews/surface_resolver.ex` | Resolves named surfaces from manager metadata, host, and terminal candidates; `resolve/1`, `get/2`, `primary_surface/1`. |
| `Casein.Previews.Identity` | `lib/casein/previews/identity.ex` | `surface_key/1` / `url_key/1` — stable dedupe keys (path/query ignored). |
| `Casein.Previews.Url` | `lib/casein/previews/url.ex` | Origin allowlist + `port_allowed?/2` / `valid_preview_url?/2`; delegates loopback checks to `PreviewCtl.Origin`. |
| `Casein.Previews.WorkspaceContext` | `lib/casein/previews/workspace_context.ex` | `prepare/1` enriches a workspace with detected ports; `validate_port/2`, `localhost_url/2`. |
| `Casein.Previews.Detector` | `lib/casein/previews/detector.ex` | Parses localhost URLs / host:port hints from terminal scrollback. |
| `Casein.Previews.SocketDetector` | `lib/casein/previews/socket_detector.ex` | Detects dev-server ports from listening TCP sockets inside the workspace. |
| `Casein.Previews.TerminalOutput` | `lib/casein/previews/terminal_output.ex` | Captures recent tmux scrollback for port detection. |
| `Casein.Previews.TidewaveProbe` | `lib/casein/previews/tidewave_probe.ex` | Fingerprints listening localhost ports as Tidewave endpoints. |
| `Casein.Previews.EnvPorts` / `EnvRegistry` | `lib/casein/previews/env_ports.ex`, `env_registry.ex` | Ephemeral preview-environment port helpers / instance registry. |
| `Casein.Previews.Artifacts` | `lib/casein/previews/artifacts.ex` | `store_png!/3` persists screenshots to a servable path; prunes to `:preview_max_artifacts`. |
| `Casein.Previews.Commands` | `lib/casein/previews/commands.ex` | Narrow audited command surface for terminals/agents (no arbitrary URLs). |
| `Casein.PreviewControl` | `lib/casein/preview_control.ex` | Host facade for controllable previews (`open_session`, `navigate`, `observe`, `click`/`type`/`press`, `screenshot`, storage, `close_session`). Selects the adapter from the `:preview_control_adapter` config (`:memory` → `PreviewCtl.Test.FakeAdapter`, `:playwright` → `PreviewCtl.Playwright.Adapter`, resolved by `PreviewCtl.Session.adapter_for/1`) and drives `PreviewCtl.*` directly. |
| `Casein.PreviewControl.Registry` | `lib/casein/preview_control/registry.ex` | `defdelegate`s into `PreviewCtl.Registry` (in-memory, instance-local session registry). |
| `CaseinWeb.PreviewProxy.Rewrite` | `lib/casein_web/preview_proxy/rewrite.ex` | Pure header/body transforms for the proxy: drops frame-blocking headers, injects `<base href>`, rewrites root-relative assets, keeps Phoenix LiveView fallback endpoints under the proxy prefix, and (HMR) injects the import map + WebSocket-reroute shim and rewrites loopback origins. |
| `CaseinWeb.PreviewProxy.WebSocketBridge` | `lib/casein_web/preview_proxy/web_socket_bridge.ex` | `WebSock` handler that tunnels a preview WebSocket to the workspace loopback dev server via `Mint.WebSocket` (HMR / LiveReload). Gated by `:preview_proxy_hmr`. |

The HTTP edges (`CaseinWeb.PreviewProxyController`, `PreviewArtifactController`,
`PreviewPaneController`) and `Casein.PreviewPanes` live outside these paths but
are part of the data flow below.

## Data flow / lifecycle

**Open (`Casein.PreviewControl.open_session/3`)**

1. `WorkspaceContext.prepare/1` enriches the workspace with terminal/socket-detected ports.
2. `fetch_surface/2` → `SurfaceResolver.get/2` (with an `app`→`primary_surface/1` fallback).
3. `Previews.open_surface/3` finds-or-opens the `Preview` row (dedup keyed by `surface_key`).
4. `find_or_persist_session/4` either reuses an open `ControlSession` for the
   preview (unless `new_control_session: true`) or persists a new one and starts
   its runtime via `PreviewCtl.Runtime.start/3`. Emits `preview.session_opened`
   audit event.
5. Records an initial `"url"` observation and broadcasts `{:preview_opened, ...}`
   on `"preview:<workspace_id>"`.

**Action (navigate/click/type/press/screenshot/observe/observe_live/storage)**

1. `ensure_local_runtime/1` re-hydrates the runtime on the current instance if
   `PreviewCtl.Registry` (instance-local) has no entry — required because the box
   runs several instances behind the `:4000` loopback.
2. `PreviewCtl.Session.<action>/n` runs the adapter call (origin-guarded).
3. `sync_session_url/3` updates `current_url` only when it changed.
4. `record_action_and_observation/5` inserts one `ControlAction` + fan-out
   `ControlObservation` rows (url, dom_summary, console_errors, network_errors,
   storage, screenshot) in a transaction, then records a `PreviewActivity` entry.
5. `broadcast_observation/2` pushes `{:preview_observation, ...}` to LiveView
   viewers (skipping minimal type/press echoes).

**Embed / proxy.** A registered tmux preview pane (via `POST /api/preview/panes`)
gets an iframe overlay. For frame-blocked loopback apps, the iframe targets
`/preview-proxy/:workspace_id/:port/*path` (`PreviewProxyController`): host is
hard-pinned to `127.0.0.1`, port validated by `Url.port_allowed?/2`, and the
request is forwarded with method, cookies, headers, and body intact. Responses
run through `PreviewProxy.Rewrite` (strip `x-frame-options`/CSP/length/encoding,
preserve repeated `set-cookie`, inject `<base>`, rewrite root-relative HTML/CSS
assets, and rewrite standard Phoenix socket endpoint literals so LiveView
long-poll fallback stays inside the proxy). When `:preview_proxy_hmr` is enabled
(off by default), the controller also tunnels WebSocket `Upgrade`s to the dev
server (`PreviewProxy.WebSocketBridge`, via `Mint.WebSocket`; owner/SSRF-gated,
per-workspace capped) and injects an import map + WebSocket-reroute shim +
loopback-origin rewriting so Vite/webpack HMR and Phoenix LiveReload survive
proxying; loopback previews are also routed through the proxy on navigate while
the flag is on. Screenshots are served from `/preview-artifacts/...` via
`Artifacts`.

**Close.** `close_session/1` (one runtime) or `close_sessions_for_preview/1`
(all open sessions for a preview, batched DB flip + runtime teardown).

## Public surface

Called by `Casein.Agents.PreviewTools` (MCP), `Casein.Previews.Commands`, and
LiveView preview panels:

- `Casein.PreviewControl.open_session/3`, `open_localhost_session/3`, `open_for_preview/3`
- `observe/1`, `observe_live/1`, `navigate/3`, `click/2`, `type/4`, `press/2`
- `go_back/2`, `go_forward/2`, `reload/2`, `screenshot/2`
- `get_storage/1`, `clear_storage/1`
- `close_session/1`, `close_sessions_for_preview/1`
- `latest_observation/1`, `latest_screenshot/1`, `latest_errors/1`,
  `latest_observation_for_preview/1`, `get_open_session_for_preview/2`
- `Casein.Previews.open/2`, `find_or_open/2`, `open_surface/3`
- `Casein.Previews.SurfaceResolver.resolve/1`, `get/2`, `primary_surface/1`
- `Casein.Previews.Url.port_allowed?/2`, `valid_preview_url?/2`, `allowed_origins/1`

Configured adapter: `Application.get_env(:casein, :preview_control_adapter, :memory)`
(`:memory` | `:playwright`), resolved at boot into `:preview_ctl :adapter` — see
[`../preview_mcp.md`](../preview_mcp.md) "Adapter configuration".

## Invariants & gotchas

- **Origin allowlist is the boundary.** `Preview.changeset` rejects any URL not
  in `Url.allowed_origins/1` (loopback + manager-owned workspace domains). The
  proxy controller additionally pins the host to `127.0.0.1`. Agents never get
  arbitrary browser access.
- **`PreviewCtl.Registry` is in-memory and instance-local.** A session opened on
  instance A is not registered on B (or on A after restart). Every
  runtime-resolving op must go through `ensure_local_runtime/1`, which idempotently
  re-hydrates from the persisted `current_url` + storage profile. Skipping it
  returns `{:error, :not_found}` cross-instance.
- **`mode: :iframe` is legacy.** `Preview.changeset` normalizes `:iframe` → `:tab`;
  in-cockpit embedding is now done via the iframe-overlay/proxy path, not a stored
  iframe mode.
- **Surface dedupe ignores path/query.** `Identity.url_key/1` keys only on
  scheme/host/port, so route changes navigate within an existing preview rather
  than spawning a duplicate.
- **Storage profiles cross instances.** `:ephemeral` (default), `:workspace`, and
  `:profile` (requires `storage_profile_name`) persist Playwright storage state
  under `:preview_storage_root`/`.storage`; this is what lets re-hydration restore
  auth across instances.
- **Observation broadcast filters echoes.** `real_observation?/1` requires a
  url/dom_summary/artifact_path key so minimal type/press results don't blank the
  live panel.
- **Casein.*Adapter/*Bridge/*Registry are thin facades** over `PreviewCtl.*` kept
  for backward compatibility; new logic belongs in the `PreviewCtl` boundary.
- **Artifact pruning is best-effort** — a screenshot capture never fails because
  cleanup of older PNGs failed.
- **Own-origin `pv-*` router must pin `X-Forwarded-Proto: https`.**
  `scripts/preview-router.sh` listens plaintext on `:41080` behind the
  TLS-terminating manager Caddy. Caddy v2.11.1 `trusted_proxies` does **not**
  make `{scheme}` become `https`, so the generated Caddyfile sets
  `header_up X-Forwarded-Proto https` on both `forward_auth` hops and the pane
  `reverse_proxy`, and builds the login `rd=` from `https://` rather than
  `{scheme}`. Omitting that lets `Plug.SSL` 301 `/api/previews/authz` to itself
  (`ERR_TOO_MANY_REDIRECTS`). Guard: `scripts/test-preview-router.sh`.
- **Ephemeral preview envs are dual-bound (socket + loopback port).**
  `scripts/preview-env.sh` boots each env with `CASEIN_HTTP_SOCKET=<state>/sockets/<id>.sock`
  (the canonical front door — a pure function of the id, collision-free, dialed by
  `scripts/preview-router.sh` as `reverse_proxy unix//…`, mirroring the live
  `/run/casein/current.sock` model) **and** `CASEIN_PREVIEW_TIDEWAVE_PORT=<port>`.
  The port spins a second, loopback-only Bandit listener
  (`Casein.Application.preview_tidewave_listener/0`) serving the same endpoint, so
  the programmatic Tidewave MCP dial (`Casein.Agents.TidewaveMCP` →
  `http://127.0.0.1:<port>/tidewave/mcp`) and local tooling (screenshots, on-box
  browser) keep working — a unix socket can't serve those. Prod never sets the var,
  so the live supervision tree is unchanged. The port is still derived
  deterministically (`alloc_port` seeds at `cksum(id) % range`, then probes), so the
  100-slot range only matters for the Tidewave loopback, not the canonical address.

## See also

- [`../preview_mcp.md`](../preview_mcp.md) — authoritative MCP tool surface, adapter config, storage profiles, smoke tests, scoping plan.
- [`../architecture.md`](../architecture.md) — subsystem map, trust boundaries (Boundary 1: preview MCP), authority map.
- [`../terminal.md`](../terminal.md) — tmux/PTY substrate that hosts preview panes and emits the terminal output port detection reads.
- [`../glossary.md`](../glossary.md) — preview / control-session / surface terminology.
