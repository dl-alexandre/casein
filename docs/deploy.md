# DevIDE — Deployment

> Operator runbook for a Remote-mode deployment (product.md §4.2).
> Tracks audit_remote.md cross-cutting gaps CC-1, CC-2, CC-4. This
> document is the single-source for what an operator must do to bring
> up DevIDE on a remote machine.

## Architectural decision: CC-4 (manager colocation)

**DevIDE ships as its own image.** The milc-devbox manager is a
separate concern, reached via `MILC_DEVBOX_MANAGER_URL`. This matches
the existing code architecture
([`lib/dev_ide/devbox/manager_client.ex`](../lib/dev_ide/devbox/manager_client.ex))
where DevIDE is an HTTP client of the manager.

Operators who want them co-resident on one host should compose them
with docker-compose / Kubernetes / systemd. Operators who want them
on different hosts wire `MILC_DEVBOX_MANAGER_URL` accordingly. The
Dockerfile is single-responsibility.

## Required environment

DevIDE refuses to boot in prod with any of these missing — see
[`config/runtime.exs`](../config/runtime.exs).

| Variable                    | Purpose                                                              |
|-----------------------------|----------------------------------------------------------------------|
| `SECRET_KEY_BASE`           | Cookie + token signing key. Generate with `mix phx.gen.secret`.       |
| `DATABASE_URL`              | Postgres URL: `ecto://user:pass@host:5432/dev_ide_prod`.              |
| `PHX_HOST`                  | The public hostname (e.g. `cloud-1.dev`). Used for cookie scope + URL. |
| `PHX_SERVER`                | Set to `true` to actually accept HTTP traffic (set in Dockerfile).    |
| `DEV_IDE_API_TOKEN`         | Bearer token for the read-only API. The API returns 503 if unset.     |
| `MILC_DEVBOX_MANAGER_URL`   | URL of the milc-devbox manager (DevIDE is its HTTP client).           |
| `DEV_IDE_WORKSPACES_ROOT`   | Filesystem path workspaces must live under. Default `/workspaces`.    |
| `PORT`                      | HTTP port. Default `4000`.                                            |
| `POOL_SIZE`                 | Postgres pool size. Default `10`.                                     |
| `ECTO_IPV6`                 | Set to `true` or `1` for IPv6 DB connections.                         |
| `DNS_CLUSTER_QUERY`         | Optional. For libcluster-style multi-node discovery (unused in v1).   |

## Building the image

```bash
docker build -t dev_ide:latest .
```

The build is a two-stage Dockerfile:

- **builder** (`hexpm/elixir:1.18.4-erlang-27.2-debian-bookworm-...-slim`)
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
  -e MILC_DEVBOX_MANAGER_URL="$MILC_DEVBOX_MANAGER_URL" \
  dev_ide:latest /app/bin/migrate

# 2. Start the server.
docker run -d --name dev_ide \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e PHX_HOST="$PHX_HOST" \
  -e DEV_IDE_API_TOKEN="$DEV_IDE_API_TOKEN" \
  -e MILC_DEVBOX_MANAGER_URL="$MILC_DEVBOX_MANAGER_URL" \
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
   "https"`). `force_ssl` in `config/prod.exs` issues HSTS headers.
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

## What this deploy doc deliberately does not address

- **Multi-instance / fleet topologies.** That is `audit_fleet.md` work
  and requires a coordinator (JX).
- **High availability.** A single DevIDE instance is the v1 target.
  Scaling to N depends on session affinity (tmux is per-host),
  which is a fleet-shaped problem.
- **Backup / DR.** The audit log lives in Postgres; treat that DB
  like any other operational DB. Workspaces are on disk; their
  durability is a property of the volume backing them.
