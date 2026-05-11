# Remote-mode truth-table audit

> Grounded assessment of the current `lib/` and `config/` against the
> Remote-mode column of [`product.md`](product.md) §12 (demo truth table).
>
> Date of audit: 2026-05-11 · against commit `5656126`
> (after the Local-mode campaign closed all four cockpit punch-list items).
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
- DevIDE deployed there with a milc-devbox manager and Postgres
- the operator's browser hitting that deployment

None of that exists today. So this audit reports two things per
row: **(a) is the code ready** for the remote case if the deployment
exists, and **(b) what cross-cutting infrastructure is missing**
that would prevent verifying it. The headline gap turns out to be
deployment readiness, not feature completeness.

## Summary

| #  | Row                  | Status     | Where the gap is                                                              |
|----|----------------------|------------|-------------------------------------------------------------------------------|
| 1  | attach               | **partial**| code ready · no Dockerfile / release / HTTPS turnkey                          |
| 2  | allowed run          | **partial**| same: code ready · deployment unbuilt                                         |
| 3  | denied run           | **partial**| same: code ready · deployment unbuilt                                         |
| 4  | disconnect           | **works**  | tmux + erlexec are kernel-survival; same as Local                             |
| 5  | resume               | **partial**| works across browser drop; **fails** across DevIDE server restart (buffer in GenServer state, `restart: :temporary`) |
| 6  | audit inspect        | **works**  | Ecto audit adapter is the prod default — durable across restart              |
| 7  | replay               | **partial**| audit-replay durable; pty/scrollback replay not durable across server restart |
| 10 | cross-host attach    | **n/a**    | true cross-host belongs to Fleet mode; Remote = one DevIDE per machine        |

**Headline:** *The code is largely ready; the deployment story isn't.*
Every Remote row except cross-host has a code answer today. Six
of seven are blocked behind the same gate: there is no Dockerfile,
no release config, no turnkey TLS, no fly.toml. The one row that
has a real code gap (row 5 / 7, pty replay across server restart)
is small and well-scoped.

## Row-by-row

### 1. attach — *partial* (code ready, deployment missing)

The cockpit serves the picker at `/workspaces` and the workspace
LiveView at `/workspaces/:id?host=local`. Both work identically
regardless of where DevIDE is running. If DevIDE were deployed at
`https://cloud-1.dev/`, an operator pointing a browser at it would
get the same picker — same workspace registry, same Evidence drawer,
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
- milc-devbox manager is a separate process DevIDE talks to via
  HTTP ([`lib/dev_ide/devbox/manager_client.ex:6`](../lib/dev_ide/devbox/manager_client.ex));
  in Remote mode both must be colocated or routed.

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

### 5. resume — *partial* (works across browser drop; fails across server restart)

Local-mode row 5 was closed by the in-state output buffer
(`feff22a`). That solves the **browser-disconnect** case. It does
not solve the **server-restart** case, which is more important in
Remote mode where the operator's browser is the only client and a
prod deploy may bounce.

The Session GenServer is started with `restart: :temporary`
([`session.ex:31`](../lib/dev_ide/terminals/session.ex)). If the
process dies or the node restarts, the buffer is lost. tmux still
holds the pane (and tmux has its own scrollback), but DevIDE
doesn't currently re-read tmux's scrollback on reattach.

**Two ways to close this:**

- *Easy*: on reattach to an existing tmux session, run
  `tmux capture-pane -p -S -<N> -t <session>` and prepend that to
  the replay stream. Uses what tmux already retains; no new
  durability mechanism.
- *Harder*: persist the rolling buffer to disk (or Ecto) on a
  timer, restore on Session start. More invasive; only worth it
  if tmux capture-pane proves insufficient.

The easy path is the recommended next step.

### 6. audit inspect — *works*

The Ecto audit adapter
([`lib/dev_ide/audit/ecto_adapter.ex`](../lib/dev_ide/audit/ecto_adapter.ex),
127 lines, the prod default) writes every governed decision to
the `audit_events` table. Survives restart. The Evidence drawer
landed in Local (`7f15981`) and renders against whichever adapter
is configured — no Remote-specific code needed.

### 7. replay — *partial* (audit yes; pty no)

There are two replays in the truth table interpretation:

- **Audit replay** — reconstruct the governed event stream after a
  client returns. Durable via the Ecto audit adapter.
- **PTY replay** — reconstruct what the terminal showed after a
  client returns. Durable across browser disconnect (via the
  in-state buffer), **not** durable across server restart.

This is the same gap as row 5 stated from the replay angle. Same
fix applies (tmux capture-pane on rejoin).

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

### CC-1. Deployment artifact

- `Dockerfile` (multi-stage, Elixir → Erlang/OTP slim runtime, tmux
  installed in final image, ports exposed)
- `rel/` overlays for runtime config + migrations on boot
- `mix release` config wired in `mix.exs`
- a known-good `runtime.exs` for prod that reads
  `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
  `DEV_IDE_API_TOKEN`, `MILC_DEVBOX_MANAGER_URL`,
  `DEV_IDE_WORKSPACES_ROOT`, and TLS paths

**Until this exists, none of rows 1–7 can be demonstrated.**
Highest-leverage item by far.

### CC-2. Turnkey HTTPS

Currently `force_ssl` is set in `config/prod.exs` but `runtime.exs`
TLS config (lines 73–101) is commented out. An operator deploying
DevIDE must hand-roll `:keyfile` / `:certfile` paths. Acceptable
for a custom deploy; insufficient for a one-line install. A Fly /
Render / Caddy / Nginx fronting story would close this.

### CC-3. PTY replay across server restart  *(row 5 / 7)*

The only Remote-mode row with a code-level gap (versus
infrastructure gap). The fix is small: on `Session.ensure_started`
finding an existing tmux session, capture scrollback via
`tmux capture-pane -p -S -<N>` and seed the in-state buffer with
it. After that, the existing replay-on-subscribe path works
unchanged.

This is also a Local-mode improvement — it closes the
"server restarted while I was gone" hole, which is rarer locally
but real (laptop sleep can pause the BEAM in ways that look like
a restart to the GenServer).

### CC-4. Manager colocation

DevIDE talks to milc-devbox manager via HTTP. For Remote, the
manager needs to be colocated on the remote host (simpler) or
itself reachable over the network (more complex; introduces a
second hop). The Dockerfile decision likely determines this —
ship the manager in the same image, or two-process.

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

1. **CC-1: Dockerfile + release config.** Without this no Remote
   row can be demonstrated. Biggest single unblock.
2. **CC-3: tmux scrollback on reattach.** Closes the only code-level
   Remote gap and incidentally improves Local. Small change.
3. **CC-2: TLS turnkey story.** Pick a fronting strategy (Fly,
   Caddy, Nginx) and document it. May be zero code, all docs +
   runbook.
4. **CC-4: manager colocation decision.** Decide one-image vs
   two-process before the Dockerfile is final, since they imply
   different `runtime.exs` defaults.
5. **CC-6: cross-origin auth.** Defer until a real cross-origin
   deploy is proposed.

After CC-1 + CC-3 land, Remote-mode is `works/works/works/works`
on rows 1–7 modulo operational toil. Row 10 (cross-host) remains
correctly classified as Fleet-mode work.

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
