# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.
## Windows workstream B: native preview runtime and browser automation

- Owner: issue [#463](https://github.com/dl-alexandre/casein/issues/463)
- Scope: `lib/preview_ctl/playwright/**`, preview-specific process adapters under
  `lib/casein/processes/**`, `lib/casein/runtimes/preview_*`,
  `scripts/prepare-windows-preview-runtime.ps1`,
  `scripts/package-windows-desktop.ps1`,
  `scripts/test-windows-desktop-package.ps1`, and preview parity documentation.
- Boundary: preserve the existing Phoenix/LiveView cockpit and Preview MCP
  schemas. Treat terminal/session backend paths owned by issue #462 as read-only
  unless an interface change is explicitly coordinated.
