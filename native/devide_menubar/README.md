# devide-menubar

macOS menu bar host described in
`docs/desktop/platform_architecture.md` ("macOS desktop host: menu bar extra
first"). It is a reference implementation of the desktop status contract:
the host execs the release, reads `runtime.json`, probes
`GET /desktop/health`, and opens URLs — nothing else. No BEAM protocol, no
product state.

## Layout

- `DevIDEHostCore` — Foundation-only library: `RuntimeStatus` (schema-1
  contract file + pid stale rule), `HealthProbe`, `HostSecrets`
  (SECRET_KEY_BASE / API / desktop-launch secret generation and Keychain migration),
  `ReleaseController` (actor owning migrate/daemon/stop/restart including the
  epmd name-drop wait), `ServerMonitor` (@MainActor state machine the menu
  renders from).
- `devide-menubar` — SwiftUI `MenuBarExtra` shell over the core. Accessory
  activation policy (no Dock icon).

## Run

Needs a desktop-capable release (SQLite-compiled; see docs/deploy.md macOS
section). Use `/usr/bin/swift` — it dispatches through xcrun to the
xcode-select'd toolchain, sidestepping broken package-manager Swift shims
earlier on PATH:

```sh
cd native/devide_menubar
DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/dev_ide /usr/bin/swift run
```

For a development-only host bundle without an embedded release:

```sh
./scripts/bundle.sh          # -> build/DevIDE MenuBar.app
open "build/DevIDE MenuBar.app"
```

Release discovery: `DEVIDE_RELEASE_ROOT` wins; otherwise the persisted
release embedded under the app's `Contents/Resources`, then the persisted
"Choose Release…" pick (UserDefaults). `DEV_IDE_DESKTOP_DATA_DIR` overrides
the default `~/Library/Application Support/DevIDE`. The host generates and
persists boot secrets in the user's login Keychain on first start; an existing
`host-secrets.json` is migrated once and removed only after the Keychain write
succeeds. The release runs under `RELEASE_NODE=devide_desktop` so it cannot
collide with stray `dev_ide` nodes. It also persists a loopback port in
`desktop-host.json`; Open DevIDE exchanges a short-lived, single-use HMAC claim
for an HttpOnly browser session while Copy URL intentionally copies the clean,
unauthenticated URL. The reusable launch secret never enters browser history.

Build the self-contained product artifact from the repository root:

```sh
scripts/package-macos-desktop.sh
scripts/test-macos-desktop-package.sh
```

The package build creates a native SQLite OTP release, builds checksum-pinned
tmux 3.7b with static libevent and utf8proc, embeds licenses, signs every nested
Mach-O before sealing the app, and emits an architecture-labelled zip,
SHA-256, and manifest under `build/artifacts`. The package test launches the
app through LaunchServices and verifies health plus the desktop auth exchange.
CI repeats this gate on macOS 14 arm64, macOS 15 arm64/Intel, and macOS 26 arm64.

## Test

```sh
swift test
```

Two self-asserting end-to-end suites (throwaway data dirs, unique
RELEASE_NODE each so they can boot releases concurrently) are gated on a
real release being available:

```sh
DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/dev_ide \
  /usr/bin/swift test --filter "LifecycleIntegration|CrashRecovery"
```

`LifecycleIntegration`: start → ready → health identity → graceful stop →
epmd drain → restart with a fresh pid. `CrashRecovery`: SIGKILL the BEAM →
crash detected → backoff countdown → auto-restart to ready without manual
action; plus the no-intent case (stale contract found at launch stays
stopped).

## Menu (v1)

Status header (state, port, version/revision) · Open DevIDE / Copy URL ·
Start / Stop / Restart (restart waits for process exit and the epmd name
drop) · Open Logs / Open Data Folder · Start at Login (`SMAppService`,
bundled `.app` only — the registration binds to the bundle's path) · Quit
(stops the server) / Quit, Leave Server Running.

## Remaining distribution work

- Real signing identity + notarization (`bundle.sh` signs ad-hoc)
- Updater (Sparkle or Tauri parity)
- Auto-restart on sustained `unhealthy` (deliberately manual-only for now:
  a slow-but-alive node must not be restart-looped; crash auto-restart
  covers `stale` with 5→10→30→60s backoff and a 2-minute quiet reset)
- Recent-workspace deep links, MCP/pairing helpers
