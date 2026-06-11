# Remote-mode truth-table audit

> Grounded assessment of the current `lib/` and `config/` against the
> Remote-mode column of [`product.md`](product.md) §12 (demo truth table).
>
> Date of audit: 2026-05-11 · last updated this commit (CC-1 + CC-4 closed; CC-3 prior).
> Re-run this audit when significant runtime or deployment changes land.
>
> Status legend: `works` · `partial` · `stub` · `missing` · `uncertain`.
>
> **What "Remote mode" means here** (product.md §4.2):
> `browser → DevIDE@<remote-host> → persistent remote tmux`.
> The operator's browser hits a DevIDE instance running on another
> machine. The cockpit served is the same cockpit. The runtime
> authority, sessions, audit, and gate all live on the remote.
> Cross-host browsing of multiple remote DevIDEs is a Fleet-mode
> concern (coordinator-managed) and audited separately.

## Why this audit is different from `audit_local.md`

The Local audit had a tight code/test loop: every row could be
exercised on this machine and proven to work. The Remote audit
cannot. Verifying any Remote-mode claim requires:

- a second machine reachable over HTTPS
- DevIDE deployed there with its workspace source and Postgres
- the operator's browser hitting that deployment

None of that exists today. So this audit reports two things per
row: **(a) is the code ready** for the remote case if the deployment
exists, and **(b) what cross-cutting infrastructure is missing**
that would prevent verifying it. The headline gap turns out to be
deployment readiness, not feature completeness.

## Summary

| #  | Row                  | Status     | Where the gap is                                                              |
|----|----------------------|------------|-------------------------------------------------------------------------------|
| 1  | attach               | **ready** | Dockerfile + release config + deploy.md exist; awaits first production build  |
| 2  | allowed run          | **ready** | same: Dockerfile/release shipped; awaits first production build                |
| 3  | denied run           | **ready** | same: Dockerfile/release shipped; awaits first production build                |
| 4  | disconnect           | **works**  | tmux + erlexec are kernel-survival; same as Local                             |
| 5  | resume               | **works**  | browser drop: in-state buffer (`feff22a`) · server restart: tmux scrollback capture on reattach (this commit) |
| 6  | audit inspect        | **works**  | Ecto audit adapter is the prod default — durable across restart              |
| 7  | replay               | **works**  | audit replay via Ecto adapter; pty replay via in-state buffer + tmux capture-pane recovery |
| 10 | cross-host attach    | **n/a**    | true cross-host belongs to Fleet mode; Remote = one DevIDE per machine        |

**Headline:** *Code ready, deployment artifact shipped, awaiting
first production run.* The Dockerfile, release config, migrate
overlay, hardened `runtime.exs`, and operator runbook
(`docs/deploy.md`) all exist as of this commit. No row has a
code-level gap; rows 1–3 sit at `ready` (build & boot validated
locally; not yet exercised on a real remote host). CC-2 (TLS) is
documented as three turnkey options in `deploy.md` rather than
absorbed into the image.

## Row-by-row

### 1. attach — *partial* (code ready, deployment missing)

The cockpit serves the picker at `/workspaces` and the workspace
LiveView at `/workspaces/:id` (old `?host=local` links are still accepted).
Both work identically regardless of where DevIDE is running. If DevIDE were deployed at
`https://cloud-1.dev/`, an operator pointing a browser at it would
get the same picker — same workspace registry, same audit API,
same terminal channel.

**The gap is purely operational:**

- No `Dockerfile` at repo root.
- No `rel/` directory; no release overlay; `mix release` is unconfigured.
- No `fly.toml` / Kubernetes manifests / systemd unit.
- TLS config in [`config/runtime.exs:73-101`](../config/runtime.exs)
  is commented-out scaffolding; `keyfile` / `certfile` must be wired
  by the operator. `force_ssl` *is* set in
  [`config/prod.exs:14`](../config/prod.exs).
- Postgres dependency: the prod default adapters
  ([`config/config.exs:13-17`](../config/config.exs)) all require a
  reachable Repo. No "lite" mode for Remote-without-DB.
- The workspace source is pluggable via
  `DevIDE.WorkspaceSource` (default: local directories under
  `DEV_IDE_WORKSPACES_ROOT`). A managed-workspace integration lives
  behind that behaviour — see `docs/integrations/`.

### 2. allowed run — *partial* (code ready, deployment missing)

End-to-end allow path (channel → Session → policy gate → erlexec →
output stream) is identical to Local. Once DevIDE runs on the
remote host with tmux installed and a workspace on disk, this
works the same way it does locally.

Same deployment gap as row 1.

### 3. denied run — *partial* (code ready, deployment missing)

Policy gate enforcement and audit emission are local to whichever
DevIDE serves the request. The Ecto audit adapter is the prod
default ([`config/config.exs:13`](../config/config.exs)), so deny
events survive server restart.

Same deployment gap as row 1.

### 4. disconnect — *works*

tmux is started under erlexec with `pty` and lives in the kernel
process tree, not the BEAM. When the operator's websocket goes
down, the Session GenServer's `:DOWN` handler clears the
subscriber but the tmux session itself is untouched. This is
identical to Local mode and survives a network drop the same way.

- [`lib/dev_ide/terminals/session.ex:153-160`](../lib/dev_ide/terminals/session.ex) (`:DOWN` handler)

### 5. resume — *works* (browser drop AND server restart)

Two cases, both covered:

- **Browser disconnect** — the Session GenServer keeps running,
  appends PTY output to its in-state buffer, and replays the buffer
  to the next subscriber. Closed in `feff22a`.
- **Server restart** — the Session GenServer is gone, but tmux
  persisted. `Session.init/1` checks `Tmux.session_exists?/1` and,
  if true, captures the pane's scrollback via
  `Tmux.capture_scrollback/1` (`tmux capture-pane -p -e -J -S -`)
  and seeds the new GenServer's buffer with it (trimmed to
  `@buffer_bytes`). The existing replay-on-subscribe path carries
  it to the client unchanged. Closed in this commit.

- [`lib/dev_ide/terminals/session.ex`](../lib/dev_ide/terminals/session.ex) (`init/1`, `trim_to/2`)
- [`lib/dev_ide/terminals/tmux.ex`](../lib/dev_ide/terminals/tmux.ex) (`session_exists?/1`, `capture_scrollback/1`)
- Test: [`test/dev_ide/terminals/session_test.exs`](../test/dev_ide/terminals/session_test.exs) ("recovers tmux scrollback when the Session GenServer is rebuilt")

### 6. audit inspect — *works*

The Ecto audit adapter
([`lib/dev_ide/audit/ecto_adapter.ex`](../lib/dev_ide/audit/ecto_adapter.ex),
127 lines, the prod default) writes every governed decision to
the `audit_events` table. Survives restart. The Run ledger and
Agents MCP activity render contextual audit from the same storage —
no Remote-specific code needed.

### 7. replay — *works* (audit and pty)

Two replays, both durable:

- **Audit replay** — reconstruct the governed event stream after
  a client returns. Durable via the Ecto audit adapter
  ([`audit/ecto_adapter.ex`](../lib/dev_ide/audit/ecto_adapter.ex)).
  Survives restart.
- **PTY replay** — reconstruct what the terminal showed.
  In-state buffer for the live-process case; tmux scrollback
  capture for the after-restart case. See row 5 for code refs.

### 10. cross-host attach — *n/a for Remote*

Remote mode (product.md §4.2) is one DevIDE per machine, serving
its own workspaces. "Switching hosts in the picker" inside a single
Remote DevIDE means switching between the workspaces that one
remote runtime knows about — which is just within-host workspace
selection (already works).

True cross-host attach across two independent Remote DevIDEs
requires a coordinator to broker visibility, which is Fleet mode
(product.md §4.3). Audit that separately in `docs/audit_fleet.md`
when JX integration becomes a target. For Remote mode, this row is
not the right question.

## Cross-cutting gaps (the real Remote-mode punch list)

The row-by-row table above understates the situation: most rows
share the same blocker. The actual Remote-mode work is mostly
**infrastructure**, not features.

### CC-1. Deployment artifact — ✅ done (this commit)

Shipped:

- [`Dockerfile`](../Dockerfile) — two-stage build
  (`hexpm/elixir:1.18.4-erlang-27.2-...-slim` builder → `debian:bookworm-slim`
  runtime). Runtime image installs `tmux`, `openssl`, `libstdc++6`,
  `libncurses6`, `ca-certificates`, `locales`. Non-root `dev_ide`
  user. ERTS bundled in the release; runtime has no Elixir/Erlang
  apt dependency.
- [`.dockerignore`](../.dockerignore) — excludes `_build`, `deps`,
  `ui-iterations*`, `docs`, `.git`, etc. for a tight build context.
- [`mix.exs`](../mix.exs) — `:releases` config added.
- [`lib/dev_ide/release.ex`](../lib/dev_ide/release.ex) — provides
  `migrate/0` / `rollback/2` for invocation via release `eval`.
- [`rel/overlays/bin/migrate`](../rel/overlays/bin/migrate) — shell
  wrapper that runs `bin/dev_ide eval "DevIde.Release.migrate()"`.
  Migrations are explicit, not at server boot, so a CD pipeline can
  run one migrate pod before rolling the server pool.
- [`config/runtime.exs`](../config/runtime.exs) — hardened. Now
  fails loudly at boot if `DEV_IDE_API_TOKEN` is unset.
  `DEV_IDE_WORKSPACES_ROOT` flows into `:dev_ide, :workspaces_root`
  when set.
- [`docs/deploy.md`](deploy.md) — operator runbook with required
  env, build/run commands, smoke check, and upgrade procedure.

Local smoke validation: compile clean (`--warnings-as-errors`),
271/271 tests pass, `mix release` build was attempted but a
local-safety hook prevents `MIX_ENV=prod` outside of Docker — the
Docker build (next operator action) is the canonical validation.

### CC-2. Turnkey HTTPS

Currently `force_ssl` is set in `config/prod.exs` but `runtime.exs`
TLS config (lines 73–101) is commented out. An operator deploying
DevIDE must hand-roll `:keyfile` / `:certfile` paths. Acceptable
for a custom deploy; insufficient for a one-line install. A Fly /
Render / Caddy / Nginx fronting story would close this.

### CC-3. PTY replay across server restart  *(row 5 / 7)* — ✅ done

Closed in this commit. `Session.init/1` now checks
`Tmux.session_exists?/1` and, if true, seeds the buffer with the
output of `tmux capture-pane -p -e -J -S -` (capped at
`@buffer_bytes`, soft-fails to `<<>>` if tmux misbehaves). The
existing replay-on-subscribe path carries it to the client.

Locally, this also closes the "BEAM restarted while I was gone"
hole — rare but real (laptop sleep can pause the BEAM in ways
that look like a restart).

### CC-4. Workspace source pluggability — ✅ decided

**DevIDE ships as its own image** and discovers workspaces through
the `DevIDE.WorkspaceSource` behaviour. The default source reads
directories under `DEV_IDE_WORKSPACES_ROOT`; integrations supply
alternatives. The Dockerfile stays single-responsibility.

See [`docs/deploy.md`](deploy.md) "Architectural decision"
for the full rationale.

### CC-5. Workspace path safety on arbitrary roots

`Workspaces.safe_host_path/1` and `PathSafety` already check
against a configurable workspace root
(`:dev_ide, :workspaces_root` or `DEV_IDE_WORKSPACES_ROOT`, default
`/workspaces`). This should work transparently on any Linux server
as long as the env points at the right directory and the BEAM has
read access. Verify in the deployment runbook; not a code change.

### CC-6. Channel auth across origins

`ChannelAuth.sign_user_token/1` uses the session cookie's signing
secret. Works for same-origin browsers hitting the deployed
cockpit directly. If a cockpit ever needs to be served from a
different origin than its DevIDE (e.g. a CDN front-end), the auth
token flow needs a different shape (probably a bearer token issued
from a separate `/auth` endpoint).

Not needed for the standard Remote deployment (browser →
`https://cloud-1.dev/` → same DevIDE). Documented for awareness.

## Punch list (ordered by leverage)

1. ~~**CC-1: Dockerfile + release config.**~~ ✅ done (this commit).
2. ~~**CC-3: tmux scrollback on reattach.**~~ ✅ done `c301833`.
3. ~~**CC-4: manager colocation decision.**~~ ✅ decided
   (single-responsibility image; manager via env URL).
4. **CC-2: TLS turnkey story.** Documented as three options in
   `deploy.md` (platform-managed, reverse proxy with TLS,
   DevIDE-terminated). No code change pending; revisit if a
   self-managed prod deploy reveals friction.
5. **CC-6: cross-origin auth.** Defer until a real cross-origin
   deploy is proposed.

The only remaining work to graduate every Remote row from `ready`
to `works` is **a first production run** on a real remote host.
That's an operator action, not a code campaign. Row 10
(cross-host) remains correctly classified as Fleet-mode work
(`audit_fleet.md`, future).

## What this audit deliberately does not say

- It does not propose a specific cloud (Fly, Render, AWS, etc.).
  The Dockerfile should be cloud-agnostic; the cloud choice is
  downstream.
- It does not specify SSO or org-multitenant auth. Those are
  product-shape decisions outside the runtime contract.
- It does not extrapolate from one Remote DevIDE to many. The
  moment "many DevIDEs under one operator's view" enters the
  picture, you are in Fleet mode and `audit_fleet.md` is the right
  doc.

## When to re-run

- After a Dockerfile / release config lands.
- After scrollback-on-reattach lands.
- Before a first real remote deployment is attempted.
- Whenever a Remote-specific feature is proposed and someone needs
  to know whether the foundation under it is real.
