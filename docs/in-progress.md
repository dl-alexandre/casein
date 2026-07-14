# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

- `feat/windows-tray-host` — Windows desktop release hardening: loopback/authentication,
  packaging/install/update safety, terminal lifecycle, and Windows artifact gates. Treat
  `windows/`, `scripts/package-windows-desktop.ps1`, `dev_ide_ghostty_windows/`, and
  desktop-profile runtime/UI paths as coordinated until this entry is removed.
