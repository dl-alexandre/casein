# DevIDE MenuBar — macOS lifecycle host (spike)

A SwiftUI `MenuBarExtra` implementation of the desktop host contract from
[`docs/desktop/platform_architecture.md`](../../docs/desktop/platform_architecture.md)
("macOS desktop host: menu bar extra first"). It is deliberately thin: it
execs the release's `bin/` scripts, reads `runtime.json`, probes
`GET /desktop/health`, and opens URLs. No product state, no BEAM protocol —
so a later Tauri host can replace it by consuming the same contract.

## What it does (v1)

- **Status**: polls `<data_dir>/runtime.json` every 2s (schema 1; unknown
  schemas are rejected, per contract). A file whose `pid` is dead is treated
  as stale. When the pid is alive it confirms readiness against
  `GET /desktop/health` on the published `base_url`, so the icon can't show
  "running" for a wedged node.
- **Start**: `bin/migrate` then `bin/dev_ide daemon`, with the environment
  the contract obliges the host to provide: `DEV_IDE_PROFILE=desktop`,
  generated-and-persisted `SECRET_KEY_BASE` + `DEV_IDE_API_TOKEN`,
  `DEV_IDE_DESKTOP_DATA_DIR`, and a distinct `RELEASE_NODE`
  (`devide_desktop`) so a stale `dev_ide` epmd registration elsewhere on the
  machine can't cause "name in use".
- **Stop/Restart**: `bin/dev_ide stop`, wait for the published pid to exit,
  then poll the release's own `erts-*/bin/epmd -names` until the node name is
  dropped — the documented restart race — before starting again.
- **Menu**: status header (state, version, revision, port), Open DevIDE,
  Copy Base URL, Start/Stop/Restart, Open Data Folder, Open Logs,
  Choose Release…, and two Quit items (stop server, or leave it running).
- **Icon**: SF Symbol template image (`terminal.fill` running, `terminal`
  stopped, warning triangle for unhealthy/incompatible), adapts to
  light/dark menu bars.

Host state lives in `~/Library/Application Support/DevIDE` (mirrors
`DevIDE.Desktop.Runtime.data_dir/0` on Darwin): `runtime.json` (written by
the release), `host-secrets.json` (0600, written by the host),
`host-logs/` (migrate/daemon/stop output).

## Build & run

```bash
cd native/devide_menubar
bash scripts/bundle.sh            # swift build + assemble + ad-hoc codesign
open "build/DevIDE MenuBar.app"
```

`swift run` works for quick iteration (the activation policy is also set in
code), but LSUIElement and the ATS loopback exemption only apply from the
bundled app. Requires macOS 14+ and Xcode command line tools.

Build a release to point it at (from the repo root, toolchain per AGENTS.md):

```bash
mise exec elixir@1.20.0-otp-28 erlang@28.5 -- \
  env MIX_ENV=prod DEV_IDE_REPO_ADAPTER=sqlite mix dev_ide.release.lan
```

Then pick the assembled release directory (the one containing `bin/dev_ide`)
via **Choose Release…** in the menu.

## Deliberately not in the spike

- **Start at Login** (SMAppService) — phase 3 in the design doc.
- **Crash restarts with bounded backoff** — the host observes a crash (stale
  `runtime.json`) but only offers manual Start.
- **Option-key Quit alternate** — modeled as two explicit menu items for now;
  collapse to a `modifierKeyAlternate` when we bump the deployment target.
- **Keychain for secrets** — `host-secrets.json` is 0600 in the data dir;
  move to Keychain before anything ships.
- **Copy MCP endpoint / pairing helpers, recent workspaces** — need the
  deep-link scheme (`docs/deep_links.md`) wired in; phase 3.
- **Real signing / notarization / Sparkle** — packaging-rule work, not spike
  work. The bundle script ad-hoc signs only so Apple silicon doesn't SIGKILL
  the binary.
