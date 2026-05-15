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
| Build host | **The devbox itself, in a container** | Devbox has `docker` but no host Elixir/Erlang (recon: 2026-05-15). `scripts/build-release.sh` runs the Dockerfile's `builder` stage and extracts the release tree — same pinned toolchain as the production image, no host installs. |

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

## First deployment

First run on a shared production host — go through it deliberately, watch the
output, and have a second set of eyes if you can. Every command runs **on the
devbox** (`ssh devbox@devbox.milcgroup.com`).

1. **Check out the repo** at `/opt/devide/repo`:

   ```sh
   sudo mkdir -p /opt/devide && sudo chown devbox:devbox /opt/devide
   git clone https://github.com/dl-alexandre/dev_ide.git /opt/devide/repo
   cd /opt/devide/repo && git checkout remote-workspace-mode
   ```

2. **Build the release** in a container (the devbox has Docker but no host
   Elixir toolchain; `scripts/build-release.sh` uses the Dockerfile's pinned
   `builder` stage and extracts the release tree):

   ```sh
   cd /opt/devide/repo
   ./scripts/build-release.sh
   # → ./release-out/   (host-visible, owned by root after docker cp)

   # Activate it for the systemd unit (see Host layout)
   sudo rm -rf /opt/devide/release
   sudo cp -a release-out /opt/devide/release
   sudo chown -R devbox:devbox /opt/devide/release
   ```

3. **Environment file:**

   ```sh
   sudo mkdir -p /etc/devide
   sudo cp /opt/devide/repo/deploy/devbox/devide.env.example /etc/devide/devide.env
   sudo chmod 600 /etc/devide/devide.env
   sudoedit /etc/devide/devide.env
   ```

   Fill in `SECRET_KEY_BASE`, `DEV_IDE_API_TOKEN` (both `mix phx.gen.secret`),
   `DEVIDE_PG_PASSWORD`, and `DATABASE_URL`. **`DATABASE_URL` must encode the
   same user/password/db as the `DEVIDE_PG_*` vars** — and use a URL-safe
   password (letters + digits; `@ : / #` break URL parsing).

4. **Pre-pull the Postgres image** so the unit's `--wait` step isn't also
   waiting on a download the first time:

   ```sh
   docker pull postgres:16-alpine
   ```

5. **Start the Postgres container** by hand once, to confirm it comes up
   healthy before involving systemd:

   ```sh
   docker compose \
     -f /opt/devide/repo/deploy/devbox/docker-compose.postgres.yml \
     --env-file /etc/devide/devide.env up -d --wait
   docker compose -f /opt/devide/repo/deploy/devbox/docker-compose.postgres.yml ps
   ```

6. **Install + start the systemd unit:**

   ```sh
   sudo cp /opt/devide/repo/deploy/devbox/devide.service /etc/systemd/system/devide.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now devide
   journalctl -u devide -f
   ```

   On start the unit: brings up + waits for the Postgres container, runs
   `bin/migrate`, then boots the release. A bad env file or failed migration
   surfaces as a `failed` unit after 5 quick retries — not an infinite loop.

7. **Verify** — see the next section. Do this *before* §1.

8. **Caddy route (§1)** — last, and a separate change in the **milc-devbox**
   repo. It flips public exposure on. Do not do it until step 7 passes on a
   real deploy. See `docs/devide_on_devbox.md` §1.

## Verification

DevIDE binds loopback, so until §1 lands it's reachable only from the host:

```sh
systemctl is-active devide                 # → active
curl -fsS http://127.0.0.1:4000/ -o /dev/null && echo "DevIDE responding"
docker compose -f /opt/devide/repo/deploy/devbox/docker-compose.postgres.yml ps
                                           # → postgres ... (healthy)
journalctl -u devide --since "5 min ago" | grep -i migrat
                                           # → migrations ran (or "already up")
```

This is a safe live test of §2/§3: hit it from the host, confirm it serves and
talks to its DB, with nothing exposed to the network.

## Updating

```sh
cd /opt/devide/repo && git pull
./scripts/build-release.sh

# For zero-surprise updates, keep the previous release so rollback is a `mv` back.
sudo mv /opt/devide/release /opt/devide/release.prev
sudo cp -a release-out /opt/devide/release
sudo chown -R devbox:devbox /opt/devide/release

sudo systemctl restart devide              # re-runs migrate, reboots the release
```

## Rollback

```sh
# Code rollback — restore the previous release tree, restart.
sudo systemctl stop devide
rm -rf /opt/devide/release && mv /opt/devide/release.prev /opt/devide/release
sudo systemctl start devide

# Full teardown — if the deployment must be undone entirely.
sudo systemctl disable --now devide
sudo rm /etc/systemd/system/devide.service && sudo systemctl daemon-reload
docker compose -f /opt/devide/repo/deploy/devbox/docker-compose.postgres.yml down
# The DB volume SURVIVES `down`. To discard data too: add `-v`.
```

Note: a migration that ran on update is **not** reverted by a code rollback.
If an update includes a destructive migration, snapshot the DB first (below).

## Backups

DevIDE's state — including the audit log, a security record — lives in the
`devide_pgdata` Docker volume. Snapshot it before risky updates:

```sh
docker exec devide-postgres-1 pg_dump -U dev_ide dev_ide_prod \
  | gzip > /opt/devide/backup-$(date +%F).sql.gz
```

Restore into a fresh container with `gunzip -c … | docker exec -i
devide-postgres-1 psql -U dev_ide dev_ide_prod`.

## Files

| File | Purpose |
|------|---------|
| `devide.service` | systemd unit — Postgres-up + migrate + release boot |
| `docker-compose.postgres.yml` | Dedicated Postgres, loopback `127.0.0.1:15432` |
| `devide.env.example` | Environment template → `/etc/devide/devide.env` |
