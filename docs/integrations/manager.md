# MILC Devbox Manager Integration

This directory (`lib/dev_ide/integrations/manager/`) contains the **entire** integration with the milc-devbox manager system. Nothing outside this tree (or its dedicated tests and this document) should contain knowledge of the manager, its payload shapes, service names, or deployment conventions.

## Responsibilities

The integration implements `DevIDE.WorkspaceSource` and provides:

- HTTP client to the milc-devbox manager (`client.ex`)
- Payload normalization (`workspace.ex` + `to_public/1` in `workspace_source.ex`)
- Special execution behaviour on the devbox host (docker compose exec, on-host paths, tmux shell)
- Log service selection for v3 workspaces
- Forward-auth compatible identity handling (via `ForwardAuth` plug when enabled)

## Well-known metadata keys populated by this source

When converting manager data to the public `%DevIDE.Workspace{}`, the following keys are placed under `metadata`:

- `type` — `:v3 | :legacy | :unknown`
- `ports` — map of service → port
- `domain_base`
- `slot`, `created_at`, `last_started`, `raw` (original payload for debugging)

## Callbacks implemented

- `default_log_service/1` — returns `"milc-platform-server"` for v3 workspaces
- `prepare_local_argv/1` and `local_tmux_pane_shell/0` — wrap commands with `docker compose exec` when running on-host
- `safe_host_loc/1` — special handling for `/data/workspaces`

## Configuration (only relevant when this source is active)

- `MILC_DEVBOX_MANAGER_URL`
- `DEV_IDE_ON_DEVBOX` / `on_devbox`
- `DEV_IDE_DEVBOX_EXEC_SERVICE` (defaults to `onebackend-v3`)
- `MILC_DEVBOX_SSH_HOST`

## Deployment artifacts

The `deploy/` subdirectory contains the systemd unit, Postgres compose file, and environment template used when running a shared DevIDE instance on a milc devbox host.

## Testing

All tests for this integration live under `test/dev_ide/integrations/manager/`. Public tests may use Bypass to stub the manager HTTP endpoints when exercising the full stack with this source selected.

---

**Rule**: If you find yourself writing `if type == :v3` or referencing `milc-platform-server` or `onebackend-v3` outside this directory, you are doing it wrong. Push the knowledge into this integration.
  `ws-{name}-onebackend` (compose service `onebackend-v3`).
- **DevIDE auth today** is a placeholder: `DevIdeWeb.Plugs.AssignCurrentUser`
  returns a static `%{id: "dev", email: "dev@local", role: :owner}` for
  everyone. `Plugs.ApiAuth` is a separate bearer-token gate for `/api`.
- A shared Postgres (`one-platform-postgres-dev`, pg18) is available on `:5432`.

## Work breakdown

### 1. Routing — `manager/lib/caddy.js` (separate repo, manager PR)

Add a Dashboard-sibling block in `generateCaddyfile()`:

```
{scheme}://devide.{domain} {
    [import aws_tls]            # AWS mode only
    import forward_auth
    reverse_proxy 127.0.0.1:{DEVIDE_PORT}
}
```

~6 lines, mirrors the existing dashboard block. Pick a fixed host port for
DevIDE (outside the workspace port ranges; the manager allocates workspace
ports from `user-ports.json`). No per-workspace route entries.

### 2. Auth & identity — DevIDE (the core work)

Replace the `AssignCurrentUser` placeholder with a trusted-header identity
plug. **This is the gating change** — without it a shared instance shows every
dev the same `dev@local` session.

- **`DevIdeWeb.Plugs.ForwardAuth`** — reads **`X-Auth-Request-Email`** (the
  authoritative header — see "Identity derivation" below; `X-Auth-Request-User`
  is *not* used). Derives the username and assigns `:current_user`. Rejects
  requests missing the email header **only when forward-auth mode is enabled**
  (config flag), so local single-user dev keeps working with the static user.
- **Trust boundary**: the headers are only trustworthy because Caddy strips
  any client-supplied copy and re-sets them from oauth2-proxy. DevIDE must
  bind to `127.0.0.1` (or the docker bridge) so it is unreachable except
  through Caddy. Document this; it is load-bearing.
- **LiveView**: `AssignCurrentUser.from_session/1` currently ignores the
  session. Put the authenticated identity into the session in the plug, and
  have `from_session/1` read it so `WorkspaceLive.*` mounts get the real user.
- **API** (`/api`): keep the bearer-token gate as-is (machine clients /
  fleet runners don't go through oauth2-proxy). No change.

### Identity derivation (verified against `manager/lib/auth.js`)

The manager **ignores `X-Auth-Request-User`**. Its `authMiddleware` reads
`x-auth-request-email` and derives the username itself:

```
normalizeUser(email) = email |> split("@") |> first |> downcase
```

`workspace.create()` stores that derived value as `workspace.user` (and
prefixes the workspace name with it). Authorization throughout the manager is
`ws.user === authUser.user || authUser.isAdmin`.

**DevIDE must derive the username identically** — same `split("@") |> hd() |>
downcase` — or it will silently mismatch the manager's records. Treat the
email as the authoritative identity and the username as a derived value.

### 3. Workspace list scoping & link access — DevIDE

The manager's `GET /workspaces` **already filters by `authUser.user`
server-side**, and `ManagerClient` already forwards an `x-auth-request-email`
header. So once DevIDE forwards the *authenticated* user's email (not a
static env var), **list scoping is delegated to the manager for free**.
Direct workspace links are intentionally more permissive: knowing a
`/workspaces/:id` URL is enough to open that workspace in DevIDE, matching the
manager's link-addressable `GET /api/workspaces/:id/status` endpoint.

- **List** (`WorkspaceLive.Index`): no DevIDE-side filter needed — forward the
  authenticated email to the manager and render what it returns. Admins: the
  manager honors `?all=true` (gated by the `admins` list in
  `auth-config.json`); mirror that flag through if an "all workspaces" view
  is wanted.
- **Show link access**: `WorkspaceLive.Show.mount/3` fetches the workspace
  through the manager with the viewer's email forwarded, then validates host
  location safety. It does not compare the workspace owner to the viewer; this
  preserves "send me your DevIDE link" collaboration while keeping the picker
  scoped.
- **Terminal / Run / Audit**: every `Session.ensure_started`, `Commands.Run`,
  and `gate/3` audit emission must carry the authenticated user — not the
  static one — so cross-user link access is still attributable. The `gate/3`
  audit attrs already thread `workspace_id`; add `actor_email`.
- **Terminal session naming** already keys on `:current_user`; with real
  identity this becomes correct multi-user isolation instead of decoration.

### 4. Execution substrate on-box — DevIDE

On devbox the SSH layer is unnecessary; the `{:local, …}` branches already
exist and the remote-mode work is preserved for genuine off-box use.

- **FileAccess**: `Workspaces.safe_host_loc/1` returns
  `{:local, "/data/workspaces/{name}"}` when DevIDE runs on-box (new config
  flag `:on_devbox` or detect via `remote_ssh_host` being unset). Files /
  Search / Diff become direct filesystem + local `git` — no ssh.
- **Commands / Terminal**: replace `Commands.SshAdapter` with a
  `Commands.DockerExecAdapter` that runs
  `docker compose exec -T onebackend-v3 …` in the workspace dir (or
  `docker exec ws-{name}-onebackend …`) — same shape as `SshAdapter` minus
  the `ssh {host} --` wrapper. `Terminals.Session` builds a local
  `tmux new-session -A` whose command is the `docker exec` instead of
  `ssh -tt …`.
- DevIDE needs Docker access: run as a host process in the `docker` group, or
  as a container with `/var/run/docker.sock` and `/data/workspaces` mounted.

### 5. Deployment — DevIDE + ops

Canonical host artifacts live in the private
`MILCGroup/milc-devbox` repository under `devide/`. Its installer writes the
operator profile to `/etc/devide/operator.json` and stable infrastructure to
`/opt/devide/deploy/`. Core releases contain only portable application
artifacts and consume that overlay through the versioned operator-config
contract. Decisions (from the open questions, now resolved):

- **`mix release`** — already configured in `mix.exs`. Runtime config via
  `runtime.exs`: `SECRET_KEY_BASE`, `PHX_HOST=devide.{domain}`, `DATABASE_URL`,
  `PORT`, and `PHX_IP=127.0.0.1` (new — `runtime.exs` parses `PHX_IP`; the
  trust-boundary bind, defaults to all-interfaces for non-devbox deploys).
- **Supervision: systemd unit** from the private operator overlay. Host process
  in the `docker`
  group — native `/data/workspaces` + docker-socket access, matches the
  `devbox-manager` service. A container buys no isolation here since the
  docker-socket mount is root-equivalent regardless.
- **Database: dedicated Postgres container** from the private operator overlay
  on `127.0.0.1:15432` (a port
  clear of the devbox host's known occupants). The systemd unit brings it up
  `--wait`, then runs `bin/migrate`, then boots the release.
- **Manager API calls** become `http://127.0.0.1:9000` — no `ssh -fNL` tunnel.
  The `x-auth-request-email` header `ManagerClient` sends is wired to the
  authenticated user (done in §3).

## Security considerations (shared production host)

- DevIDE becomes a shared dependency on a prod host: BEAM memory footprint,
  and an outage affects every dev. Size the release; set a memory limit.
- The trusted-header model is only safe if DevIDE is **not** directly
  reachable. Bind localhost; never expose `DEVIDE_PORT` publicly.
- The picker remains user-scoped, but direct workspace URLs are a collaboration
  affordance. Treat a shared DevIDE URL as granting cockpit access to that
  workspace; manager lifecycle mutations remain owner/admin-gated by the
  manager itself.
- Docker access = root-equivalent on the host. The DevIDE process can exec
  into any container. Acceptable (the manager already has this) but worth
  stating.

## Phasing

1. **§4** — local docker-exec substrate. ✅ Done (`on_devbox?`/`safe_host_loc`,
   `PortExec`, `DockerExecAdapter`, on-devbox terminal; `DockerExecAdapter`
   test seam is a tracked follow-up).
2. **§2 + §3** — ForwardAuth plug + list scoping/link access. ✅ Done (`ForwardAuth`
   plug, `from_session/1`, `ManagerClient`/`Workspaces` auth threading,
   `owns?/2`, Index list-scoping, Show + terminal-channel link access,
   `user_socket` real identity). Static-user fallback preserved for local dev.
3. **§5** — release + systemd unit + DB, behind a localhost port. ✅ Done.
   Portable runtime support remains in core; the MILC systemd unit,
   dedicated-Postgres compose file, environment template, and runbook are
   maintained by the private `MILCGroup/milc-devbox/devide` overlay.
4. **§1** — manager PR for the Caddy route. ⏳ Pending — last, so nothing is
   exposed until auth + scoping are proven.

### §3 follow-ups (tracked, not blockers)

- `logs/sse.ex` `stream_logs` doesn't thread `auth` — low-risk, the log
  stream is only reachable from the Show page after link access succeeds.
- `run:start` relies on Show's mount-level workspace resolution (the workspace
  assign is immutable post-mount) rather than a per-event lookup.
- `DockerExecAdapter` needs a runner seam (like `SshRunner`) to be unit-tested.

## Open questions

None — all resolved (see below). Remaining work is §1, the manager Caddy PR.

## Resolved

- ~~Does `X-Auth-Request-User` equal the manager's `user` field?~~ **N/A** —
  the manager ignores `X-Auth-Request-User` and derives the username from
  `X-Auth-Request-Email` via `email.split("@")[0].toLowerCase()`. DevIDE must
  derive it the same way. See "Identity derivation" above.
- ~~Admin "see all workspaces" view?~~ **Superseded (flat peer model)** —
  DevIDE no longer elevates `DEV_IDE_ADMINS` / `role: :admin`. Every
  oauth2-authenticated viewer may open every workspace and artifact; there is
  no "mine vs all" privilege tier inside DevIDE. The env list is still parsed
  (harmless legacy) but grants nothing.
- ~~Shared pg or dedicated container?~~ **Dedicated Postgres container** —
  isolated from the shared dev pg, one named volume to back up. The audit log
  (a security record) lives here, so the dedicated volume is the thing to
  include in host backups.
- ~~Host process (systemd) vs container?~~ **systemd unit** — a host process
  has native `/data/workspaces` and docker-socket access; containerizing buys
  no isolation because the docker-socket mount is root-equivalent anyway.
  Matches the `devbox-manager` service shape.
