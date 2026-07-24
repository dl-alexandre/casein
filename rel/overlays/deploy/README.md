# Casein on devbox — deployment (§5)

Deploys one shared DevIDE instance on the devbox EC2 host, served behind the
existing Caddy + oauth2-proxy front door and scoped per-user. This is the
**Dashboard model** — a sibling of the manager Dashboard route, not a
per-workspace process.

Full design and historical context: see `docs/integrations/manager.md` §5 and the
authoritative on-host runbook at `/opt/casein/deploy/README.md` (this file)
after the post-7204683 stable-layout reconciliation.

## Shape

| Decision | Choice | Why |
|----------|--------|-----|
| Admin view | Mirror the manager's `admins` list + `?all=true` | Manager already filters server-side; DevIDE just forwards the flag |
| Database | Dedicated Postgres **container** | Isolated from the shared dev pg; one named volume to back up |
| Supervision | **systemd unit** (host process) | Native `/data/workspaces` + docker-socket access; matches `devbox-manager` |
| Build host | **The devbox itself, in a container** | Devbox has `docker` but no host Elixir/Erlang. `scripts/build-release.sh` runs the Dockerfile's `builder` stage and extracts the release tree — same pinned toolchain as the production image, no host installs. |
| Deploy artifacts | **Bundled inside every release** at `<release>/deploy/`; copied to **stable host dir** on activation | Canonical source lives in `lib/casein/integrations/manager/deploy/`; the `rel/overlays/deploy/` symlink set ships them with every `mix release`. An explicit activation step then copies the fresh artifacts into the stable `/opt/casein/deploy/` (release-independent). This is the "C then B" reconciliation after 7204683. |

DevIDE binds **loopback only** (`PHX_IP=127.0.0.1`). It trusts the
`X-Auth-Request-*` headers Caddy sets — so it must be unreachable except
through Caddy. Never publish `PORT` outside the host.

## Host layout (stable after 7204683 reconciliation)

```
/opt/casein/
  deploy/                # STABLE, release-independent. Contains the 4 artifacts:
                         #   casein.service, docker-compose.postgres.yml,
                         #   devide.env.example, README.md
                         # Populated by the activation step from the release's
                         # bundled <release>/deploy/ copy. The installed unit
                         # and all ExecStartPre paths reference this dir.
  release/               # extracted `mix release` output → release/bin/casein
                         # (also contains its own copy of deploy/ for the next
                         # activation or rollback)
  release.prev/          # (optional) previous release for fast rollback
/etc/casein/devide.env   # EnvironmentFile, chmod 600 (populated once at first
                         # deploy from the example in deploy/)
```

**Why the stable sibling directory?** Keeping deploy artifacts *inside* the
release tree (`release/deploy/`) would have left the installed unit
(`/etc/systemd/...`) pointing at a directory that operators routinely `mv` or
`rm -rf` during updates and rollbacks. The first `git pull` or release swap
after 7204683 would then make `ExecStartPre` (the compose step) fail with
"no such file or directory" — exactly what happened on the real DevBox for
cd0aed5 and 4c308b8. The sibling `/opt/casein/deploy/` + deliberate activation
step guarantees the unit and compose file survive release swaps while still
being version-locked and shipped inside every tarball.

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

   The output tree includes `release-out/deploy/{casein.service,
   docker-compose.postgres.yml, devide.env.example, README.md}` — bundled
   from `rel/overlays/deploy/`.

2. **Place the release on the devbox** (extracted tree becomes the active release):

   ```sh
   sudo mkdir -p /opt/casein && sudo chown devbox:devbox /opt/casein
   sudo rm -rf /opt/casein/release
   sudo cp -a release-out /opt/casein/release
   sudo chown -R devbox:devbox /opt/casein/release
   ```

   (If built off-box, scp the `release-out/` tree to the devbox first.)

3. **Activation step** (the key reconciliation step — copies deploy artifacts
   from the just-placed release into the stable location and installs the unit):

   ```sh
   sudo mkdir -p /opt/casein/deploy
   sudo chown devbox:devbox /opt/casein/deploy
   sudo cp -a /opt/casein/release/deploy/. /opt/casein/deploy/
   sudo chown -R devbox:devbox /opt/casein/deploy
   sudo cp /opt/casein/deploy/casein.service /etc/systemd/system/casein.service
   sudo systemctl daemon-reload
   ```

   This ensures the unit's `ExecStartPre` (for the compose file) and future
   references always use the stable `/opt/casein/deploy/...` paths.

   **Optional one-command helper** (shipped inside every release at
   `bin/activate_devbox_deploy` via `rel/overlays/bin/` and also exercised by
   `scripts/build-release.sh`):

   ```sh
   sudo /opt/casein/release/bin/activate_devbox_deploy
   ```

   The helper performs the exact `mkdir`/`chown`/`cp -a`/`chown -R`/unit-refresh
   sequence above (including the safety fixes from this round) and then prints
   the remaining `systemctl` commands. The explicit multi-line commands in the
   block above remain the documented source of truth for operators who prefer
   full visibility.

4. **Environment file** (first time only; later updates edit in place):

   ```sh
   sudo mkdir -p /etc/casein
   sudo cp /opt/casein/deploy/devide.env.example /etc/casein/devide.env
   sudo chmod 600 /etc/casein/devide.env
   sudoedit /etc/casein/devide.env
   ```

   Fill in `SECRET_KEY_BASE`, `CASEIN_API_TOKEN` (both `mix phx.gen.secret`),
   `DEVIDE_PG_PASSWORD`, and `DATABASE_URL`. **`DATABASE_URL` must encode the
   same user/password/db as the `DEVIDE_PG_*` vars** — and use a URL-safe
   password (letters + digits; `@ : / #` break URL parsing).

   For full Preview MCP browser automation, keep
   `CASEIN_PREVIEW_CONTROL_ADAPTER=playwright`. The release bundles the
   Playwright helper and npm dependency; install Chromium once for the service
   user after the release is placed:

   ```sh
   cd /opt/casein/release/lib/casein-*/priv/scripts
   sudo -u devbox env HOME=/home/devbox node node_modules/playwright/cli.js install chromium
   ```

5. **Pre-pull the Postgres image** so the unit's `--wait` step isn't also
   waiting on a download the first time:

   ```sh
   docker pull postgres:16-alpine
   ```

6. **Start the Postgres container** by hand once, to confirm it comes up
   healthy before involving systemd:

   ```sh
   docker compose \
     -f /opt/casein/deploy/docker-compose.postgres.yml \
     --env-file /etc/casein/devide.env up -d --wait
   docker compose -f /opt/casein/deploy/docker-compose.postgres.yml ps
   ```

7. **Enable + start the systemd unit:**

   ```sh
   sudo systemctl enable --now devide
   sudo journalctl -u devide -f
   ```

   On start the unit: brings up + waits for the Postgres container, runs
   `bin/migrate`, then boots the release. A bad env file or failed migration
   surfaces as a `failed` unit after 5 quick retries — not an infinite loop.

8. **Verify** — see the next section. Do this *before* exposing via Caddy.

9. **Caddy route (§1)** — last, and a separate change in the **milc-devbox**
   repo. It flips public exposure on. Do not do it until step 8 passes on a
   real deploy. See `docs/integrations/manager.md` §5 for design and the
   living `/opt/casein/deploy/README.md` for operator commands.

## Verification

DevIDE binds loopback, so until §1 lands it's reachable only from the host:

```sh
systemctl is-active devide                 # → active
curl -fsS http://127.0.0.1:4000/ -o /dev/null && echo "DevIDE responding"
docker compose -f /opt/casein/deploy/docker-compose.postgres.yml ps
                                           # → postgres ... (healthy)
sudo journalctl -u devide --since "5 min ago" | grep -i migrat
                                           # → migrations ran (or "already up")
```

This is a safe live test of §2/§3: hit it from the host, confirm it serves and
talks to its DB, with nothing exposed to the network.

## Updating

```sh
# Build a new release (in a checkout of dev_ide on the build host):
./scripts/build-release.sh

# For zero-surprise updates, keep the previous release so rollback is a `mv` back.
sudo mv /opt/casein/release /opt/casein/release.prev
sudo cp -a release-out /opt/casein/release
sudo chown -R devbox:devbox /opt/casein/release

# Activation step: copy fresh deploy artifacts from the *new* release into the
# stable dir (this also refreshes the unit file if the template changed).
sudo mkdir -p /opt/casein/deploy
sudo chown devbox:devbox /opt/casein/deploy
sudo cp -a /opt/casein/release/deploy/. /opt/casein/deploy/
sudo chown -R devbox:devbox /opt/casein/deploy
sudo cp /opt/casein/deploy/casein.service /etc/systemd/system/casein.service
sudo systemctl daemon-reload

sudo systemctl restart devide              # re-runs migrate, reboots the release
```

The activation step is what makes the paths future-proof. The unit file on disk
(now at `/etc/systemd/system/casein.service`) and the stable deploy/ dir are
always refreshed from the release being activated.

## GitHub Actions deployment

The repository includes `.github/workflows/deploy-devbox.yml`, which runs on
pushes to `master` and can also be started manually with `workflow_dispatch`.
It builds the same release tree with `scripts/build-release.sh`, packages it as
a tarball, copies it to the devbox host over SSH, and runs
`scripts/deploy-devbox-release.sh` remotely. If the SSH secrets are not
configured yet, the workflow still builds and uploads the release artifact, then
skips the devbox deploy step with a warning.

Required repository secrets:

| Secret | Purpose |
|--------|---------|
| `DEVBOX_SSH_HOST` | Devbox SSH hostname or IP. |
| `DEVBOX_SSH_USER` | SSH user, normally `devbox`. |
| `DEVBOX_SSH_PRIVATE_KEY` | Private key with SSH access to the devbox user. |
| `DEVBOX_SSH_KNOWN_HOSTS` | Pinned `known_hosts` line for the devbox host. |
| `DEVBOX_SSH_PORT` | Optional. Defaults to `22` when omitted. |

The remote deploy script extracts to a staging directory, validates the release
shape, moves the current release to `/opt/casein/release.prev`, activates the
new release's deploy artifacts, ensures Chromium is installed for the service
user when the Playwright helper is present, starts a canary instance on a
per-deploy Unix socket, and smoke checks `/api/workspaces` plus the Preview and
Terminal MCP `tools/list` calls. Only after the canary is healthy does it point
`/run/casein/current.sock` at the new socket and ask old instances to drain. If
activation or smoke checks fail after the release swap starts, it restores both
`release.prev` and the pre-canary `/etc/casein/devide.env` so the stable
`casein.service` can still boot the prior release.

## Rollback

```sh
# Code rollback — restore the previous release tree + its deploy artifacts.
sudo systemctl stop devide
rm -rf /opt/casein/release && mv /opt/casein/release.prev /opt/casein/release

# If rolling back from a socket-canary deploy to an older loopback release,
# remove the canary listener overrides so the service binds PORT again.
sudo sed -i '/^DEVIDE_HTTP_SOCKET=/d; /^DEVIDE_INSTANCE_UUID=/d' /etc/casein/devide.env

# Re-activate the *previous* release's deploy artifacts (in case the compose
# file or unit template differed) so stable paths and unit stay consistent.
sudo mkdir -p /opt/casein/deploy
sudo chown devbox:devbox /opt/casein/deploy
sudo cp -a /opt/casein/release/deploy/. /opt/casein/deploy/
sudo chown -R devbox:devbox /opt/casein/deploy
sudo cp /opt/casein/deploy/casein.service /etc/systemd/system/casein.service
sudo systemctl daemon-reload
sudo systemctl start devide

# Full teardown — if the deployment must be undone entirely.
sudo systemctl disable --now devide
sudo rm /etc/systemd/system/casein.service && sudo systemctl daemon-reload
docker compose -f /opt/casein/deploy/docker-compose.postgres.yml down
# The DB volume SURVIVES `down`. To discard data too: add `-v`.
```

Note: a migration that ran on update is **not** reverted by a code rollback.
If an update includes a destructive migration, snapshot the DB first (below).

## Backups

DevIDE's state — including the audit log, a security record — lives in the
`casein_pgdata` Docker volume. Snapshot it before risky updates:

```sh
docker exec devide-postgres-1 pg_dump -U dev_ide dev_ide_prod \
  | gzip > /opt/casein/backup-$(date +%F).sql.gz
```

Restore into a fresh container with `gunzip -c … | docker exec -i
devide-postgres-1 psql -U dev_ide dev_ide_prod`.

## Reconcile current broken DevBox (post-7204683, 4c308b8 / cd0aed5 era)

The real DevBox is currently running release `4c308b8` (Ghostty inline snapshot
work) but its installed `/etc/systemd/system/casein.service` (and possibly the
runbook in use) still contains the **pre-7204683** `ExecStartPre` that hard-coded
the old `repo/deploy/devbox/` layout that disappeared after the rename.

A bad tree is preserved at `/opt/casein/release.bad` for inspection.

**One-time reconciliation commands** (run on the devbox via
`ssh devbox@devbox.milcgroup.com`):

```sh
# 1. Stop the broken unit so we can safely touch paths.
sudo systemctl stop devide || true

# 2. Ensure the parent tree exists and is owned correctly (mirrors the
#    "Place the release" step in First deployment). Then seed the stable
#    deploy/ directory from the current (or bad) release tree. The 4 files
#    are guaranteed to exist because they were bundled inside the release
#    tarball at build time.
sudo mkdir -p /opt/casein && sudo chown devbox:devbox /opt/casein
sudo mkdir -p /opt/casein/deploy
CURRENT_RELEASE=/opt/casein/release
if ! sudo cp -a "${CURRENT_RELEASE}/deploy/." /opt/casein/deploy/; then
  echo ">>> Primary release deploy/ copy failed; falling back to release.bad"
  CURRENT_RELEASE=/opt/casein/release.bad
  sudo cp -a "${CURRENT_RELEASE}/deploy/." /opt/casein/deploy/
fi
sudo chown -R devbox:devbox /opt/casein/deploy

# 3. Install a *corrected* unit file whose ExecStartPre uses the new stable
#    /opt/casein/deploy/ path for the compose file (and release/ for bins).
#    We write it fresh so it is guaranteed to have the post-reconciliation paths
#    even if the bundled service inside 4c308b8 still had the intermediate
#    /release/deploy/ references.
sudo tee /opt/casein/deploy/casein.service > /dev/null << 'UNITEOF'
# DevIDE-on-devbox systemd unit (reconciled after 7204683).
# (full header comments elided for the here-doc; see the file in the next
# release or in the repo for the complete documented version)
[Unit]
Description=Casein — shared on-devbox IDE
Documentation=https://github.com/dl-alexandre/dev_ide/blob/master/lib/casein/integrations/manager/deploy/README.md
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
User=devbox
Group=docker
EnvironmentFile=/etc/casein/devide.env
WorkingDirectory=/opt/casein

# Stable paths (the whole point of the reconciliation):
ExecStartPre=/usr/bin/docker compose -f /opt/casein/deploy/docker-compose.postgres.yml --env-file /etc/casein/devide.env up -d --wait
ExecStartPre=/opt/casein/release/bin/migrate
ExecStart=/opt/casein/release/bin/casein start
ExecStop=/opt/casein/release/bin/casein stop

TimeoutStartSec=300
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/data/workspaces /opt/casein

[Install]
WantedBy=multi-user.target
UNITEOF

sudo cp /opt/casein/deploy/casein.service /etc/systemd/system/casein.service
sudo systemctl daemon-reload

# 4. (Re)start. The first start will exercise the new stable ExecStartPre.
sudo systemctl start devide
sudo journalctl -u devide -f
```

After this, the box is on the stable layout. Future releases only need the
normal "place release + activation step + restart" sequence; the unit will
automatically pick up new deploy artifacts (including any evolution of the
unit template itself) because activation always re-copies the service file.

Once a *new* release (built after this change lands) is activated, its
`release/deploy/casein.service` will contain the full up-to-date header
comments (including the rich post-7204683 history and stable-layout contract
that the one-time `tee` above deliberately kept terse for the broken box).
You can then `cp` it again (or just re-run activation) to refresh the comments
in the stable copy. The next activation from any post-reconciliation release
will automatically restore the complete documented header.

## Files

| File | Purpose |
|------|---------|
| `casein.service` | systemd unit — Postgres-up + migrate + release boot |
| `docker-compose.postgres.yml` | Dedicated Postgres, loopback `127.0.0.1:15432` |
| `devide.env.example` | Environment template → `/etc/casein/devide.env` |
| `README.md` | This file (self-documenting runbook) |

These 4 files are the **canonical source** (in `lib/casein/integrations/manager/deploy/`
in the repo, symlinked via `rel/overlays/deploy/` so they are carried inside
every release tarball at `<release-root>/deploy/`). An additional convenience
helper `bin/activate_devbox_deploy` is shipped under `<release-root>/bin/`
(via `rel/overlays/bin/`) and documented in the Activation step above.

**After activation** they live at the stable `/opt/casein/deploy/` on the host.
The installed unit (`/etc/systemd/system/casein.service`) is a copy of the one
from stable deploy/. All references in the unit use `/opt/casein/deploy/` for
the compose file so that future release swaps never invalidate `ExecStartPre`.

See the "Reconcile current broken DevBox" section above for the one-time
commands that fix a box that still has a pre-7204683 unit.
