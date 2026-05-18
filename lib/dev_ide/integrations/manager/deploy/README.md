# DevIDE on devbox — deployment (§5)

Deploys one shared DevIDE instance on the devbox EC2 host, served behind the
existing Caddy + oauth2-proxy front door and scoped per-user. This is the
**Dashboard model** — a sibling of the manager Dashboard route, not a
per-workspace process.

Full design: [`docs/devide_on_devbox.md`](../../../../../docs/devide_on_devbox.md).

## Shape

| Decision | Choice | Why |
|----------|--------|-----|
| Admin view | Mirror the manager's `admins` list + `?all=true` | Manager already filters server-side; DevIDE just forwards the flag |
| Database | Dedicated Postgres **container** | Isolated from the shared dev pg; one named volume to back up |
| Supervision | **systemd unit** (host process) | Native `/data/workspaces` + docker-socket access; matches `devbox-manager` |
| Build host | **The devbox itself, in a container** | Devbox has `docker` but no host Elixir/Erlang. `scripts/build-release.sh` runs the Dockerfile's `builder` stage and extracts the release tree — same pinned toolchain as the production image, no host installs. |
| Deploy artifacts | **Bundled inside every release** at `<release>/deploy/`; copied to **stable host dir** on activation | Canonical source lives in `lib/dev_ide/integrations/manager/deploy/`; the `rel/overlays/deploy/` symlink set ships them with every `mix release`. An explicit activation step then copies the fresh artifacts into the stable `/opt/devide/deploy/` (release-independent). This is the "C then B" reconciliation after 7204683. |

DevIDE binds **loopback only** (`PHX_IP=127.0.0.1`). It trusts the
`X-Auth-Request-*` headers Caddy sets — so it must be unreachable except
through Caddy. Never publish `PORT` outside the host.

## Host layout (stable after 7204683 reconciliation)

```
/opt/devide/
  deploy/                # STABLE, release-independent. Contains the 4 artifacts:
                         #   devide.service, docker-compose.postgres.yml,
                         #   devide.env.example, README.md
                         # Populated by the activation step from the release's
                         # bundled <release>/deploy/ copy. The installed unit
                         # and all ExecStartPre paths reference this dir.
  release/               # extracted `mix release` output → release/bin/dev_ide
                         # (also contains its own copy of deploy/ for the next
                         # activation or rollback)
  release.prev/          # (optional) previous release for fast rollback
/etc/devide/devide.env   # EnvironmentFile, chmod 600 (populated once at first
                         # deploy from the example in deploy/)
```

No git checkout ("repo/") on the box; the release tarball is the source of truth
for the running app. Deploy artifacts are version-locked via the release bundle
but live at stable paths after activation so that `git pull` + release swaps
(cd0aed5, Ghostty 4c308b8, future work) never cause "no such file" in
ExecStartPre.

## First deployment

First run on a shared production host — go through it deliberately, watch the
output, and have a second set of eyes if you can. Every command runs **on the
devbox** (`ssh devbox@devbox.milcgroup.com`) unless noted.

1. **Build the release** (on any host with Docker; can be the devbox itself):

   ```sh
   # In a checkout of dev_ide on the build host:
   ./scripts/build-release.sh
   # → ./release-out/   (host-visible, owned by root after docker cp)
   ```

   The output tree includes `release-out/deploy/{devide.service,
   docker-compose.postgres.yml, devide.env.example, README.md}` — bundled
   from `rel/overlays/deploy/`.

2. **Place the release on the devbox** (extracted tree becomes the active release):

   ```sh
   sudo mkdir -p /opt/devide && sudo chown devbox:devbox /opt/devide
   sudo rm -rf /opt/devide/release
   sudo cp -a release-out /opt/devide/release
   sudo chown -R devbox:devbox /opt/devide/release
   ```

   (If built off-box, scp the `release-out/` tree to the devbox first.)

3. **Activation step** (the key reconciliation step — copies deploy artifacts
   from the just-placed release into the stable location and installs the unit):

   ```sh
   sudo mkdir -p /opt/devide/deploy
   sudo chown devbox:devbox /opt/devide/deploy
   sudo cp -a /opt/devide/release/deploy/. /opt/devide/deploy/
   sudo cp /opt/devide/deploy/devide.service /etc/systemd/system/devide.service
   sudo systemctl daemon-reload
   ```

   This ensures the unit's `ExecStartPre` (for the compose file) and future
   references always use the stable `/opt/devide/deploy/...` paths.

4. **Environment file** (first time only; later updates edit in place):

   ```sh
   sudo mkdir -p /etc/devide
   sudo cp /opt/devide/deploy/devide.env.example /etc/devide/devide.env
   sudo chmod 600 /etc/devide/devide.env
   sudoedit /etc/devide/devide.env
   ```

   Fill in `SECRET_KEY_BASE`, `DEV_IDE_API_TOKEN` (both `mix phx.gen.secret`),
   `DEVIDE_PG_PASSWORD`, and `DATABASE_URL`. **`DATABASE_URL` must encode the
   same user/password/db as the `DEVIDE_PG_*` vars** — and use a URL-safe
   password (letters + digits; `@ : / #` break URL parsing).

5. **Pre-pull the Postgres image** so the unit's `--wait` step isn't also
   waiting on a download the first time:

   ```sh
   docker pull postgres:16-alpine
   ```

6. **Start the Postgres container** by hand once, to confirm it comes up
   healthy before involving systemd:

   ```sh
   docker compose \
     -f /opt/devide/deploy/docker-compose.postgres.yml \
     --env-file /etc/devide/devide.env up -d --wait
   docker compose -f /opt/devide/deploy/docker-compose.postgres.yml ps
   ```

7. **Enable + start the systemd unit:**

   ```sh
   sudo systemctl enable --now devide
   journalctl -u devide -f
   ```

   On start the unit: brings up + waits for the Postgres container, runs
   `bin/migrate`, then boots the release. A bad env file or failed migration
   surfaces as a `failed` unit after 5 quick retries — not an infinite loop.

8. **Verify** — see the next section. Do this *before* exposing via Caddy.

9. **Caddy route (§1)** — last, and a separate change in the **milc-devbox**
   repo. It flips public exposure on. Do not do it until step 8 passes on a
   real deploy. See `docs/devide_on_devbox.md` §1.

## Verification

DevIDE binds loopback, so until §1 lands it's reachable only from the host:

```sh
systemctl is-active devide                 # → active
curl -fsS http://127.0.0.1:4000/ -o /dev/null && echo "DevIDE responding"
docker compose -f /opt/devide/deploy/docker-compose.postgres.yml ps
                                           # → postgres ... (healthy)
journalctl -u devide --since "5 min ago" | grep -i migrat
                                           # → migrations ran (or "already up")
```

This is a safe live test of §2/§3: hit it from the host, confirm it serves and
talks to its DB, with nothing exposed to the network.

## Updating

```sh
# Build a new release (in a checkout of dev_ide on the build host):
./scripts/build-release.sh

# For zero-surprise updates, keep the previous release so rollback is a `mv` back.
sudo mv /opt/devide/release /opt/devide/release.prev
sudo cp -a release-out /opt/devide/release
sudo chown -R devbox:devbox /opt/devide/release

# Activation step: copy fresh deploy artifacts from the *new* release into the
# stable dir (this also refreshes the unit file if the template changed).
sudo mkdir -p /opt/devide/deploy
sudo chown devbox:devbox /opt/devide/deploy
sudo cp -a /opt/devide/release/deploy/. /opt/devide/deploy/
sudo cp /opt/devide/deploy/devide.service /etc/systemd/system/devide.service
sudo systemctl daemon-reload

sudo systemctl restart devide              # re-runs migrate, reboots the release
```

The activation step is what makes the paths future-proof. The unit file on disk
(now at `/etc/systemd/system/devide.service`) and the stable deploy/ dir are
always refreshed from the release being activated.

## Rollback

```sh
# Code rollback — restore the previous release tree + its deploy artifacts.
sudo systemctl stop devide
rm -rf /opt/devide/release && mv /opt/devide/release.prev /opt/devide/release

# Re-activate the *previous* release's deploy artifacts (in case the compose
# file or unit template differed) so stable paths and unit stay consistent.
sudo mkdir -p /opt/devide/deploy
sudo chown devbox:devbox /opt/devide/deploy
sudo cp -a /opt/devide/release/deploy/. /opt/devide/deploy/
sudo cp /opt/devide/deploy/devide.service /etc/systemd/system/devide.service
sudo systemctl daemon-reload
sudo systemctl start devide

# Full teardown — if the deployment must be undone entirely.
sudo systemctl disable --now devide
sudo rm /etc/systemd/system/devide.service && sudo systemctl daemon-reload
docker compose -f /opt/devide/deploy/docker-compose.postgres.yml down
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

## Reconcile current broken DevBox (post-7204683, 4c308b8 / cd0aed5 era)

The real DevBox is currently running release `4c308b8` (Ghostty inline snapshot
work) but its installed `/etc/systemd/system/devide.service` (and possibly the
runbook in use) still contains the **pre-7204683** `ExecStartPre` that hard-coded
the old `repo/deploy/devbox/` layout that disappeared after the rename.

A bad tree is preserved at `/opt/devide/release.bad` for inspection.

**One-time reconciliation commands** (run on the devbox via
`ssh devbox@devbox.milcgroup.com`):

```sh
# 1. Stop the broken unit so we can safely touch paths.
sudo systemctl stop devide || true

# 2. Seed the stable deploy/ directory from whatever deploy artifacts the
#    *current* release tree still carries (they were bundled at build time
#    even if the git worktree on the box was cleaned). Use the bad tree if
#    the active release is also broken.
CURRENT_RELEASE=/opt/devide/release
# If the active one is missing good deploy/ artifacts, fall back:
# CURRENT_RELEASE=/opt/devide/release.bad
sudo mkdir -p /opt/devide/deploy
sudo chown devbox:devbox /opt/devide/deploy
sudo cp -a "${CURRENT_RELEASE}/deploy/." /opt/devide/deploy/ || \
  echo "If cp failed, manually copy the 4 files from the preserved tree."

# 3. Install a *corrected* unit file whose ExecStartPre uses the new stable
#    /opt/devide/deploy/ path for the compose file (and release/ for bins).
#    We write it fresh so it is guaranteed to have the post-reconciliation paths
#    even if the bundled service inside 4c308b8 still had the intermediate
#    /release/deploy/ references.
sudo tee /opt/devide/deploy/devide.service > /dev/null << 'UNITEOF'
# DevIDE-on-devbox systemd unit (reconciled after 7204683).
# (full header comments elided for the here-doc; see the file in the next
# release or in the repo for the complete documented version)
[Unit]
Description=DevIDE — shared on-devbox IDE
Documentation=https://github.com/dl-alexandre/dev_ide/blob/master/docs/devide_on_devbox.md
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
User=devbox
Group=docker
EnvironmentFile=/etc/devide/devide.env
WorkingDirectory=/opt/devide

# Stable paths (the whole point of the reconciliation):
ExecStartPre=/usr/bin/docker compose -f /opt/devide/deploy/docker-compose.postgres.yml --env-file /etc/devide/devide.env up -d --wait
ExecStartPre=/opt/devide/release/bin/migrate
ExecStart=/opt/devide/release/bin/dev_ide start
ExecStop=/opt/devide/release/bin/dev_ide stop

TimeoutStartSec=300
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/data/workspaces /opt/devide

[Install]
WantedBy=multi-user.target
UNITEOF

sudo cp /opt/devide/deploy/devide.service /etc/systemd/system/devide.service
sudo systemctl daemon-reload

# 4. (Re)start. The first start will exercise the new stable ExecStartPre.
sudo systemctl start devide
journalctl -u devide -f
```

After this, the box is on the stable layout. Future releases only need the
normal "place release + activation step + restart" sequence; the unit will
automatically pick up new deploy artifacts (including any evolution of the
unit template itself) because activation always re-copies the service file.

Once a *new* release (built after this change lands) is activated, its
`release/deploy/devide.service` will contain the full up-to-date header
comments; you can then `cp` it again (or just re-run activation) to refresh
the comments in the stable copy.

## Files

| File | Purpose |
|------|---------|
| `devide.service` | systemd unit — Postgres-up + migrate + release boot |
| `docker-compose.postgres.yml` | Dedicated Postgres, loopback `127.0.0.1:15432` |
| `devide.env.example` | Environment template → `/etc/devide/devide.env` |
| `README.md` | This file (self-documenting runbook) |

These 4 files are the **canonical source** (in `lib/dev_ide/integrations/manager/deploy/`
in the repo, symlinked via `rel/overlays/deploy/` so they are carried inside
every release tarball at `<release-root>/deploy/`).

**After activation** they live at the stable `/opt/devide/deploy/` on the host.
The installed unit (`/etc/systemd/system/devide.service`) is a copy of the one
from stable deploy/. All references in the unit use `/opt/devide/deploy/` for
the compose file so that future release swaps never invalidate `ExecStartPre`.

See the "Reconcile current broken DevBox" section above for the one-time
commands that fix a box that still has a pre-7204683 unit.
