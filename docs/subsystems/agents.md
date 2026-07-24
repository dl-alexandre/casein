# Agents / MCP capability layer

> Detect what agent capabilities a workspace has, and give external coding
> agents (Grok, Claude, Codex, opencode) narrow, audited tool access to a
> workspace's tmux sessions and preview surfaces over MCP.

## Responsibility

`DevIDE.Agents.*` is the capability + tool layer that connects external agents
to a workspace. It does four distinct jobs:

1. **Capability detection** (`DevIDE.Agents`, `LocalAdapter`, the
   `*Capability` modules) — observe, read-only, what agent features a
   workspace exposes (opencode config, fff, browser artifacts, transcripts, and
   the MCP endpoints: terminal, preview, artifact, and Tidewave). Per the
   `DevIDE.Agents`
   M7 contract this layer **never** starts agents, sends prompts, or grants
   permissions — every public function is a query.
2. **Agent-facing tools** (`TerminalTools`, `PreviewTools`, `ArtifactTools`,
   `AnnotationTools`, `BrowserControl`) — the actual MCP tool definitions and
   dispatch handlers that let an agent drive tmux, previews, and artifact
   worktrees without arbitrary shell or browser access. The web layer
   (`DevIdeWeb.API.TerminalMCP` / `PreviewMCP` / `ArtifactMCP`) wraps these in
   JSON-RPC.
3. **Wiring agents in** (`MCPUrls`, `MCPMaterializer`, `PaneEnv`, `TidewaveMCP`)
   — build the MCP endpoint URLs, materialize per-workspace client config files
   for each agent CLI, and push the `DEVIDE_*` env into a tmux session so a bare
   `claude` / `grok` / `codex` command picks up the DevIDE MCP servers
   automatically.
4. **Operational replay** (`AgentEvents`, `AgentEvent`, `Activity`) — append
   metadata-only MCP, ACP, semantic-state, transcript identity, permission, and
   worktree handoff events to a durable per-session stream, then project them
   into the live History feed. This is separate from the security-oriented
   `Audit` log.

Side-effecting runtime control deliberately lives beside this read-only facade:
`DevIDE.AgentSessions.GrokACP` supervises a structured Grok ACP observer, while
`ReviewCommand` / `Run` support allowlisted review-mode agent runs with
compile-time-fixed argv.

## Module map

| Module | File | Role |
|--------|------|------|
| `DevIDE.Agents` | `lib/dev_ide/agents.ex` | Behaviour + public query API (`detect/2`, `transcripts/1`, `review_commands/1`); dispatches to the configured `:agents_adapter`. Read-only M7 contract. |
| `DevIDE.Agents.LocalAdapter` | `lib/dev_ide/agents/local_adapter.ex` | Default adapter: filesystem + metadata detection of capabilities. Read-only; all path access via `Files.PathSafety`. |
| `DevIDE.Agents.Capability` | `lib/dev_ide/agents/capability.ex` | Struct for one observed capability (`kind`, `status`, `source`, `url`, `details`). |
| `DevIDE.Agents.Artifact` | `lib/dev_ide/agents/artifact.ex` | Read-only file pointer (e.g. transcript) returned by detection. |
| `DevIDE.Agents.TerminalMCPCapability` | `lib/dev_ide/agents/terminal_mcp_capability.ex` | Detect the terminal-control MCP endpoint; advertises URL + tool names. |
| `DevIDE.Agents.PreviewTools.MCPCapability` | `lib/dev_ide/agents/preview_tools/mcp_capability.ex` | Detect the preview-control MCP endpoint; advertises URL + tool names. |
| `DevIDE.Agents.ArtifactMCPCapability` | `lib/dev_ide/agents/artifact_mcp_capability.ex` | Detect the artifact-project MCP endpoint; advertises URL + tool names. |
| `DevIDE.Agents.TidewaveCapability` | `lib/dev_ide/agents/tidewave_capability.ex` | Detect locally-hosted Tidewave (dev/preview-env only) via configured URL-provider MFA. |
| `DevIDE.Agents.TerminalTools` | `lib/dev_ide/agents/terminal_tools.ex` | MCP tool definitions + dispatch for tmux control (list/topology/capture/send/label/worktree). `devide_`-prefix and workspace scoping. |
| `DevIDE.Agents.PreviewTools` | `lib/dev_ide/agents/preview_tools.ex` | MCP tool definitions + dispatch for preview control (open/observe/click/type/screenshot/navigate/reload). |
| `DevIDE.Agents.ArtifactTools` | `lib/dev_ide/agents/artifact_tools.ex` | MCP tool definitions + dispatch for artifact projects (create/update/list/get/serve/snapshot). |
| `DevIDE.Agents.AnnotationTools` | `lib/dev_ide/agents/annotation_tools.ex` | Annotation tools (`annotation_list`, `annotation_propose`) appended to the terminal tool set. |
| `DevIDE.Agents.PreviewTools.BrowserControl` | `lib/dev_ide/agents/preview_tools/browser_control.ex` | Best-effort `push_event` broadcasts to connected workspace LiveViews (reload iframe / reload page). |
| `DevIDE.Agents.TerminalOutputFormat` | `lib/dev_ide/agents/terminal_output_format.ex` | Normalize tmux scrollback (strip ANSI by default) for token-cheap agent output. |
| `DevIDE.Agents.MCPUrls` | `lib/dev_ide/agents/mcp_urls.ex` | Build terminal/preview/artifact MCP endpoint URLs from config/env, pre-scoping `workspace_id`. |
| `DevIDE.Agents.MCPMaterializer` | `lib/dev_ide/agents/mcp_materializer.ex` | Write per-workspace agent client configs (Grok/Codex/opencode/Cursor/`.mcp.json`/`env.sh`) into a staging home. |
| `DevIDE.Agents.AgentCapabilityToken` / `AgentCapabilityTokens` | `lib/dev_ide/agents/agent_capability_token.ex`, `lib/dev_ide/agents/agent_capability_tokens.ex` | Hash-at-rest, expiring managed-Grok bearer claims and replacement/revocation lifecycle. |
| `DevIDE.Agents.GrokCapabilityPolicy` | `lib/dev_ide/agents/grok_capability_policy.ex` | Computes exact direct-tool grants and intersects them with live workspace mode/write-unlock policy on every request. |
| `DevIDE.Agents.PaneEnv` | `lib/dev_ide/agents/pane_env.ex` | Build the `DEVIDE_*` env map and push it into a tmux session; materializes configs as a side effect. |
| `DevIDE.Agents.AuthProfile` | `lib/dev_ide/agents/auth_profile.ex` | Resolve opt-in owner Claude/Codex auth homes under `~/.devide/agent-auth/profiles/<owner>/<runtime>`. A profile only activates once signed in (`.credentials.json` / `auth.json` present); otherwise the runtime defaults to the host global provider login — except owners registered in `agent-auth/owners`, whose profiles apply even before sign-in (opt-in fail-closed). |
| `DevIDE.Agents.TidewaveMCP` | `lib/dev_ide/agents/tidewave_mcp.ex` | Resolve an optional Tidewave MCP URL (env → self-hosted → workspace metadata → preview registry) + server key. |
| `DevIDE.Agents.MCPAudit` | `lib/dev_ide/agents/mcp_audit.ex` | Record every tool completion as a metadata-only `AgentEvent` and in `Activity`; emit an `Audit` event for successful mutating tools; propose labels from terminal calls. |
| `DevIDE.Agents.MCPError` | `lib/dev_ide/agents/mcp_error.ex` | Normalize `{:error, reason}` from tool handlers into MCP `structuredContent` payloads. |
| `DevIDE.Agents.AgentEvent` / `AgentEvents` | `lib/dev_ide/agents/agent_event.ex`, `lib/dev_ide/agents/agent_events.ex` | Durable normalized agent timeline with native source-id dedupe, session/correlation queries, replay cursors, privacy constructors, and Jido publication. |
| `DevIDE.Agents.Activity` | `lib/dev_ide/agents/activity.ex` | Live operator feed. It remains a transient PubSub/cache projection and hydrates its reads from durable `AgentEvents`. |
| `DevIDE.Agents.ReviewCommand` | `lib/dev_ide/agents/review_command.ex` | Allowlisted review-mode command; argv fixed at compile time, gated on detected capabilities. |
| `DevIDE.Agents.Run` | `lib/dev_ide/agents/run.ex` | One in-flight review-mode run per workspace (supervised, linger, hard timeout). |
| `DevIDE.AgentSessions.GrokACP` | `lib/dev_ide/agent_sessions/grok_acp.ex` | Supervised Grok leader attachment: initialize/authenticate, `session/new` or `session/load`, normalize tool/plan/permission events into `Activity`. |
| `DevIDE.AgentSessions.GrokACP.Attachments` | `lib/dev_ide/agent_sessions/grok_acp/attachments.ex` | Validates hook-reported private leader/bundle metadata, owns one ACP attachment per workspace/Grok session, and exposes workspace-scoped permission snapshots and decisions. |
| `DevIDE.AgentSessions.GrokACP.Transport.Stdio` | `lib/dev_ide/agent_sessions/grok_acp/transport/stdio.ex` | Starts or adopts a no-auto-update Grok leader and talks ACP through Grok's supported newline-JSON stdio bridge. |

## Data flow / lifecycle

**Wiring an agent into a workspace (session setup):**

1. `PaneEnv.ensure_for_session/3` (or `vars_for_workspace/2`) is called for a
   workspace tmux session.
2. It resolves the workspace bootstrap token, then calls
   `MCPMaterializer.materialize/2`, which
   writes a staging home containing `grok/config.toml`, `codex/config.toml`,
   `opencode.json`, `.mcp.json`, `cursor/mcp.json`, and `env.sh`. Grok,
   OpenCode, Claude/Cursor staging configs point at the terminal + preview MCP URLs
   (from `MCPUrls`) with a `Bearer ${CASEIN_API_TOKEN}` header, plus an
   optional Tidewave server (from `TidewaveMCP.resolve_url/2`). Managed Grok has
   a separate `grok/.mcp.json` containing only the three DevIDE-authenticated
   servers; Tidewave is excluded because it is outside `ApiAuth`. Codex staging is
   intentionally free of DevIDE MCP entries; the launcher injects them at
   runtime. Cursor's `mcp.json` is also copied into the checkout's `.cursor/`.
3. `PaneEnv.ensure_for_session/3` (and app boot via
   `Terminals.Shims.sync_tmux_terminal_env!/0`) self-heals missing agent
   launcher shims via `DevIDE.Agents.AgentShims.ensure/0` (partial loss of e.g.
   only `claude` has bitten after deploys/npm updates), refreshes
   `:tmux_ctl` `:terminal_env` so the next `new-window`/`split-window` gets
   `-e PATH=…` with agent bins, then builds the `DEVIDE_*` env map
   (`CASEIN_API_TOKEN`, `DEVIDE_WORKSPACE_ID`, `DEVIDE_TERMINAL_MCP_URL`,
   `DEVIDE_PREVIEW_MCP_URL`, `DEVIDE_AGENT_MCP_HOME`, prepended `PATH`, optional
   `DEVIDE_TIDEWAVE_MCP_URL`) and pushes it into the session with
   `Tmux.set_environments/2`. Template apply calls this **before** creating
   panes so the first window is not racy. `PATH` always includes
   `~/.devide/agent-shims` and the npm global bin dir (also embedded in
   `Terminals.Shims.path_with_shims/1`; shell-integration force-fronts them
   after user rc files run, so session create is not bashrc-dependent and
   installer-prepended dirs cannot shadow the launchers). The shim dir is
   never on PATH outside DevIDE contexts — plain terminals resolve agent
   names to the real binaries. `PaneEnv` also injects
   `CLAUDE_CONFIG_DIR` and `CODEX_HOME` under
   `~/.devide/agent-auth/profiles/<owner>/<runtime>` when that owner profile is
   signed in (`.credentials.json` / `auth.json` present); otherwise the
   runtime keeps the host global provider login.
4. Launching a shimmed agent binary in that pane picks up the materialized config
   + env, so MCP injection is automatic. Claude reads the staged `.mcp.json`,
   managed Grok receives the immutable bundle through leader ACP metadata,
   OpenCode reads project
   `.opencode/opencode.json`, and Codex receives DevIDE MCP through launch-time
   `-c mcp_servers...` overrides. Codex defaults are workspace-mode aware:
   review/observe/locked use `read-only + never`, while manual workspaces use
   `workspace-write + on-request`. Unrestricted mode is an explicit opt-in via
   `DEVIDE_CODEX_DEFAULT_YOLO=1`; bearer credentials are excluded from Codex's
   repo-command environment while remaining available to the MCP client.
   Claude still defaults to `--dangerously-skip-permissions` unless the operator
   passes an explicit permission option or sets `DEVIDE_CLAUDE_DEFAULT_YOLO=0`.
   Palette id `clauded` maps to bare `claude`
   (`PaneEnv.launch_command/3` / allowlist) — do not rely on the host bash alias.
   Plain agent starts do not depend on `CASEIN_API_TOKEN` because DevIDE MCP is
   not persisted in global agent configs. Version/help probes
   (`--version`/`--help`/`-h` for any runtime, plus `codex update|doctor` and
   `claude update`) bypass the launcher entirely and exec the real binary —
   they never resolve env, create a worktree, or inject MCP
   (`agent_runtime_passthrough` in `scripts/devide`). `install-agent-shims.sh`
   (`--check` / `--ensure`), the deploy poller, and `devide agent doctor` all
   verify shim completeness and PATH precedence; a shadowed or partial shim set
   is a hard failure because agents would launch without MCP or with
   `command not found`. When no agent env resolves, `devide agent launch`
   silently falls back to the real binary (`DEVIDE_AGENT_LAUNCH_VERBOSE=1`
   explains the fallback on stderr; `DEVIDE_AGENT_LAUNCH_STRICT=1` restores
   the hard failure), and the installer's migration cleanup removes legacy
   launcher shims from `~/.local/bin` so plain terminals are untouched by
   DevIDE. Every launch also stamps the tmux pane options `@devide_paired`
   (`1`/`0`) and `@devide_paired_reason`; topology reads them
   (`TmuxCtl.Client` `list-panes` formats → pane `paired`/`paired_reason`)
   and the viewer badges unpaired panes in the terminal chrome — pairing
   failures are visible in the UI, never as terminal output.

**An agent calling a tool (request lifecycle):**

1. Agent POSTs JSON-RPC to `/api/terminals/mcp`, `/api/preview/mcp`, or
   `/api/artifacts/mcp` (bearer auth). The thin `*MCPController` hands the
   decoded message to `DevIdeWeb.API.TerminalMCP.handle/2` /
   `PreviewMCP.handle/2` / `ArtifactMCP.handle/2`.
2. The web handler resolves/scopes `workspace_id` (pre-scoped from the URL query
   param when present), then dispatches `tools/call` to
   `TerminalTools.invoke/2`, `PreviewTools.invoke/3`, or `ArtifactTools.invoke/2`.
3. The tool handler validates scope (terminal: `devide_` prefix +
   `workspace_matches?`; preview: `ensure_pane_workspace_scope`), performs the
   tmux/preview operation, and returns `{:ok, map}` or `{:error, reason}`.
4. Result is recorded via `MCPAudit.record_terminal/3` /
   `record_preview/4` / `record_artifact/4` (→ metadata-only `mcp.completed`
   `AgentEvent` + `Activity` feed; `Audit.emit!` for successful mutating tools;
   label proposals), and errors are shaped by `MCPError` into MCP
   `structuredContent`.

**Observing a shared Grok leader session:**

Before Grok starts, the trusted launcher exchanges the durable workspace bearer
for a 12-hour `grokcap_*` capability. Only its SHA-256 hash is stored. The claim
is bound to one workspace, private leader, bundle digest, checkout digest, tmux
session, and exact agent pane; minting a replacement for that binding revokes the
old bearer. The durable bootstrap/admin values are removed from the child
environment, and the raw capability cache plus known credential roots are denied
to Grok's native tools by a managed sandbox profile. Materialization, bundle
verification, capability exchange, and sandbox installation all fail closed for
managed Grok launches.

The token's direct-tool map is a frozen ceiling and is intersected with current
workspace policy on every MCP request. Locked/manual operation exposes reads and
metadata reporting only. An active, time-boxed write unlock adds supported
mutations, but raw `terminal_send_command` and `terminal_send_keys` are never
granted; pane-taking tools are forced to the claimed agent pane. Revoking the
unlock removes MCP mutations immediately. A later launch also changes the sandbox
signature and restarts an existing leader rather than reusing a previously
writable native-tool sandbox. Write-enabled leaders extend Grok's `strict`
profile; locked leaders extend `read-only` with explicit credential denies.

`search_tools` and `invoke_tool` are intentionally absent, so cross-server
routing cannot bypass the exact grant. Streamable HTTP session ids are also bound
to server, workspace, and bearer scope. The capability follows the private
leader—not one native Grok `sessionId`—because a leader is deliberately shared by
the TUI and ACP and may host multiple conversations. Expiry or explicit
revocation takes effect on the next request; relaunching renews an expired leader
capability.

1. A managed Grok hook reports `agent_runtime`, Grok `sessionId`, transcript,
   private leader socket, and content-addressed capability bundle metadata through
   `terminal_report_agent_state`. The tool derives cwd from the target tmux pane;
   caller-supplied cwd is never trusted.
2. `GrokACP.Attachments` accepts only Grok transcripts under `~/.grok/sessions`,
   direct `<24hex>.sock` children of the configured private leader root (or its
   deterministic short-path fallback when Unix socket limits require it), and
   bundles accepted by `GrokCapabilityBundle.allowed_path?/1` whose directory
   name matches the reported SHA-256 digest. The global `~/.grok/leader.sock`
   and partial reports do not trigger a process.
3. The manager starts a transient `GrokACP` child under the agents supervision
   tree, keyed by workspace plus Grok session. Repeated
   reports reuse it; a changed socket/cwd/bundle stops and recreates the
   attachment so the visible digest cannot drift from the active plugin.
4. The stdio transport starts (or adopts) a Grok leader on the configured Unix
   socket with leader auto-update disabled, then attaches an official
   `grok agent --leader stdio` bridge. DevIDE does not implement Grok's private
   socket framing.
5. The client sends ACP `initialize`, uses the authentication method advertised
   by that response, and calls `session/load` for a known Grok session ID or
   `session/new` otherwise. ACP has no separate subscription request: loading or
   creating the session makes this client a leader subscriber. Negotiated
   `_meta.pluginDirs` receives the validated bundle; unsupported extensions are
   not sent.
6. `tool_call`, `tool_call_update`, `plan`, and `session/request_permission`
   messages are appended first as metadata-only `AgentEvent`s using Grok's
   native `_meta.eventId` (or a deterministic fallback), then projected into
   `Activity`. Reconnect replay dedupes on workspace + logical stream + native
   source id. Raw prompts, tool input/output, and plan content are not copied.
7. Permission requests remain pending until the workspace-scoped Attachments
   API responds or cancels them; successful responses append
   `permission.decided`. Safe snapshots broadcast on
   `grok_acp_attachments:<workspace_id>` for an operator UI without exposing
   socket, cwd, or bundle paths.
   Requests are never auto-denied because Grok broadcasts a shared request to
   the TUI and DevIDE, with the first response winning.

**Durable AgentEvent projection:**

- `agent_events` is operational replay, not security evidence. Audit decisions
  continue to use `audit_events`; neither store replaces the other.
- `{workspace_id, stream_id, source_event_id}` is unique. `ingress` is deliberately
  excluded so ACP and transcript recovery can converge on one source event.
- `replay/2` advances by opaque `{inserted_at, id}` cursor; `occurred_at` remains
  the source/display time so late transcript backfill is not skipped.
- Constructors allowlist metadata. Raw prompts, assistant text, thoughts, code,
  command/keys/text, and tool input/output are excluded. Deliberate handoff text
  is the sole current `operator_content` payload.
- Inserted events publish `devide.agent_event.*` Jido signals with the same event
  id and Grok/Claude `agent_session_id`. Blocked Audit/Jido payloads also carry
  `agent_session_id` when the hook supplied one.

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
- `DevIDE.Agents.AgentShims.ensure/0`, `missing/0`, `complete?/0` — self-heal
  DevIDE launcher shims under `~/.devide/agent-shims`.
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
- `DevIDE.Agents.AgentEvents.append_runtime/1`, `append_mcp/4`,
  `append_state_transition/1`, `append_handoff/1`, `recent_for/2`,
  `list_for_session/3`, `replay/2` — normalized append/recovery surface.
- `DevIDE.Agents.MCPError.*` — error normalization for tool handlers.
- `DevIDE.Agents.*Capability.detect/0` — individual endpoint detection.
- `DevIDE.AgentSessions.GrokACP.ensure_started/3`, `status/1`, `attach/2`,
  `respond_permission/3`, `cancel_permission/2` — supervised structured Grok
  session observation and explicit permission responses.
- `DevIDE.AgentSessions.GrokACP.Attachments.observe/1`, `list/1`, `subscribe/1`,
  `respond_permission/4`, `cancel_permission/3` — production leader lifecycle
  and workspace-safe approval surface.

## Invariants & gotchas

- **Detection is read-only (M7).** `DevIDE.Agents` and `LocalAdapter` observe
  only; they never start agents or grant permissions. Don't add side effects to
  the detection path. Side-effecting ACP lifecycle belongs in the dedicated
  agent-session modules.
- **Web layer depends on context, not the reverse.** `TerminalMCPCapability` /
  `PreviewMCPCapability` / `ArtifactMCPCapability` / `TidewaveCapability` resolve the endpoint base URL
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
- **Provider auth profiles are opt-in and require a completed sign-in.** Do not
  persist provider secrets in `workspace_records` or manager metadata. The
  current compatibility behavior uses the host global provider login when a
  profile directory or its provider credentials (`.credentials.json` for
  Claude, `auth.json` for Codex) are missing. This fallback is intended only for
  trusted single-operator environments; multi-user deployments should set
  `DEVIDE_AGENT_AUTH_FALLBACK=none` so a workspace fails closed until its owner
  signs in. Run `devide agent auth signin <runtime>` from a DevIDE workspace
  once per provider, or `devide agent auth signin <owner> <runtime>` outside a
  workspace. Workspaces named `<owner>-...` use that owner's profile after
  sign-in. Use `devide agent auth status [workspace] [runtime]` or `devide agent
  auth list` to audit profile and sign-in state.
- **Registered owners never fall back to the host global login.**
  `~/.devide/agent-auth/owners` lists owner slugs (one per line, `#` comments)
  managed with `devide agent auth register <owner>` / `unregister <owner>`.
  For a registered owner the profile dir applies even before sign-in, so
  Claude/Codex prompt for their own login inside the profile instead of using
  the host global account. `DEVIDE_AGENT_AUTH_FALLBACK=none` treats every
  owner as registered. Per-owner registration remains opt-in for compatibility;
  fail-closed authentication for every owner is the recommended policy for
  multi-user deployments.
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
