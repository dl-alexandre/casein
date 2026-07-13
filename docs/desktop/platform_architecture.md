# Desktop platform architecture

## Release requirement

Published DevIDE desktop releases are native, self-contained artifacts for their
target operating system. WSL, containers, and remote Linux hosts may be used for
development, but a Windows release must function when WSL is unavailable.

The Phoenix/LiveView application remains the product runtime and the browser or
embedded WebView remains its cockpit. The desktop host owns installation,
startup, windowing, updates, and crash recovery; it does not become a second
application backend.

This profile is part of the portable public product core described by GitHub
issue #248. It must contain no MILC topology, identity, domain, checkout path,
service-name, or private-repository defaults. Those belong in a separately
versioned private operator overlay that consumes documented public interfaces.

Desktop starts with `deployment_capabilities: []`. Devbox-oriented deployment
drift, poller, socket, and reverse-proxy diagnostics are optional capabilities,
not product-health requirements. When no provider is configured they remain
inactive rather than warning about missing tmux anchors, Caddy, pollers, or an
internal Git remote.

## Platform boundary

DevIDE currently models terminal topology in tmux terms. Cross-platform releases
must instead expose product-level session, window, pane, process, and terminal
operations through behaviours whose implementations are selected for the host.

| Boundary | Linux | macOS | Windows |
|---|---|---|---|
| Terminal/PTY | tmux adapter | native PTY or tmux adapter | ConPTY adapter |
| Process tree | process groups/systemd where installed | process groups/launchd | Job Objects |
| Service lifecycle | desktop host or systemd | desktop host or launchd | desktop host or Windows service |
| IPC | loopback TCP or Unix socket | loopback TCP or Unix socket | loopback TCP or named pipe |
| Shell discovery | user shell/bash | user shell/zsh | PowerShell/cmd |
| Data directory | XDG data home | Application Support | LocalAppData |
| Path model | POSIX | POSIX | drive, UNC, and extended paths |
| Status/readiness publication | `runtime.json` in data dir + loopback health route | `runtime.json` in data dir + loopback health route | `runtime.json` in data dir + loopback health route |

tmux remains a supported Linux implementation. It must not be required by the
LiveView, MCP, agent, preview, or persistence contracts.

## Required behaviours

The first extraction should define narrow behaviours rather than one broad
platform module:

- `DevIDE.Terminals.Backend`: create, attach, resize, input, capture, topology,
  and terminate terminal sessions.
- `DevIDE.Processes.Backend`: spawn and terminate complete process trees and
  report exit status.
- `DevIDE.Platform.Paths`: application data, cache, logs, workspace paths, and
  path normalization.
- `DevIDE.Platform.Shell`: default shell and command-line construction.
- `DevIDE.Platform.Lifecycle`: readiness publication and graceful shutdown.

The first terminal boundary is now present as `DevIDE.Terminals.Backend`, with
`DevIDE.Terminals.Backends.Tmux` adapting the existing implementation. Backend
selection uses `config :dev_ide, :terminal_backend`; the older
`:tmux_adapter` test and compatibility key is used as a migration fallback
while call sites are moved in small slices. Durable session naming, existence
checks, replay capture, initial size discovery, and initial resize now cross
this boundary. PTY process spawning now crosses it through
`DevIDE.Terminals.Backend.SpawnSpec`; the tmux backend owns host, container, and
remote SSH command construction. The next native-Windows seam is the transport
that executes a spawn spec, writes input, resizes the PTY, and terminates its
process tree.

Product code consumes these boundaries. Host-specific adapters may use ports,
NIFs, or sidecars, but those implementation details do not leak into LiveView or
MCP schemas.

## Existing portability inventory

The initial repository scan found host coupling concentrated in these areas:

1. `lib/tmux_ctl/` and `lib/dev_ide/terminals/tmux*.ex` implement the current
   topology and mutation engine.
2. Terminal sessions, templates, agent panes, and LiveView events expose tmux
   pane/window identifiers and commands beyond the adapter layer.
3. `lib/dev_ide/terminals/shims.ex`, agent launchers, preview launchers, and most
   `scripts/` utilities assume Bash and POSIX command construction.
4. Deploy, LAN, cleanup, and janitor paths assume systemd, Unix signals, `/proc`,
   Unix permissions, or Unix sockets.
5. Workspace, preview, and file-link paths require an explicit Windows path
   model instead of POSIX string assumptions.

The extraction should begin at terminal creation/attachment and process-tree
termination. Rewriting deployment scripts is not required for the first native
Windows vertical slice.

## Native Windows vertical slice

The first Windows milestone is intentionally narrow:

1. Assemble and start a Windows OTP release compiled with SQLite.
2. Bind Phoenix only to loopback on an ephemeral port.
3. Start PowerShell through a ConPTY-backed terminal adapter.
4. Stream bytes through the existing terminal transport and browser renderer.
5. Support input, resize, replay, reconnect, and complete process-tree shutdown.
6. Persist the selected workspace and runtime state under LocalAppData.
7. Start, use, reconnect to, and stop DevIDE with WSL disabled.

Agent runtimes, preview automation, multi-pane parity, service installation, and
auto-update follow only after this slice is reliable.

## macOS desktop host: menu bar extra first

The first native macOS surface is a menu bar extra (status item), not a
windowed application. DevIDE's desktop shape — a long-running loopback daemon
with a browser cockpit — matches the Docker Desktop/OrbStack model, and the
status item directly fixes the release's current UX gaps: manual
`bin/migrate && bin/dev_ide daemon` startup, an undiscoverable ephemeral port
(`PORT=0`), the epmd "name in use" restart race, no autostart, and no visible
health. The app's main menu (File/Edit/Window) only becomes relevant once an
embedded webview window exists; see "Later: windowed cockpit" below.

The host obeys the platform boundary above: it execs the release, reads the
status file, probes a health endpoint, and opens URLs. It holds no product
state and speaks no BEAM protocol. Holding that contract keeps the host
framework choice cheap to change.

### Status contract

`DevIDE.Desktop.Runtime.status_path/0` already names the file
(`<data_dir>/runtime.json`); nothing writes it yet. The desktop profile must:

- Write `runtime.json` when the endpoint is bound, atomically
  (write to a temp file in the same directory, then rename).
- Remove it on graceful shutdown. Hosts must treat a file whose `pid` is not
  alive as stale, since crashes leave it behind.
- Serve an unauthenticated loopback readiness route (`GET /desktop/health`)
  the host can poll. Outside the desktop profile the route returns 404 so no
  version metadata leaks from networked deployments.

Schema (versioned so hosts can reject what they don't understand):

```json
{
  "schema": 1,
  "status": "ready",
  "port": 54321,
  "base_url": "http://127.0.0.1:54321",
  "pid": 12345,
  "version": "0.9.0",
  "revision": "abc1234",
  "started_at": "2026-07-12T18:00:00Z"
}
```

`status` is one of `starting | ready | stopping | unhealthy | stopped`; v1
only ever writes `ready` (the file appears when the endpoint is bound and
disappears on shutdown), but hosts must tolerate the full set. `version` and
`revision` come from `DevIDE.Release.Metadata`, not a second source. Live
uptime deliberately does not live in the file — a file written once at boot
would carry a permanently stale value — the health route reports `uptime_ms`
and the host can derive it from `started_at` otherwise.

`GET /desktop/health` mirrors the published identity plus live uptime, and
deliberately omits `pid`:

```json
{
  "status": "ready",
  "port": 54321,
  "base_url": "http://127.0.0.1:54321",
  "version": "0.9.0",
  "revision": "abc1234",
  "uptime_ms": 123456
}
```

Implementation: `DevIDE.Desktop.Status` (writer, reader, `runtime.json`
lifecycle) and `DevIdeWeb.DesktopHealthController`; the supervision wiring
lives in `DevIde.Application.desktop_status/0`.

The host must provide the release's environment (learned from the first
desktop-profile boot): `DEV_IDE_PROFILE=desktop`, a generated-and-persisted
`SECRET_KEY_BASE` and `DEV_IDE_API_TOKEN` (boot refuses to start without the
token), and optionally `DEV_IDE_DESKTOP_DATA_DIR`. It should also set a
distinct `RELEASE_NODE` if anything else on the machine may register a
`dev_ide` node with epmd — a stale node holds the default name and start
fails with "name in use".

### Host responsibilities (v1 menu)

- Status header: running/starting/stopped/unhealthy, version, bound port.
  Icon state mirrors it (template image so it renders in light/dark menubars).
- Open DevIDE: opens `base_url` in the default browser. A recent-workspaces
  submenu reuses the existing deep-link scheme (`docs/deep_links.md`).
- Start / Stop / Restart: the host owns the release process tree. Restart is
  explicitly: graceful stop, wait for the process tree to exit, wait for epmd
  to drop the `dev_ide` name (poll with timeout — this is the documented
  "name in use" failure), run `bin/migrate`, start fresh. Crash restarts use
  bounded backoff.
- Copy MCP endpoint / agent pairing info.
- Open logs, open data folder.
- Start at Login (SMAppService on macOS).
- Quit stops the server by default; an option-key variant quits the host and
  leaves the server running.

The host app is `LSUIElement` (no Dock icon), bundled and signed as a proper
`.app`. The Bun/tailwind codesign lesson applies to every executable the
bundle carries.

### Host framework

Tauri v2 (tray, autostart, updater plugins) is preferred because macOS and
Windows then share one lifecycle host, consistent with the packaging rule
below. A thin SwiftUI `MenuBarExtra` implementation of the same contract is an
acceptable macOS-first spike if native polish is needed before the Tauri host
exists. Either implementation consumes only the status contract.

### Sequencing

1. Status contract in the release itself: `runtime.json` writer, removal on
   shutdown, reliable graceful stop, readiness route. Pure Elixir, testable
   now, host-agnostic.
2. Minimal host: launch, supervise, tray with status + Open + lifecycle +
   Quit.
3. Quality of life: login item, recent workspaces, pairing helpers, updater
   (Tauri updater or Sparkle).
4. Later: windowed cockpit. An embedded WKWebView window requires a real app
   main menu — at minimum a standard Edit menu for clipboard shortcuts, Window
   management, and Settings — and app-level shortcuts must not shadow the
   IDE's leader keys (`docs/leader_keys.md`). WKWebView configuration also
   needs deliberate choices at that point: developer extras, download and
   clipboard permissions, and whether any non-loopback navigation is allowed. Native notifications for action
   center cards can slot into the host's status-polling loop at this stage;
   they are not v1.

## Packaging rule

Each release artifact is built and tested on its target OS and architecture.
Tauri may bundle or install that target's OTP release, but it never downloads or
silently provisions WSL as part of the Windows product path.

Before any public snapshot, build artifacts must be scanned independently of
the source tree, and the reviewed core must be published from fresh history.
Licensing, provenance, dependency/asset inventories, and the public/private
feature boundary remain explicit release gates rather than assumptions of the
desktop spike.

## Windows notification-area host

The first host implementation lives in `windows/DevIDE.Tray.ps1`. It uses the
Windows Forms `NotifyIcon` API, starts the packaged OTP release without a console
window, and keeps the Phoenix cockpit on a loopback-only port. Its menu exposes
open, restart, logs, launch-at-sign-in, and quit actions. Double-clicking the icon
opens the cockpit in the user's default browser.
For the first Windows vertical slice, the launch target is `/desktop-terminal`;
the normal `/` workspace cockpit still depends on terminal seams that are being
ported away from tmux.

The host persists only local runtime state under `%LOCALAPPDATA%\DevIDE`:

- `devide.sqlite3` — desktop SQLite database;
- `desktop-host.json` — retained port and launch-at-sign-in preference;
- `secret-key-base.txt` — per-install Phoenix secret;
- `api-token.txt` — per-install local API bearer token;
- `desktop-host.log` — lifecycle and startup errors.

Create a Windows payload from a native Windows checkout with:

```powershell
powershell -File scripts/package-windows-desktop.ps1
```

Then launch `dist\DevIDE-windows-x64\windows\Start-DevIDE.cmd`. The packaging
script deliberately produces an installer-ready directory rather than choosing
an installer technology. Code signing, an MSI/MSIX wrapper, branded icon assets,
and auto-update remain release-engineering follow-ups.
