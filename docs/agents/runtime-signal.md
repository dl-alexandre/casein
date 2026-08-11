# Runtime signal (S11 / #867)

**Problem:** the deployed BEAM can disagree with what the checkout implies.
Reading `Application.get_env(:casein, :tmux_adapter, Casein.Terminals.Tmux)` in
the repo “proves” `Tmux` is live; production once resolved MCP writes through
`Casein.Terminals.Backends.Tmux` (incomplete). A git SHA alone would not have
caught that — only a live MCP call and `UndefinedFunctionError` did.

**Tool:** `runtime_signal` (Terminal MCP, read-only).

```text
runtime_signal { workspace_id? }
→ {
    revision: { deployed, remote, branch, status, behind, ahead, … },
    modules: {
      tmux_adapter: {
        configured, repo_default, backend_module,
        mcp_resolved, mcp_source,      # TerminalTools.Shared path
        ops_resolved, ops_source,      # get_env(..., Tmux) path
        paths_disagree?,
        mcp_surface: { ok?, missing: ["paste_text/3", …] }
      },
      terminal_backend: { configured, resolved, source }
    },
    diverged?: bool,
    attention: ["revision_drift" | "tmux_adapter_paths_disagree" | …]
  }
```

## How to use from an agent pane

1. Call `runtime_signal` before debugging “MCP works for capture but paste dies”.
2. If `modules.tmux_adapter.paths_disagree?` — stop trusting repo defaults; the
   MCP path is `mcp_resolved`, not `repo_default`.
3. If `mcp_surface.ok? == false` — the live module is missing callbacks; do not
   invent double-Enter folklore. Cite `missing`.
4. If `revision.status != "current"` — deployed SHA ≠ `origin/<branch>` head;
   `behind`/`ahead` are set when a git dir is available (`CASEIN_CHECKOUT`).

## Kind discipline

- Remote lookup failure → `revision.status: "unknown"`, **not** current.
- Missing module / missing export → attention, **not** silent ok.
- No mutations; no adapter swap from this tool.

## Code

- `Casein.Deployment.RuntimeSignal` — pure snapshot
- `Casein.Agents.TerminalTools.RuntimeSignal` — MCP / Jido action
- Related: `Casein.Deployment.Drift` (SHA-only), `Casein.Terminals.Backend.module/0`
