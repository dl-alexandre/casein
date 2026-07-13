# devide-menubar

Phase-2 spike of the macOS menu bar host described in
`docs/desktop/platform_architecture.md` ("macOS desktop host: menu bar extra
first"). It is a reference implementation of the desktop status contract:
the host execs the release, reads `runtime.json`, probes
`GET /desktop/health`, and opens URLs — nothing else. No BEAM protocol, no
product state.

## Layout

- `DevIDEHostCore` — Foundation-only library: `RuntimeStatus` (schema-1
  contract file + pid stale rule), `HealthProbe`, `HostSecrets`
  (SECRET_KEY_BASE / DEV_IDE_API_TOKEN generation, 0600, Keychain TODO),
  `ReleaseController` (actor owning migrate/daemon/stop/restart including the
  epmd name-drop wait), `ServerMonitor` (@MainActor state machine the menu
  renders from).
- `devide-menubar` — SwiftUI `MenuBarExtra` shell over the core. Accessory
  activation policy (no Dock icon).

## Run

Needs a desktop-capable release (SQLite-compiled; see docs/deploy.md macOS
section) and Swift 6+:

```sh
cd native/devide_menubar
DEVIDE_RELEASE_ROOT=$PWD/../../_build/prod/rel/dev_ide swift run
```

Optional: `DEV_IDE_DESKTOP_DATA_DIR` overrides the default
`~/Library/Application Support/DevIDE`. The host generates and persists boot
secrets on first start (`host-secrets.json` in the data dir) and runs the
release under `RELEASE_NODE=devide_desktop` so it cannot collide with stray
`dev_ide` nodes.

## Test

```sh
swift test
```

## Menu (v1)

Status header (state, port, version/revision) · Open DevIDE / Copy URL ·
Start / Stop / Restart (restart waits for process exit and the epmd name
drop) · Open Logs / Open Data Folder · Quit (stops the server) / Quit, Leave
Server Running.

## Not in the spike (phase 3+)

- `.app` packaging with `LSUIElement`, codesigning, notarization
- Bundled/installed release instead of `DEVIDE_RELEASE_ROOT`
- Start at Login (`SMAppService`), updater (Sparkle or Tauri parity)
- Recent-workspace deep links, MCP/pairing helpers
- Keychain-backed secrets
- Crash-restart backoff supervision
