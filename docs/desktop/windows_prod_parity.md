# Windows desktop and devbox parity

This is the direction of record for bringing the standalone Windows product to
the same user-level capability as the production devbox. Parity means the same
workflow and safety guarantees; it does not mean reproducing Linux, systemd, or
tmux implementation details on Windows.

## Current capability matrix

| Product capability | Devbox production | Windows desktop | Required work |
|---|---|---|---|
| Install and launch without language tooling | systemd release | packaged OTP release and tray host | Harden public signing and update channel |
| Local security boundary | Caddy, scoped tokens | loopback binding, DPAPI-protected bearer/launch tokens, and health-validated tray rotation with rollback | Add production-signed evidence |
| Mobile origin identity | Deployment-defined origin | installation-stable `windows-<uuid>` and `<machine> (Windows)` identity | Add trusted-LAN pairing transport |
| Persistent product data | PostgreSQL | SQLite under LocalAppData; integrity check before migration; DPAPI-encrypted pre-update snapshot restored by rollback | Clean-VM migration and rollback evidence |
| Mobile open-clarification inbox | Postgres `NOT EXISTS` + `DISTINCT ON` filter-before-distinct (H28) | Same H28 contract via shared `OpenClarifications.project/4` on SQLite Ecto + Memory paths (no Postgres JSON operators) | Clean-VM paired-device evidence still external (#377) |
| Interactive terminal | tmux PTY | PowerShell through ConPTY | Job Object containment and richer diagnostics |
| Resize and reconnect | tmux capture/attach | ConPTY resize and application-owned session | Crash/reboot restoration |
| Agent MCP pairing | launch script injects scoped MCP | native shell injects scoped MCP and project discovery | Verify every supported agent runtime |
| Grok | launcher-managed `.mcp.json` | project `.mcp.json`, token inherited by shell | Completed by the desktop agent/MCP slice |
| Claude, Codex, OpenCode, Cursor | runtime-specific injection | generated configs exist, no desktop launch UX | Add runtime launch actions and conformance tests |
| Preview control and screenshots | Playwright sidecar and preview MCP | packaged Node/Playwright/Chromium runtime, native preview-server lifecycle with kill-on-close Job Object process-tree cleanup, path-shape-aware `storage_state_path` mkdir (win32/posix), shipped-helper diagnose + daemon action-path smoke (observe/type/click/press/screenshot/reload/close), repair diagnostics, preview_bridge file:// IIFE walk (`scripts/verify_preview_bridge_file_page.mjs`), and clean-host evidence gate (`docs/desktop/windows_preview_mcp_clean_host.md`, `scripts/verify_windows_preview_mcp_clean_host.sh`) | Capture clean-machine agent-driven Preview MCP acceptance evidence on a signed Win11 install |
| Multi-pane sessions and templates | tmux windows/panes | one durable PowerShell session | Native session/window/pane backend |
| Worktrees and agent lifecycle | launcher, hooks, reaper, audit | backend features exist, desktop workflow incomplete | Native worktree launch, state hooks, recovery UI |
| Updates | git-driven clean release deploy | explicit tray check; trusted catalog, pinned channel/target, archive hash/size verification, encrypted backup, health-triggered rollback | Production-signed channel and clean-VM evidence |
| Operations | journal, health, deploy diagnostics | signed offline archive with one-command install/repair/uninstall, Apps & Features registration, tray status, health, local log, and support bundle with fixed-schema JSON diagnostics plus latest crash/recovery state | Clean-VM crash/recovery evidence |
| Accessibility and onboarding | browser UI | browser UI plus tray | First-run workspace/agent check and keyboard QA |

## Delivery order

1. **Connected native agents**: make workspace-scoped MCP credentials and
   discovery intrinsic to the Windows terminal. Do not write bearer tokens to
   project files or global provider homes.
2. **Preview parity**: package the supported browser, route preview process
   creation through the platform backend, and prove open/click/type/screenshot
   from an agent launched inside the desktop shell.
3. **Session topology**: replace the singleton shell with native product-level
   sessions, windows, panes, capture, templates, and explicit process ownership.
4. **Agent workflow parity**: add launch actions for Grok, Claude, Codex,
   OpenCode, and Cursor; port state hooks, worktree reporting, recovery, and
   audit surfaces without depending on bash or tmux.
5. **Release trust and recovery**: Authenticode-sign every executable, publish a
   signed update manifest, test upgrade/downgrade/rollback, add repair and
   support-bundle flows, and use Windows Job Objects for full process-tree exit.
6. **Public release gate**: clean-machine and no-WSL tests for install, restart,
   workspace persistence, all supported agents, preview automation, update,
   uninstall, accessibility, and failure recovery.

The devbox implementation remains unchanged throughout this work. Shared MCP,
workspace, audit, and LiveView contracts are reused; Windows receives native
adapters and launch integration behind the desktop profile.

## Mobile origin identity

The Windows tray host persists `origin.json` under `%LOCALAPPDATA%\Casein` on
first launch. Its opaque id is installation-scoped and is never derived from an
IP address, hostname, port, or URL. The friendly name uses the Windows machine
name with an explicit `(Windows)` suffix so a mobile client can distinguish it
from local macOS and devbox profiles.

The host injects that identity through `CASEIN_ORIGIN_ID` and
`CASEIN_ORIGIN_DISPLAY_NAME`; Device Link credentials retain it across token
rotation. Changing network interfaces or listener coordinates therefore
updates reachability for the same origin rather than manufacturing another
identity. Non-desktop deployments continue to use the shared `Casein.Origin`
identity derivation.

## Acceptance direction

The literal Windows/mobile acceptance gate is maintained in
[`windows_mobile_acceptance.md`](windows_mobile_acceptance.md) and GitHub issue
#371. Production signing evidence (#376), the physical-device matrix (#377),
and authenticated post-deploy verification (#378) are focused evidence tasks;
they do not replace or independently redefine the parent checklist.

## Offline lifecycle

The distributable ZIP is the offline, per-user Windows installer. Extract it
locally, then run `Install-Casein.cmd`; it requires a valid production
Authenticode release and opens the existing browser cockpit through the thin
tray host. It does not require WSL, Erlang, Elixir, Node.js, Git, or an
administrator account. The underlying installer also requires signing by
default; `-AllowUnsignedDevelopment` exists only for the repository's isolated
package smoke and must never be used for release acceptance.

Keep the extracted archive until the installation has been exercised. Running
`Repair-Casein.cmd` from that same trusted archive stops Casein, validates the
installed release, replaces it atomically when any manifest-covered file is
missing or changed, preserves user data through an encrypted pre-repair
snapshot, and relaunches it. `Uninstall-Casein.cmd` removes the application and
Apps & Features entry while retaining user data; pass `-RemoveUserData` to the
packaged `windows\Uninstall-Casein.ps1` only when that deletion is deliberate.

## Local access-token recovery

Use **Rotate local access tokens** from the notification-area menu if a local
agent credential or previously opened cockpit launch URL may have been exposed.
The thin tray host asks for confirmation, stops the local runtime, replaces the
API bearer and one-time launch proof roots with new current-user DPAPI-protected
values, and waits for loopback health. The stable Windows origin, SQLite data,
workspace state, and Phoenix session-signing root are not changed.

Existing local agent connections must reconnect after a successful rotation.
If the runtime does not become healthy, the tray restores the prior encrypted
token files and restarts with them. Logs and support bundles record only the
rotation timestamp and outcome; they never contain old or new token values.
