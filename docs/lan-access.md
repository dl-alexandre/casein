# LAN Access

DevIDE's normal development server is loopback-only. DevIDE LAN is the
product-like local-network mode for a single trusted machine on a trusted LAN.

For the simple dogfood path, use plain HTTP on the LAN:

```bash
mise exec -- mix dev_ide.lan.up
```

Then open:

```text
http://<hostname>.local/
```

On this host, for example:

```text
http://r630.local/
```

Check or stop it with:

```bash
mise exec -- mix dev_ide.lan.status
mise exec -- mix dev_ide.lan.down
```

`lan up` prints ready only after the managed backend service is active, the
port-80 edge is active, and an HTTP probe through the LAN hostname succeeds.
The status block always prints an IP fallback such as `http://192.168.1.240/`.

## Release Install Path

For a built release, LAN mode is exposed by the release helper, not Mix:

```bash
sudo ./bin/devide lan up
```

Build LAN-local releases with the SQLite repo profile:

```bash
CASEIN_REPO_ADAPTER=sqlite MIX_ENV=prod mix dev_ide.release.lan
```

or, when using the containerized release builder:

```bash
CASEIN_REPO_ADAPTER=sqlite ./scripts/build-release.sh
```

`dev_ide.release.lan` installs the frontend npm dependencies, installs the
preview helper npm dependencies, runs `assets.deploy`, and then assembles the
release. A plain `mix release dev_ide` will now fail fast if the CSS/JS bundles
or `cache_manifest.json` are missing, because a release without those files
boots but renders an unstyled page.

`lan up` is idempotent. It first copies the release into a durable install path
(`/opt/devide/lan-release` by default), then creates or refreshes
`/etc/devide/lan.env`, installs the backend and port-80 edge units, starts them,
and probes both the real URL and `/assets/css/app.css` before printing `READY`.

Existing values in `/etc/devide/lan.env` are preserved. Upgrades refresh the
systemd unit files so they point at the durable release copy, while local env
overrides such as `DATABASE_PATH`, `DATABASE_URL`, `PORT`, `CASEIN_LAN_HOST`, and
`CASEIN_WORKSPACES_ROOT` remain intact. By default, `lan up` also writes
`CASEIN_HOME_WORKSPACE_PATH` to the LAN service user's home directory, so the
initial `home` workspace opens at the actual home directory rather than an empty
seed folder.

If the source release lives under `/tmp`, the installed systemd units still point
at `/opt/devide/lan-release`, so a reboot or tmp cleanup does not break the
managed backend. Set `DEVIDE_LAN_RELEASE_DIR=/some/durable/path` to choose a
different install location.

Useful release commands:

```bash
sudo ./bin/devide lan install
/opt/devide/lan-release/bin/devide lan status
sudo /opt/devide/lan-release/bin/devide lan down
```

`lan down` stops only the managed systemd units. It does not scan for or kill
unrelated manual `mix phx.server` or release processes.

The release service runs:

```text
/opt/devide/lan-release/bin/dev_ide start
```

with the LAN service profile from `/etc/devide/lan.env`. If your database is
not the local SQLite default, set `DATABASE_PATH` before `lan up` or edit the
env file and run `lan up` again:

```bash
sudo DATABASE_PATH=/var/lib/devide/lan/devide.sqlite3 \
  ./bin/devide lan up
```

Postgres is still supported for server-style releases by compiling with the
default `CASEIN_REPO_ADAPTER=postgres` profile and setting `DATABASE_URL`.

## What `lan up` Owns

`lan up` installs and starts three systemd units:

```text
devide-lan.service            -> runs the Phoenix backend as your user
devide-lan-http-edge.socket   -> listens on LAN port 80
devide-lan-http-edge.service  -> proxies :80 to the loopback backend
```

The edge service requires the backend service, so port-80 traffic is not
considered healthy unless DevIDE itself is running. The backend service uses the
LAN profile internally:

```text
CASEIN_LAN_INSECURE_HTTP=true
CASEIN_LAN_DIRECT_MODE=true
CASEIN_LAN_FRIENDLY_PATHS=true
CASEIN_LAN_PATH_ROOT=/home/<user>
CASEIN_DEFAULT_WORKSPACE=home
CASEIN_HOME_WORKSPACE_PATH=/home/<user>
PORT=4000
```

Those are implementation details for the service profile, not the normal user
interface. The checkout/Mix task uses `mise exec -- mix phx.server`; the
release helper uses the release's `bin/dev_ide start`. The default direct
workspace is the service user's home directory:

```text
/home/<user>
```

## Requirements

DevIDE LAN expects:

- Linux with systemd and `systemd-socket-proxyd`.
- `mise` available only for the checkout/Mix workflow. A built release does
  not need Mix or mise at runtime.
- A writable SQLite database path for LAN-local releases. The default is
  `/var/lib/devide/lan/devide.sqlite3`, and `lan up` creates its parent
  directory.
- Postgres reachable by `DATABASE_URL` only for Postgres-compiled releases or
  the default checkout/Mix workflow.
- TCP port `80` allowed through the host firewall.
- `<hostname>.local` resolving from the client device, usually via Avahi or
  Bonjour.

On Arch, useful packages/services are:

```bash
sudo pacman -S avahi nss-mdns
sudo systemctl enable --now avahi-daemon.service
```

If another device times out, allow HTTP through the firewall:

```bash
sudo ufw allow 80/tcp
```

## Administrator Access

The Mix task itself should be run as your normal user:

```bash
mise exec -- mix dev_ide.lan.up
```

It uses `sudo` only for systemd unit installation, service control, and the
firewall rule. If sudo cannot run non-interactively, it prints a short prompt.
Run:

```bash
sudo -v
mise exec -- mix dev_ide.lan.up
```

Avoid `sudo mise exec -- mix ...`; that builds as root and can leave root-owned
artifacts under the checkout.

## Common Options

```bash
# Use another direct workspace
mise exec -- mix dev_ide.lan.up --workspace dev_ide

# Use another workspace root
mise exec -- mix dev_ide.lan.up --workspaces-root /data/devide-workspaces

# Point the built-in "home" workspace somewhere else
mise exec -- mix dev_ide.lan.up --home-workspace-path "$HOME"

# Use another LAN hostname for status probes and generated URLs
mise exec -- mix dev_ide.lan.up --host devide.home.arpa

# Avoid firewall changes
mise exec -- mix dev_ide.lan.up --no-firewall

# Use a different backend port if :4000 is occupied
mise exec -- mix dev_ide.lan.up --backend-port 4010
```

## Trusted HTTPS

Plain HTTP is easiest on a private LAN, but it is not encrypted. Anyone on the
LAN path can observe or tamper with browser traffic, cookies, and terminal
interaction.

For trusted local HTTPS, install `mkcert`, then run the doctor:

```bash
# Arch
sudo pacman -S mkcert nss

mise exec -- mix dev_ide.doctor --fix
```

The doctor creates/checks the default workspace, generates:

```text
priv/cert/devide-lan.pem
priv/cert/devide-lan-key.pem
```

and imports the mkcert CA into the host user's trust stores when possible.

Start HTTPS LAN mode manually with:

```bash
CASEIN_LAN=true mise exec -- mix phx.server
```

Then open:

```text
https://<hostname>.local:4443/
```

For portless HTTPS:

```bash
mise exec -- mix dev_ide.doctor --fix --edge
CASEIN_LAN=true mise exec -- mix phx.server
```

Then open:

```text
https://<hostname>.local/
```

Client devices must trust the same mkcert root CA before browsers will treat
the HTTPS URL as secure. Export or copy this file from the DevIDE host:

```bash
mkcert -CAROOT
```

Install `rootCA.pem` on the client device. Never copy `rootCA-key.pem`; that is
the private signing key.

## Local Domains

The default LAN URL uses the host's mDNS name:

```text
<hostname>.local
```

DevIDE also supports a same-host hosts-file domain:

```text
devide.test
```

`.test` is used because `.local` is owned by mDNS on many Linux desktops and a
`/etc/hosts` entry for `devide.local` may be ignored. To prepare the hosts-file
mapping:

```bash
mise exec -- mix dev_ide.doctor --fix
```

To choose a different same-host name:

```bash
CASEIN_LOCAL_DOMAIN=devide.home.arpa mise exec -- mix dev_ide.doctor --fix
```

## Internals

| Variable | Default | Purpose |
|---|---|---|
| `CASEIN_LAN_INSECURE_HTTP` | set by `lan up` | Enables the no-cert LAN HTTP service profile. |
| `CASEIN_LAN_INSECURE_HTTP_PORT` | `80` | Port exposed by the LAN HTTP edge. |
| `PORT` | `4000` | Loopback backend port used by `devide-lan.service`. |
| `CASEIN_LAN_HOST` | `<hostname>.local` | Endpoint URL host used for generated URLs. |
| `CASEIN_LAN_DIRECT_MODE` | enabled by LAN profiles | Set to `false` only for manual runs that should keep `/` on the workspace picker. |
| `CASEIN_LAN_FRIENDLY_PATHS` | enabled by LAN profiles | Lets `/` and `/<dir>` open filesystem-addressed workspaces under `CASEIN_LAN_PATH_ROOT`. |
| `CASEIN_LAN_PATH_ROOT` | `CASEIN_HOME_WORKSPACE_PATH` | Root for LAN-friendly URL paths. `/aws` resolves to `$CASEIN_LAN_PATH_ROOT/aws`. |
| `CASEIN_DEFAULT_WORKSPACE` | `home` | Workspace id or local workspace name for direct drop-in. |
| `CASEIN_WORKSPACES_ROOT` | `/tmp/dev_ide_workspaces` in dev | Parent directory for local filesystem workspaces. |
| `DATABASE_PATH` | `/var/lib/devide/lan/devide.sqlite3` in release | SQLite database file for LAN-local releases. |
| `DATABASE_URL` | Postgres fallback | Used by Postgres-compiled releases, ignored by SQLite-compiled releases. |
| `DEVIDE_LAN_ENV_FILE` | `/etc/devide/lan.env` in release | Private env file owned by the release `devide lan` helper. |
| `DEVIDE_LAN_PUBLIC_ENV_FILE` | `/etc/devide/lan.public.env` in release | Non-secret status env readable by non-root `lan status`. |
| `DEVIDE_LAN_RELEASE_DIR` | `/opt/devide/lan-release` in release | Durable release copy used by managed systemd units. |
| `CASEIN_LAN` | unset | Enables manual HTTPS LAN mode. |
| `CASEIN_LAN_HTTPS_PORT` | `4443` | Manual HTTPS backend port. |
| `CASEIN_LAN_CERTFILE` | `priv/cert/devide-lan.pem` | Manual HTTPS certificate path. |
| `CASEIN_LAN_KEYFILE` | `priv/cert/devide-lan-key.pem` | Manual HTTPS private key path. |

## Troubleshooting

If `lan status` reports that the backend service is inactive:

```bash
journalctl -u devide-lan.service -n 100 --no-pager
```

If `lan status` says `NOT READY` but also reports `manual backend
detected`, the URL works through a manually started `mix phx.server`, not
through `devide-lan.service`. Run `mise exec -- mix dev_ide.lan.up` to move that
working state under systemd.

If `http://<hostname>.local/` times out but the IP fallback works, fix mDNS or
local DNS for the hostname. On Linux, make sure Avahi is running and the client
can resolve the host.

If `lan up` fails because port `80` is already occupied, it prints the managed
LAN status block and recent backend logs instead of reporting ready. Stop the
conflicting service or choose another `CASEIN_LAN_INSECURE_HTTP_PORT`.

If the database is unavailable, the backend service will fail during
`bin/migrate` or boot; `lan up` reports `NOT READY` and includes recent
`devide-lan.service` logs. For LAN-local SQLite releases, check that
`DATABASE_PATH` points at a writable location. For Postgres-compiled releases,
check `DATABASE_URL` and the database service.

If a manual backend is already using `:4000`, `lan up` cannot start the managed
backend on the same port. Either stop the manual process or set a different
`PORT` in `/etc/devide/lan.env` and run `lan up` again.

If the browser rapidly reloads after switching between HTTPS and HTTP modes,
clear site data for the LAN host. The managed HTTP service uses a separate
cookie key, but old browser state from earlier experiments can still confuse an
open tab.

If you previously ran a manual backend with `mix phx.server`, stop it before
using `lan up` if it occupies the same backend port.

## Trust Boundary

DevIDE LAN exposes the cockpit to other devices on the local network. Use it
only on networks you trust. API and MCP endpoints keep their bearer-token
checks, but the browser cockpit remains the same local-dev operator surface.
