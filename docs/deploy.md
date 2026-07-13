# DevIDE — Deployment

> Operator runbook for a Remote-mode deployment (product.md §4.2).
> Tracks audit_remote.md cross-cutting gaps CC-1, CC-2. This document
> is the single-source for what an operator must do to bring up DevIDE
> on a remote machine.

## Architectural decision

**DevIDE ships as its own image.** By default it discovers workspaces
as directories under `DEV_IDE_WORKSPACES_ROOT` (the
`DevIDE.WorkspaceSource.Local` source). To plug a different source —
e.g. a managed-workspace integration — see [`docs/integrations/`](integrations/)
and set `:dev_ide, :workspace_source` accordingly.

## Required environment

DevIDE refuses to boot in prod with any of these missing — see
[`config/runtime.exs`](../config/runtime.exs).

| Variable                    | Purpose                                                              |
|-----------------------------|----------------------------------------------------------------------|
| `SECRET_KEY_BASE`           | Cookie + token signing key. Generate with `mix phx.gen.secret`.       |
| `DATABASE_URL`              | Postgres URL: `ecto://user:pass@host:5432/dev_ide_prod`.              |
| `PHX_HOST`                  | The public hostname (e.g. `cloud-1.dev`). Used for cookie scope + URL. |
| `PHX_SERVER`                | Set to `true` to actually accept HTTP traffic (set in Dockerfile).    |
| `DEV_IDE_API_TOKEN`         | Bearer token for the API + MCP endpoints. The API returns 503 if unset. |
| `DEV_IDE_WORKSPACES_ROOT`   | Filesystem path workspaces must live under. Default `/workspaces`.    |
| `PORT`                      | HTTP port. Default `4000`.                                            |
| `POOL_SIZE`                 | Postgres pool size. Default `10`.                                     |
| `ECTO_IPV6`                 | Set to `true` or `1` for IPv6 DB connections.                         |
| `DNS_CLUSTER_QUERY`         | Optional. For libcluster-style multi-node discovery (unused in v1).   |

## Local stack (smoke validation)

The repo ships a `docker-compose.yml` that brings up DevIDE + Postgres
locally so you can validate the production Dockerfile end-to-end
without provisioning a real remote machine.

For the single-machine or local-network development flow, including
`dev_ide.lan.up`, direct `home` workspace, port-80 LAN edge, and optional
mkcert HTTPS, see
[`docs/lan-access.md`](lan-access.md).

For the separate **DevIDE-on-devbox** (systemd + dedicated Postgres on the
milc devbox host) deployment, including the stable `/opt/devide/deploy/`
layout and activation after the 7204683 reconciliation, see
[`docs/integrations/manager.md`](integrations/manager.md) §5 and the
self-contained runbook inside `lib/dev_ide/integrations/manager/deploy/README.md`.

```bash
# 1. Configure secrets — .env is gitignored.
cp .env.example .env
# Edit .env and fill in:
#   SECRET_KEY_BASE   (python3 -c "import secrets;print(secrets.token_urlsafe(48))")
#   DEV_IDE_API_TOKEN (python3 -c "import secrets;print(secrets.token_urlsafe(32))")

# 2. Seed a workspace directory under the host bind-mount.
mkdir -p workspaces-local/alpha
(cd workspaces-local/alpha && git init -b main && echo hello > README.md)

# 3. Build, migrate, run.
docker compose build
docker compose run --rm dev_ide /app/bin/migrate
docker compose up
```

Open <http://localhost:4000/workspaces>. You should see the picker
render with the `alpha` workspace under a `local` host card with
capability chips (`tmux`, `git`, `audit`, `replay`, `policy`). Click
the workspace name to attach a terminal.

Quick API smoke (bearer-gate validation):

```bash
TOKEN=$(grep '^DEV_IDE_API_TOKEN=' .env | cut -d= -f2)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/api/workspaces                            # → 401 (fail-closed)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/api/workspaces -H "Authorization: Bearer wrong"  # → 401
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/api/workspaces -H "Authorization: Bearer $TOKEN" # → 200
```

Full keystroke-roundtrip smoke (proves the xterm.js ↔ Phoenix
Channel ↔ Session ↔ tmux flow against the production image without
opening a browser):

```bash
# Requires: Python 3.10+ and `pip install websockets`. Stack must be
# up under the `dev` profile so a workspace exists in the picker.

# 1. Sign a user token from inside the running release.
TOKEN=$(docker compose exec -T dev_ide /app/bin/dev_ide rpc \
    'IO.write(DevIdeWeb.ChannelAuth.sign_user_token("smoke-user"))')

# 2. Run the smoke. Sends `echo <marker>\n` as a channel `input`
# event and waits for the marker bytes to come back as `data` pushes.
python3 docker/smoke/channel_smoke.py \
    --url ws://localhost:4000/socket/websocket \
    --token "$TOKEN" \
    --workspace alpha
# → "OK — marker observed in channel data after N bytes"
```

See [`docker/smoke/channel_smoke.py`](../docker/smoke/channel_smoke.py)
for the wire-protocol details (Phoenix v2 frame format) and exit codes.

Tear down cleanly:

```bash
docker compose down              # stop + remove containers
docker compose down --volumes    # also drop the Postgres volume
```

### Automated portable-release contract

Run the isolated production-image smoke before changing release, runtime
configuration, database, terminal, or MCP wiring:

```bash
bash scripts/portable-release-smoke.sh
```

The script ignores any checkout-local `.env`, builds the `portable` release
profile, migrates a disposable PostgreSQL database, and waits on the neutral
database-aware `/healthz` endpoint. It then exercises the cockpit HTTP surface,
terminal MCP initialization, an in-image terminal acceptance check, a real
Phoenix Channel keystroke round-trip, and bearer-gated workspace discovery.
Everything runs in a uniquely named Compose project and is removed on exit.

The host needs Docker, the Docker Compose plugin, and `curl`; no local
Elixir/Erlang, Node, or Python installation is used. Set
`DEVIDE_PORTABLE_SMOKE_TIMEOUT_SECONDS` to extend the default 120-second boot
wait on slow builders. Set `DEVIDE_PORTABLE_SMOKE_KEEP_IMAGES=1` to retain the
two built images for debugging.

## Building the image (without compose)

```bash
docker build -t dev_ide:latest .
```

The build is a two-stage Dockerfile:

- **builder** (`hexpm/elixir:1.20.0-erlang-28.5-debian-bookworm-...-slim`;
  versions are `ARG`s at the top of the Dockerfile)
  pulls deps, compiles assets and Elixir code, builds the erlexec port
  driver, and runs `mix release dev_ide`.
- **runtime** (`debian:bookworm-...-slim`) installs `tmux`, `openssl`,
  `libstdc++6`, `libncurses6`, `ca-certificates`, `locales`; copies
  the release; runs as a non-root `dev_ide` user.

The release bundles ERTS so the runtime image has no Erlang/Elixir
package dependency.

## First boot

```bash
# 1. Migrate the database (one-shot — do this before rolling the server).
docker run --rm \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e PHX_HOST="$PHX_HOST" \
  -e DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" \
  -e DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
  dev_ide:latest /app/bin/migrate

# 2. Start the server.
docker run -d --name dev_ide \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e PHX_HOST="$PHX_HOST" \
  -e DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" \
  -e DEV_IDE_RUNNER_TOKEN="$DEV_IDE_RUNNER_TOKEN" \
  -e DEV_IDE_WORKSPACES_ROOT=/workspaces \
  -v /srv/workspaces:/workspaces \
  dev_ide:latest
```

The migrate step is intentionally explicit — it lets a CI/CD pipeline
run one migration pod before rolling the server pool, which is the
sane shape for zero-downtime upgrades.

## CC-2 — TLS

The Dockerfile does not handle TLS. Three supported fronting
strategies:

1. **Platform-managed TLS** (Fly, Render, Railway, Cloud Run, etc.) —
   the platform terminates TLS on a public hostname and forwards plain
   HTTP to port 4000. `PHX_HOST` is your public hostname; the endpoint
   is configured for HTTPS URLs in `config/runtime.exs` (`scheme:
   "https"`). `DevIdeWeb.RuntimeSSLPlug` issues the runtime redirect and
   HSTS headers unless a service profile disables it.
   **Recommended starting point.**

2. **Reverse proxy with TLS** (Caddy, Nginx, Traefik) — terminate TLS
   on the proxy, forward to DevIDE on `:4000`. Same DevIDE config as (1).
   Caddy is the lowest-config option:
   ```caddyfile
   cloud-1.dev {
       reverse_proxy localhost:4000
   }
   ```

3. **DevIDE-terminated TLS** — Uncomment and fill in the `https:`
   block in [`config/runtime.exs`](../config/runtime.exs) (lines 76–84
   of the original generator template). Mount the keyfile/certfile
   into the container. Useful for air-gapped or fully-self-managed
   deployments; more operational toil than fronting it.

## Smoke check

After the server is up:

```bash
# Server is alive and serving the picker
curl -sf "http://${PHX_HOST}/workspaces" -H "Host: ${PHX_HOST}" -I

# API is fail-closed without a bearer
curl -sf "http://${PHX_HOST}/api/workspaces" -o /dev/null -w "%{http_code}\n"
# Expected: 401 (or 503 if DEV_IDE_API_TOKEN missed somehow)

# API responds when authenticated
curl -sf "http://${PHX_HOST}/api/workspaces" \
  -H "Authorization: Bearer ${DEV_IDE_API_TOKEN}" \
  | head
```

## Upgrades

```bash
docker pull dev_ide:<new>
docker run --rm <env...> dev_ide:<new> /app/bin/migrate
docker stop dev_ide && docker rm dev_ide
docker run -d --name dev_ide <env...> dev_ide:<new>
```

Sessions are durable across the restart: tmux survives in the kernel,
and the new Session GenServer recovers scrollback on first attach
(see audit_remote.md row 5 / CC-3). The operator's browser reconnects
to the new endpoint and sees their pane history.

## Observability (out of scope for CC-1)

The Phoenix LiveDashboard is mounted at `/dev/dashboard` in
non-prod. Production observability — Prometheus exporter, structured
log shipping, error-tracking — is a separate work item and not part
of this campaign. Use the audit log (`/api/workspaces/:id/audit`) as
the operational ground truth in the meantime.

## macOS (Darwin) native builds

A release can be built and run natively on macOS with
`MIX_ENV=prod DEV_IDE_REPO_ADAPTER=sqlite mix dev_ide.release.lan`
(toolchain via mise, per AGENTS.md). Two Darwin-specific hazards are
handled by the build itself:

- **Case-insensitive APFS beam collisions.** `DevIde`/`DevIDE` and
  `Mix.Tasks.DevIde`/`Mix.Tasks.Devide` are compile-time-only Boundary
  roots whose `.beam` filenames collide on APFS/NTFS; the
  `prune_case_colliding_modules` release step (mix.exs) drops them from
  every release and fails the build if any *other* case collision
  appears. Without the prune, embedded-mode boot dies with
  `:load_failed`.
- **Tailwind's Bun-compiled CLI.** Darwin kills it with SIGKILL
  (`Code Signature Invalid`) unless it is ad-hoc re-signed after
  download; the `dev_ide.release.lan` alias does this automatically
  (`resign_bun_binaries` in mix.exs).

Run the release directly (`bin/migrate`, `bin/dev_ide daemon`) with an
env file — `bin/devide lan install` manages systemd units and is
Linux-only. After `bin/dev_ide stop`, wait for epmd to drop the
`dev_ide` name before starting again or the new node fails with "name
in use". Note the same collision still makes the Boundary compiler
flaky in *dev* on macOS (occasional spurious `unknown boundary`
warnings); the durable fix is renaming one module of each pair.

## What this deploy doc deliberately does not address

- **Multi-instance topologies.** DevIDE is a single-runtime cockpit;
  there is no coordinator or cross-host scheduler.
- **High availability.** A single DevIDE instance is the target.
  Scaling to N depends on session affinity (tmux is per-host).
- **Backup / DR.** The audit log lives in Postgres; treat that DB
  like any other operational DB. Workspaces are on disk; their
  durability is a property of the volume backing them.
