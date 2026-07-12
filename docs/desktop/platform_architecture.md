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

## Packaging rule

Each release artifact is built and tested on its target OS and architecture.
Tauri may bundle or install that target's OTP release, but it never downloads or
silently provisions WSL as part of the Windows product path.

Before any public snapshot, build artifacts must be scanned independently of
the source tree, and the reviewed core must be published from fresh history.
Licensing, provenance, dependency/asset inventories, and the public/private
feature boundary remain explicit release gates rather than assumptions of the
desktop spike.
