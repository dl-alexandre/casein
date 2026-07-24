# Windows desktop and devbox parity

This is the direction of record for bringing the standalone Windows product to
the same user-level capability as the production devbox. Parity means the same
workflow and safety guarantees; it does not mean reproducing Linux, systemd, or
tmux implementation details on Windows.

## Current capability matrix

| Product capability | Devbox production | Windows desktop | Required work |
|---|---|---|---|
| Install and launch without language tooling | systemd release | packaged OTP release and tray host | Harden public signing and update channel |
| Local security boundary | Caddy, scoped tokens | loopback binding and local bearer token | Add signed binaries and token rotation UX |
| Mobile origin identity | Deployment-defined origin | installation-stable `windows-<uuid>` and `<machine> (Windows)` identity | Add trusted-LAN pairing transport |
| Persistent product data | PostgreSQL | SQLite under LocalAppData | Backup/restore UI and migration recovery |
| Interactive terminal | tmux PTY | PowerShell through ConPTY | Job Object containment and richer diagnostics |
| Resize and reconnect | tmux capture/attach | ConPTY resize and application-owned session | Crash/reboot restoration |
| Agent MCP pairing | launch script injects scoped MCP | native shell injects scoped MCP and project discovery | Verify every supported agent runtime |
| Grok | launcher-managed `.mcp.json` | project `.mcp.json`, token inherited by shell | Completed by the desktop agent/MCP slice |
| Claude, Codex, OpenCode, Cursor | runtime-specific injection | generated configs exist, no desktop launch UX | Add runtime launch actions and conformance tests |
| Preview control and screenshots | Playwright sidecar and preview MCP | MCP endpoint exists, browser runtime not packaged | Package browser dependencies and native process adapter |
| Multi-pane sessions and templates | tmux windows/panes | one durable PowerShell session | Native session/window/pane backend |
| Worktrees and agent lifecycle | launcher, hooks, reaper, audit | backend features exist, desktop workflow incomplete | Native worktree launch, state hooks, recovery UI |
| Updates | git-driven clean release deploy | local install/update with backup | Signed manifest, channel, rollback, offline installer |
| Operations | journal, health, deploy diagnostics | tray status, health, local log | Support bundle, repair action, crash reporting |
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
