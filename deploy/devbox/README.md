# DevIDE on devbox — deployment (§5)

Deploys one shared DevIDE instance on the devbox EC2 host, served behind the
existing Caddy + oauth2-proxy front door and scoped per-user. This is the
**Dashboard model** — a sibling of the manager Dashboard route, not a
per-workspace process.

Full design: [`docs/devide_on_devbox.md`](../../docs/devide_on_devbox.md).

## Shape

| Decision | Choice | Why |
|----------|--------|-----|
| Admin view | Mirror the manager's `admins` list + `?all=true` | Manager already filters server-side; DevIDE just forwards the flag |
| Database | Dedicated Postgres **container** | Isolated from the shared dev pg; one named volume to back up |
| Supervision | **systemd unit** (host process) | Native `/data/workspaces` + docker-socket access; matches `devbox-manager` |

DevIDE binds **loopback only** (`PHX_IP=127.0.0.1`). It trusts the
`X-Auth-Request-*` headers Caddy sets — so it must be unreachable except
through Caddy. Never publish `PORT` outside the host.

## Host layout

```
/opt/devide/
  repo/                  # git checkout of dev_ide (for deploy/ artifacts)
  release/               # extracted `mix release` output → release/bin/dev_ide
/etc/devide/devide.env   # EnvironmentFile, chmod 600
```

## Install

1. **Build the release** (on a build host with the Elixir toolchain, or in CI):

   ```sh
   MIX_ENV=prod mix deps.get --only prod
   MIX_ENV=prod mix assets.deploy
   MIX_ENV=prod mix release
   # → _build/prod/rel/dev_ide  — copy to /opt/devide/release on the host
   ```

2. **Place the repo** at `/opt/devide/repo` (for `deploy/devbox/*`).

3. **Environment file:**

   ```sh
   sudo mkdir -p /etc/devide
   sudo cp /opt/devide/repo/deploy/devbox/devide.env.example /etc/devide/devide.env
   sudo chmod 600 /etc/devide/devide.env
   # fill in SECRET_KEY_BASE, DEVIDE_PG_PASSWORD, DATABASE_URL, DEV_IDE_API_TOKEN
   sudoedit /etc/devide/devide.env
   ```

   `SECRET_KEY_BASE` and `DEV_IDE_API_TOKEN`: `mix phx.gen.secret`.
   `DATABASE_URL` must match `DEVIDE_PG_*` and point at `127.0.0.1:15432`.

4. **Postgres container** — the systemd unit brings it up on start, but you can
   start it by hand the first time to confirm:

   ```sh
   docker compose \
     -f /opt/devide/repo/deploy/devbox/docker-compose.postgres.yml \
     --env-file /etc/devide/devide.env up -d --wait
   ```

5. **systemd unit:**

   ```sh
   sudo cp /opt/devide/repo/deploy/devbox/devide.service /etc/systemd/system/devide.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now devide
   journalctl -u devide -f
   ```

   On start the unit: brings up + waits for the Postgres container, runs
   `bin/migrate`, then boots the release.

6. **Caddy route** — last, and a separate change in the **milc-devbox** repo
   (§1). Until it lands, DevIDE is reachable only from the host itself
   (`curl http://127.0.0.1:4000`). See `docs/devide_on_devbox.md` §1.

## Updating

```sh
# rebuild the release, copy to /opt/devide/release, then:
sudo systemctl restart devide        # re-runs migrate, reboots the release
```

## Files

| File | Purpose |
|------|---------|
| `devide.service` | systemd unit — Postgres-up + migrate + release boot |
| `docker-compose.postgres.yml` | Dedicated Postgres, loopback `127.0.0.1:15432` |
| `devide.env.example` | Environment template → `/etc/devide/devide.env` |
