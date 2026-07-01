# Agents / MCP capability layer

> Detect what agent capabilities a workspace has, and give external coding
> agents (Grok, Claude, Codex, opencode) narrow, audited tool access to a
> workspace's tmux sessions and preview surfaces over MCP.

## Responsibility

`DevIDE.Agents.*` is the capability + tool layer that connects external agents
to a workspace. It does three distinct jobs:

1. **Capability detection** (`DevIDE.Agents`, `LocalAdapter`, the
   `*Capability` modules) — observe, read-only, what agent features a
   workspace exposes (opencode config, fff, browser artifacts, transcripts, and
   the three MCP endpoints: terminal, preview, Tidewave). Per the `DevIDE.Agents`
   M7 contract this layer **never** starts agents, sends prompts, or grants
   permissions — every public function is a query.
2. **Agent-facing tools** (`TerminalTools`, `PreviewTools`, `AnnotationTools`,
   `BrowserControl`) — the actual MCP tool definitions and dispatch handlers
   that let an agent drive tmux and previews without arbitrary shell or browser
   access. The web layer (`DevIdeWeb.API.TerminalMCP` / `PreviewMCP`) wraps
   these in JSON-RPC.
3. **Wiring agents in** (`MCPUrls`, `MCPMaterializer`, `PaneEnv`, `TidewaveMCP`)
   — build the MCP endpoint URLs, materialize per-workspace client config files
   for each agent CLI, and push the `DEVIDE_*` env into a tmux session so a bare
   `claude` / `grok` / `codex` command picks up the DevIDE MCP servers
   automatically.

A separate slice (`ReviewCommand`, `Run`) supports allowlisted review-mode
agent runs with compile-time-fixed argv.

## Module map

| Module | File | Role |
|--------|------|------|
| `DevIDE.Agents` | `lib/dev_ide/agents.ex` | Behaviour + public query API (`detect/2`, `transcripts/1`, `review_commands/1`); dispatches to the configured `:agents_adapter`. Read-only M7 contract. |
| `DevIDE.Agents.LocalAdapter` | `lib/dev_ide/agents/local_adapter.ex` | Default adapter: filesystem + metadata detection of capabilities. Read-only; all path access via `Files.PathSafety`. |
| `DevIDE.Agents.Capability` | `lib/dev_ide/agents/capability.ex` | Struct for one observed capability (`kind`, `status`, `source`, `url`, `details`). |
| `DevIDE.Agents.Artifact` | `lib/dev_ide/agents/artifact.ex` | Read-only file pointer (e.g. transcript) returned by detection. |
| `DevIDE.Agents.TerminalMCPCapability` | `lib/dev_ide/agents/terminal_mcp_capability.ex` | Detect the terminal-control MCP endpoint; advertises URL + tool names. |
| `DevIDE.Agents.PreviewMCPCapability` | `lib/dev_ide/agents/preview_mcp_capability.ex` | Detect the preview-control MCP endpoint; advertises URL + tool names. |
| `DevIDE.Agents.TidewaveCapability` | `lib/dev_ide/agents/tidewave_capability.ex` | Detect locally-hosted Tidewave (dev/preview-env only) via configured URL-provider MFA. |
| `DevIDE.Agents.TerminalTools` | `lib/dev_ide/agents/terminal_tools.ex` | MCP tool definitions + dispatch for tmux control (list/topology/capture/send/label/worktree). `devide_`-prefix and workspace scoping. |
| `DevIDE.Agents.PreviewTools` | `lib/dev_ide/agents/preview_tools.ex` | MCP tool definitions + dispatch for preview control (open/observe/click/type/screenshot/navigate/reload). |
| `DevIDE.Agents.AnnotationTools` | `lib/dev_ide/agents/annotation_tools.ex` | Annotation tools (`annotation_list`, `annotation_propose`) appended to the terminal tool set. |
| `DevIDE.Agents.BrowserControl` | `lib/dev_ide/agents/browser_control.ex` | Best-effort `push_event` broadcasts to connected workspace LiveViews (reload iframe / reload page). |
| `DevIDE.Agents.TerminalOutputFormat` | `lib/dev_ide/agents/terminal_output_format.ex` | Normalize tmux scrollback (strip ANSI by default) for token-cheap agent output. |
| `DevIDE.Agents.MCPUrls` | `lib/dev_ide/agents/mcp_urls.ex` | Build terminal/preview MCP endpoint URLs from config/env, pre-scoping `workspace_id`. |
| `DevIDE.Agents.MCPMaterializer` | `lib/dev_ide/agents/mcp_materializer.ex` | Write per-workspace agent client configs (Grok/Codex/opencode/Cursor/`.mcp.json`/`env.sh`) into a staging home. |
| `DevIDE.Agents.PaneEnv` | `lib/dev_ide/agents/pane_env.ex` | Build the `DEVIDE_*` env map and push it into a tmux session; materializes configs as a side effect. |
| `DevIDE.Agents.AuthProfile` | `lib/dev_ide/agents/auth_profile.ex` | Resolve opt-in owner Claude/Codex auth homes from `~/.devide/agent-auth/profiles/<owner>/<runtime>` directory presence. Missing dirs keep global provider auth. |
| `DevIDE.Agents.TidewaveMCP` | `lib/dev_ide/agents/tidewave_mcp.ex` | Resolve an optional Tidewave MCP URL (env → self-hosted → workspace metadata → preview registry) + server key. |
| `DevIDE.Agents.MCPAudit` | `lib/dev_ide/agents/mcp_audit.ex` | Record every tool call to the `Activity` feed; emit an `Audit` event for mutating tools; propose labels from terminal calls. |
| `DevIDE.Agents.MCPError` | `lib/dev_ide/agents/mcp_error.ex` | Normalize `{:error, reason}` from tool handlers into MCP `structuredContent` payloads. |
| `DevIDE.Agents.Activity` | `lib/dev_ide/agents/activity.ex` | Recent MCP tool-call feed for human operators (terminal + preview); LiveViews subscribe. |
| `DevIDE.Agents.ReviewCommand` | `lib/dev_ide/agents/review_command.ex` | Allowlisted review-mode command; argv fixed at compile time, gated on detected capabilities. |
| `DevIDE.Agents.Run` | `lib/dev_ide/agents/run.ex` | One in-flight review-mode run per workspace (supervised, linger, hard timeout). |

## Data flow / lifecycle

**Wiring an agent into a workspace (session setup):**

1. `PaneEnv.ensure_for_session/3` (or `vars_for_workspace/2`) is called for a
   workspace tmux session.
2. It resolves the API token, then calls `MCPMaterializer.materialize/2`, which
   writes a staging home containing `grok/config.toml`, `codex/config.toml`,
   `opencode.json`, `.mcp.json`, `cursor/mcp.json`, and `env.sh`. Grok,
   OpenCode, Claude/Cursor staging configs point at the terminal + preview MCP URLs
   (from `MCPUrls`) with a `Bearer ${DEV_IDE_API_TOKEN}` header, plus an
   optional Tidewave server (from `TidewaveMCP.resolve_url/2`). Codex staging is
   intentionally free of DevIDE MCP entries; the launcher injects them at
   runtime. Cursor's `mcp.json` is also copied into the checkout's `.cursor/`.
3. `PaneEnv` builds the `DEVIDE_*` env map (`DEV_IDE_API_TOKEN`,
   `DEVIDE_WORKSPACE_ID`, `DEVIDE_TERMINAL_MCP_URL`, `DEVIDE_PREVIEW_MCP_URL`,
   `DEVIDE_AGENT_MCP_HOME`, prepended `PATH`, optional `DEVIDE_TIDEWAVE_MCP_URL`)
   and pushes it into the session with `Tmux.set_environments/2`. If a Claude
   or Codex owner profile exists under
   `~/.devide/agent-auth/profiles/<owner>/<runtime>`, `PaneEnv` also injects
   `CLAUDE_CONFIG_DIR` or `CODEX_HOME`; absent profile directories mean the
   runtime keeps its global provider login.
4. Launching a shimmed agent binary in that pane picks up the materialized config
   + env, so MCP injection is automatic. Claude reads the staged `.mcp.json`,
   Grok reads project `.mcp.json`, OpenCode reads project
   `.opencode/opencode.json`, and Codex receives DevIDE MCP through launch-time
   `-c mcp_servers...` overrides. Plain agent starts do not depend on
   `DEV_IDE_API_TOKEN` because DevIDE MCP is not persisted in global agent
   configs. (See `PaneEnv.launch_command/3`.)

**An agent calling a tool (request lifecycle):**

1. Agent POSTs JSON-RPC to `/api/terminals/mcp` or `/api/preview/mcp` (bearer
   auth). The thin `*MCPController` hands the decoded message to
   `DevIdeWeb.API.TerminalMCP.handle/2` / `PreviewMCP.handle/2`.
2. The web handler resolves/scopes `workspace_id` (pre-scoped from the URL query
   param when present), then dispatches `tools/call` to
   `TerminalTools.invoke/2` or `PreviewTools.invoke/3`.
3. The tool handler validates scope (terminal: `devide_` prefix +
   `workspace_matches?`; preview: `ensure_pane_workspace_scope`), performs the
   tmux/preview operation, and returns `{:ok, map}` or `{:error, reason}`.
4. Result is recorded via `MCPAudit.record_terminal/3` /
   `record_preview/4` (→ `Activity` feed; `Audit.emit!` for mutating tools;
   label proposals), and errors are shaped by `MCPError` into MCP
   `structuredContent`.

**Capability detection (observe):**

`DevIDE.Agents.detect(root, workspace)` → `LocalAdapter.detect/2` →
`detect_filesystem_only/1` builds the capability list (opencode, fff, browser
artifacts) and folds in the three MCP capabilities via their `*Capability.detect/0`
modules. Tidewave is enriched from manager metadata / port fingerprints when
available. The list is surfaced through agent UI and `GET
/api/workspaces/:id/status` as `agent_capabilities`.

## Public surface

- `DevIDE.Agents.detect/2`, `transcripts/1`, `review_commands/1` — read-only
  capability queries (delegate to the configured adapter).
- `DevIDE.Agents.PaneEnv.vars_for_workspace/2`, `ensure_for_session/3`,
  `launch_command/3` — build/install the agent env for a tmux session.
- `DevIDE.Agents.MCPMaterializer.materialize/2` — write agent client config
  files; returns the staging-home path.
- `DevIDE.Agents.MCPUrls.terminal_url/1`, `preview_url/1`, `base_url/0` —
  endpoint URL construction.
- `DevIDE.Agents.TidewaveMCP.resolve_url/2`, `server_key/1`,
  `normalize_mcp_url/1` — optional Tidewave wiring.
- `DevIDE.Agents.TerminalTools.definitions/0`, `invoke/2` — terminal MCP tool
  surface (called by `DevIdeWeb.API.TerminalMCP`).
- `DevIDE.Agents.PreviewTools.definitions/0`, `invoke/3` — preview MCP tool
  surface (called by `DevIdeWeb.API.PreviewMCP`).
- `DevIDE.Agents.MCPAudit.record_terminal/3`, `record_preview/4` — audit +
  activity recording.
- `DevIDE.Agents.MCPError.*` — error normalization for tool handlers.
- `DevIDE.Agents.*Capability.detect/0` — individual endpoint detection.

## Invariants & gotchas

- **Detection is read-only (M7).** `DevIDE.Agents` and `LocalAdapter` observe
  only; they never start agents or grant permissions. Don't add side effects to
  the detection path.
- **Web layer depends on context, not the reverse.** `TerminalMCPCapability` /
  `PreviewMCPCapability` / `TidewaveCapability` resolve the endpoint base URL
  through a configured MFA (`:tidewave_url_provider`, etc.) so context code never
  references `DevIdeWeb.Endpoint`. Keep this inversion.
- **Bearer token is fully trusted on the host.** Scoping, not auth, is what
  keeps agents inside their workspace. Terminal tools only touch `devide_`-prefixed
  sessions; `workspace_id` resolves both the manager UUID *and* the workspace
  **name** to tmux prefixes (sessions are `devide_<name>_<sid>`). Cross-workspace
  access is rejected with `:workspace_mismatch`.
- **Pass `workspace_id` on every call.** Generated configs append
  `?workspace_id=<uuid>` so the transport injects it; without it, tools can see
  every `devide_*` session on the host.
- **Mutating agent-pane shortcuts require the `agent_pair` marker.**
  `terminal_send_agent_*` use `find_agent_pane(..., allow_process_fallback:
  false)` — they refuse to fall back to process detection, so they never type
  into the operator's pane. Read-only agent-pane tools allow the process
  fallback.
- **Tidewave is dev/preview-env only.** It is never compiled into the prod
  release; `TidewaveCapability.detect/0` returns `:missing` unless `Tidewave` is
  loaded and a URL provider is configured. Preview-env instances (ports
  41000–41049) tag `source: :preview_env`.
- **`MCPMaterializer` does not copy `.mcp.json` into the checkout** — only
  Cursor's `mcp.json` is copied — to avoid a shared checkout accumulating every
  workspace's servers. `env.sh` is chmod `0600`.
- **Provider auth profiles are opt-in by directory presence.** Do not persist
  provider secrets in `workspace_records` or manager metadata. Missing profile
  dirs keep a workspace on the host global provider login. To replace that
  default for the current owner, run `devide agent auth signin <runtime>` from a
  DevIDE workspace once per provider. Outside a workspace, use
  `devide agent auth signin <owner> <runtime>`. Workspaces named `<owner>-...`
  automatically use `~/.devide/agent-auth/profiles/<owner>/<runtime>` after
  sign-in. Delete the relevant profile directory to return that owner to the
  global fallback. Use `devide agent auth status [workspace] [runtime]` or
  `devide agent auth list` to audit which profile is active.
- **`review_command` argv is fixed at compile time.** Users pick an id from the
  allowlist; they never supply argv. `requires` is matched against detected
  `Capability.kind`s before a `Run` starts.

## See also

- [`../terminal_mcp.md`](../terminal_mcp.md) — Terminal MCP endpoint, wire shape,
  scoping, and tool reference.
- [`../preview_mcp.md`](../preview_mcp.md) — Preview MCP endpoint, tool flow, and
  pane lifecycle.
- [`../architecture.md`](../architecture.md) — system-level first principles
  (FP-10: agent MCP tool calls leave reviewable evidence).
- [`../glossary.md`](../glossary.md) — term constraints (workspace, session,
  capability).
