# Agents / MCP capability layer

> Detect what agent capabilities a workspace has, and give external coding
> agents (Grok, Claude, Codex, opencode) narrow, audited tool access to a
> workspace's tmux sessions and preview surfaces over MCP.

## Responsibility

`Casein.Agents.*` is the capability + tool layer that connects external agents
to a workspace. It does four distinct jobs:

1. **Capability detection** (`Casein.Agents`, `LocalAdapter`, the
   `*Capability` modules) — observe, read-only, what agent features a
   workspace exposes (opencode config, fff, browser artifacts, transcripts, and
   the MCP endpoints: terminal, preview, artifact, and Tidewave). Per the
   `Casein.Agents`
   M7 contract this layer **never** starts agents, sends prompts, or grants
   permissions — every public function is a query.
2. **Agent-facing tools** (`TerminalTools`, `PreviewTools`, `ArtifactTools`,
   `AnnotationTools`, `BrowserControl`) — the actual MCP tool definitions and
   dispatch handlers that let an agent drive tmux, previews, and artifact
   worktrees without arbitrary shell or browser access. The web layer
   (`CaseinWeb.API.TerminalMCP` / `PreviewMCP` / `ArtifactMCP`) wraps these in
   JSON-RPC.
3. **Wiring agents in** (`MCPUrls`, `MCPMaterializer`, `PaneEnv`, `TidewaveMCP`)
   — build the MCP endpoint URLs, materialize per-workspace client config files
   for each agent CLI, and push the `CASEIN_*` env into a tmux session so a bare
   `claude` / `grok` / `codex` command picks up the Casein MCP servers
   automatically.
4. **Operational replay** (`AgentEvents`, `AgentEvent`, `Activity`) — append
   metadata-only MCP, ACP, semantic-state, transcript identity, permission, and
   worktree handoff events to a durable per-session stream, then project them
   into the live History feed. This is separate from the security-oriented
   `Audit` log.

Side-effecting runtime control deliberately lives beside this read-only facade:
`Casein.AgentSessions.GrokACP` supervises a structured Grok ACP observer, while
`ReviewCommand` / `Run` support allowlisted review-mode agent runs with
compile-time-fixed argv.

## Module map

| Module | File | Role |
|--------|------|------|
| `Casein.Agents` | `lib/casein/agents.ex` | Behaviour + public query API (`detect/2`, `transcripts/1`, `review_commands/1`); dispatches to the configured `:agents_adapter`. Read-only M7 contract. |
| `Casein.Agents.LocalAdapter` | `lib/casein/agents/local_adapter.ex` | Default adapter: filesystem + metadata detection of capabilities. Read-only; all path access via `Files.PathSafety`. |
| `Casein.Agents.Capability` | `lib/casein/agents/capability.ex` | Struct for one observed capability (`kind`, `status`, `source`, `url`, `details`). |
| `Casein.Agents.Artifact` | `lib/casein/agents/artifact.ex` | Read-only file pointer (e.g. transcript) returned by detection. |
| `Casein.Agents.TerminalMCPCapability` | `lib/casein/agents/terminal_mcp_capability.ex` | Detect the terminal-control MCP endpoint; advertises URL + tool names. |
| `Casein.Agents.PreviewTools.MCPCapability` | `lib/casein/agents/preview_tools/mcp_capability.ex` | Detect the preview-control MCP endpoint; advertises URL + tool names. |
| `Casein.Agents.ArtifactMCPCapability` | `lib/casein/agents/artifact_mcp_capability.ex` | Detect the artifact-project MCP endpoint; advertises URL + tool names. |
| `Casein.Agents.TidewaveCapability` | `lib/casein/agents/tidewave_capability.ex` | Detect locally-hosted Tidewave (dev/preview-env only) via configured URL-provider MFA. |
| `Casein.Agents.TerminalTools` | `lib/casein/agents/terminal_tools.ex` | MCP tool definitions + dispatch for tmux control (list/topology/capture/send/label/worktree). `casein_`-prefix and workspace scoping. |
| `Casein.Agents.PreviewTools` | `lib/casein/agents/preview_tools.ex` | MCP tool definitions + dispatch for preview control (open/observe/click/type/screenshot/navigate/reload). |
| `Casein.Agents.ArtifactTools` | `lib/casein/agents/artifact_tools.ex` | MCP tool definitions + dispatch for artifact projects (create/update/list/get/serve/snapshot). |
| `Casein.Agents.AnnotationTools` | `lib/casein/agents/annotation_tools.ex` | Annotation tools (`annotation_list`, `annotation_propose`) appended to the terminal tool set. |
| `Casein.Agents.PreviewTools.BrowserControl` | `lib/casein/agents/preview_tools/browser_control.ex` | Best-effort `push_event` broadcasts to connected workspace LiveViews (reload iframe / reload page). |
| `Casein.Agents.TerminalOutputFormat` | `lib/casein/agents/terminal_output_format.ex` | Normalize tmux scrollback (strip ANSI by default) for token-cheap agent output. |
| `Casein.Agents.MCPUrls` | `lib/casein/agents/mcp_urls.ex` | Build terminal/preview/artifact MCP endpoint URLs from config/env, pre-scoping `workspace_id`. |
| `Casein.Agents.MCPMaterializer` | `lib/casein/agents/mcp_materializer.ex` | Write per-workspace agent client configs (Grok/Codex/opencode/Cursor/`.mcp.json`/`env.sh`) into a staging home. |
| `Casein.Agents.AgentCapabilityToken` / `AgentCapabilityTokens` | `lib/casein/agents/agent_capability_token.ex`, `lib/casein/agents/agent_capability_tokens.ex` | Hash-at-rest, expiring managed-Grok bearer claims and replacement/revocation lifecycle. |
| `Casein.Agents.GrokCapabilityPolicy` | `lib/casein/agents/grok_capability_policy.ex` | Computes exact direct-tool grants and intersects them with live workspace mode/write-unlock policy on every request. |
| `Casein.Agents.PaneEnv` | `lib/casein/agents/pane_env.ex` | Build the `CASEIN_*` env map and push it into a tmux session; materializes configs as a side effect. |
| `Casein.Agents.AuthProfile` | `lib/casein/agents/auth_profile.ex` | Resolve opt-in owner Claude/Codex auth homes under `~/.casein/agent-auth/profiles/<owner>/<runtime>`. A profile only activates once signed in (`.credentials.json` / `auth.json` present); otherwise the runtime defaults to the host global provider login — except owners registered in `agent-auth/owners`, whose profiles apply even before sign-in (opt-in fail-closed). |
| `Casein.Agents.TidewaveMCP` | `lib/casein/agents/tidewave_mcp.ex` | Resolve an optional Tidewave MCP URL (env → self-hosted → workspace metadata → preview registry) + server key. |
| `Casein.Agents.MCPAudit` | `lib/casein/agents/mcp_audit.ex` | Record every tool completion as a metadata-only `AgentEvent` and in `Activity`; emit an `Audit` event for successful mutating tools; propose labels from terminal calls. |
| `Casein.Agents.MCPError` | `lib/casein/agents/mcp_error.ex` | Normalize `{:error, reason}` from tool handlers into MCP `structuredContent` payloads. |
| `Casein.Agents.AgentEvent` / `AgentEvents` | `lib/casein/agents/agent_event.ex`, `lib/casein/agents/agent_events.ex` | Durable normalized agent timeline with native source-id dedupe, session/correlation queries, replay cursors, privacy constructors, and Jido publication. |
| `Casein.Agents.Activity` | `lib/casein/agents/activity.ex` | Live operator feed. It remains a transient PubSub/cache projection and hydrates its reads from durable `AgentEvents`. |
| `Casein.Agents.ReviewCommand` | `lib/casein/agents/review_command.ex` | Allowlisted review-mode command; argv fixed at compile time, gated on detected capabilities. |
| `Casein.Agents.Run` | `lib/casein/agents/run.ex` | One in-flight review-mode run per workspace (supervised, linger, hard timeout). |
| `Casein.Desktop.AgentLauncher` | `lib/casein/desktop/agent_launcher.ex` | Native Windows runtime allowlist plus token-free executable/version/auth diagnostics. |
| `Casein.Desktop.AgentWorktree` | `lib/casein/desktop/agent_worktree.ex` | Native Windows isolated worktree creation with validated product-derived paths and argv-only Git execution. |
| `Casein.Desktop.NativeAgentLaunch` | `lib/casein/desktop/native_agent_launch.ex` | Provides one prepare/start transaction across isolated worktree creation, provider MCP materialization, topology-validated ConPTY pane input, runtime reporting, and explicit clean-only finish cleanup. |
| `Casein.AgentSessions.GrokACP` | `lib/casein/agent_sessions/grok_acp.ex` | Supervised Grok leader attachment: initialize/authenticate, `session/new` or `session/load`, normalize tool/plan/permission events into `Activity`. |
| `Casein.AgentSessions.GrokACP.Attachments` | `lib/casein/agent_sessions/grok_acp/attachments.ex` | Validates hook-reported private leader/bundle metadata, owns one ACP attachment per workspace/Grok session, and exposes workspace-scoped permission snapshots and decisions. |
| `Casein.AgentSessions.GrokACP.Transport.Stdio` | `lib/casein/agent_sessions/grok_acp/transport/stdio.ex` | Starts or adopts a no-auto-update Grok leader and talks ACP through Grok's supported newline-JSON stdio bridge. |

## Data flow / lifecycle

**Native Windows worktree boundary:**

`Casein.Desktop.AgentWorktree` accepts only the five native provider ids and a
short lowercase task slug. It resolves the primary repository with Git, derives
the branch and worktree path itself, canonicalizes symlink/junction ancestors,
rejects any resolved root inside the primary checkout, and invokes the fixed
`git` executable with an argv list. Provider input cannot supply a command,
worktree target, or shell fragment.
Runtime launch integration and clean-only reaping remain separate follow-up
slices; creating the worktree alone does not start an agent or alter the web UI.

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
   a separate `grok/.mcp.json` containing only the three Casein-authenticated
   servers; Tidewave is excluded because it is outside `ApiAuth`. Codex staging is
   intentionally free of Casein MCP entries; the launcher injects them at
   runtime. Cursor's `mcp.json` is also copied into the checkout's `.cursor/`.
3. `PaneEnv.ensure_for_session/3` (and app boot via
   `Terminals.Shims.sync_tmux_terminal_env!/0`) self-heals missing agent
   launcher shims via `Casein.Agents.AgentShims.ensure/0` (partial loss of e.g.
   only `claude` has bitten after deploys/npm updates), refreshes
   `:tmux_ctl` `:terminal_env` so the next `new-window`/`split-window` gets
   `-e PATH=…` with agent bins, then builds the `CASEIN_*` env map
   (`CASEIN_API_TOKEN`, `CASEIN_WORKSPACE_ID`, `CASEIN_TERMINAL_MCP_URL`,
   `CASEIN_PREVIEW_MCP_URL`, `CASEIN_AGENT_MCP_HOME`, prepended `PATH`, optional
   `CASEIN_TIDEWAVE_MCP_URL`) and pushes it into the session with
   `Tmux.set_environments/2`. Template apply calls this **before** creating
   panes so the first window is not racy. `PATH` always includes
   `~/.casein/agent-shims` and the npm global bin dir (also embedded in
   `Terminals.Shims.path_with_shims/1`; shell-integration force-fronts them
   after user rc files run, so session create is not bashrc-dependent and
   installer-prepended dirs cannot shadow the launchers). The shim dir is
   never on PATH outside Casein contexts — plain terminals resolve agent
   names to the real binaries. `PaneEnv` also injects
   `CLAUDE_CONFIG_DIR` and `CODEX_HOME` under
   `~/.casein/agent-auth/profiles/<owner>/<runtime>` when that owner profile is
   signed in (`.credentials.json` / `auth.json` present); otherwise the
   runtime keeps the host global provider login.
4. Launching a shimmed agent binary in that pane picks up the materialized config
   + env, so MCP injection is automatic. Claude reads the staged `.mcp.json`,
   managed Grok receives the immutable bundle through leader ACP metadata,
   OpenCode reads project
   `.opencode/opencode.json`, and Codex receives Casein MCP through launch-time
   `-c mcp_servers...` overrides. Codex defaults are workspace-mode aware:
   review/observe/locked use `read-only + never`, while manual workspaces use
   `workspace-write + on-request`. Unrestricted mode is an explicit opt-in via
   `CASEIN_CODEX_DEFAULT_YOLO=1`; bearer credentials are excluded from Codex's
   repo-command environment while remaining available to the MCP client.
   The default is sandboxed `workspace-write + on-request`; unrestricted mode
   is never enabled implicitly.
   Claude still defaults to `--dangerously-skip-permissions` unless the operator
   passes an explicit permission option or sets `CASEIN_CLAUDE_DEFAULT_YOLO=0`.
   Palette id `clauded` maps to bare `claude`
   (`PaneEnv.launch_command/3` / allowlist) — do not rely on the host bash alias.
   Plain agent starts do not depend on `CASEIN_API_TOKEN` because Casein MCP is
   not persisted in global agent configs. Version/help probes
   (`--version`/`--help`/`-h` for any runtime, plus `codex update|doctor` and
   `claude update`) bypass the launcher entirely and exec the real binary —
   they never resolve env, create a worktree, or inject MCP
   (`agent_runtime_passthrough` in `scripts/casein`). `install-agent-shims.sh`
   (`--check` / `--ensure`), the deploy poller, and `casein agent doctor` all
   verify shim completeness and PATH precedence; a shadowed or partial shim set
   is a hard failure because agents would launch without MCP or with
   `command not found`. When no agent env resolves, `casein agent launch`
   silently falls back to the real binary (`CASEIN_AGENT_LAUNCH_VERBOSE=1`
   explains the fallback on stderr; `CASEIN_AGENT_LAUNCH_STRICT=1` restores
   the hard failure), and the installer's migration cleanup removes legacy
   launcher shims from `~/.local/bin` so plain terminals are untouched by
   Casein. Every launch also stamps the tmux pane options `@casein_paired`
   (`1`/`0`) and `@casein_paired_reason`; topology reads them
   (`TmuxCtl.Client` `list-panes` formats → pane `paired`/`paired_reason`)
   and the viewer badges unpaired panes in the terminal chrome — pairing
   failures are visible in the UI, never as terminal output.

**An agent calling a tool (request lifecycle):**

1. Agent POSTs JSON-RPC to `/api/terminals/mcp`, `/api/preview/mcp`, or
   `/api/artifacts/mcp` (bearer auth). The thin `*MCPController` hands the
   decoded message to `CaseinWeb.API.TerminalMCP.handle/2` /
   `PreviewMCP.handle/2` / `ArtifactMCP.handle/2`.
2. The web handler resolves/scopes `workspace_id` (pre-scoped from the URL query
   param when present), then dispatches `tools/call` to
   `TerminalTools.invoke/2`, `PreviewTools.invoke/3`, or `ArtifactTools.invoke/2`.
3. The tool handler validates scope (terminal: `casein_` prefix +
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

The token's direct-tool map is a frozen ceiling (the full write-capable set
issued at mint) and is intersected with current workspace policy on every MCP
request. Locked/manual operation exposes reads and metadata reporting only. An
active, time-boxed write unlock expands the live grant to supported mutations,
including raw `terminal_send_command` / `terminal_send_keys` for any pane in the
bound tmux session, so an agent can drive a verify or bash pane. Agent-pane
shortcuts (`terminal_send_agent_*`) stay pinned to the claimed agent pane.
Revoking the unlock removes MCP mutations immediately without re-minting. A
later launch also changes the sandbox signature and restarts an existing leader
rather than reusing a previously writable native-tool sandbox. Write-enabled
leaders extend Grok's `strict` profile; locked leaders extend `read-only` with
explicit credential denies.

The MCP grant and the filesystem sandbox therefore move on different clocks, and
the difference is the trap: MCP re-intersects per request, but the sandbox base
is chosen once, when the leader starts, and stays frozen for the pane's life. A
pane launched while locked reaches a normal-looking prompt yet cannot write its
worktree, reach the network, or start the BEAM — and a later grant does **not**
free it; only a relaunch does. Two surfaces make that discoverable instead of
leaving it to be rediscovered by failure: the workspace status API and
`terminal_context` both report an `agent_write` block (`write_enabled`,
`unlock_status`, `unlock_until`, plus a remedy note when blocked), and
`scripts/spawn-agent-worker.sh` preflights it — refusing to open a Grok worker
window with exit 3 rather than spawning a pane that cannot work. Note that
`write_enabled` can be false while the unlock is *active*, when the workspace is
not in manual mode or its DB isolation is `shared_stage`/`unsafe`; re-granting
does not help there, so the surfaces say so explicitly.

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
   `grok agent --leader stdio` bridge. Casein does not implement Grok's private
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
   the TUI and Casein, with the first response winning.

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
- Inserted events publish `casein.agent_event.*` Jido signals with the same event
  id and Grok/Claude `agent_session_id`. Blocked Audit/Jido payloads also carry
  `agent_session_id` when the hook supplied one.

**Capability detection (observe):**

`Casein.Agents.detect(root, workspace)` → `LocalAdapter.detect/2` →
`detect_filesystem_only/1` builds the capability list (opencode, fff, browser
artifacts) and folds in the three MCP capabilities via their `*Capability.detect/0`
modules. Tidewave is enriched from manager metadata / port fingerprints when
available. The list is surfaced through agent UI and `GET
/api/workspaces/:id/status` as `agent_capabilities`.

## Public surface

- `Casein.Agents.detect/2`, `transcripts/1`, `review_commands/1` — read-only
  capability queries (delegate to the configured adapter).
- `Casein.Agents.AgentShims.ensure/0`, `missing/0`, `complete?/0` — self-heal
  Casein launcher shims under `~/.casein/agent-shims`.
- `Casein.Agents.PaneEnv.vars_for_workspace/2`, `ensure_for_session/3`,
  `launch_command/3` — build/install the agent env for a tmux session.
- `Casein.Agents.MCPMaterializer.materialize/2` — write agent client config
  files; returns the staging-home path.
- `Casein.Agents.MCPUrls.terminal_url/1`, `preview_url/1`, `base_url/0` —
  endpoint URL construction.
- `Casein.Agents.TidewaveMCP.resolve_url/2`, `server_key/1`,
  `normalize_mcp_url/1` — optional Tidewave wiring.
- `Casein.Agents.TerminalTools.definitions/0`, `invoke/2` — terminal MCP tool
  surface (called by `CaseinWeb.API.TerminalMCP`).
- `Casein.Agents.PreviewTools.definitions/0`, `invoke/3` — preview MCP tool
  surface (called by `CaseinWeb.API.PreviewMCP`).
- `Casein.Agents.MCPAudit.record_terminal/3`, `record_preview/4` — audit +
  activity recording.
- `Casein.Agents.AgentEvents.append_runtime/1`, `append_mcp/4`,
  `append_state_transition/1`, `append_handoff/1`, `recent_for/2`,
  `list_for_session/3`, `replay/2` — normalized append/recovery surface.
- `Casein.Agents.MCPError.*` — error normalization for tool handlers.
- `Casein.Agents.*Capability.detect/0` — individual endpoint detection.
- `Casein.AgentSessions.GrokACP.ensure_started/3`, `status/1`, `attach/2`,
  `respond_permission/3`, `cancel_permission/2` — supervised structured Grok
  session observation and explicit permission responses.
- `Casein.AgentSessions.GrokACP.Attachments.observe/1`, `list/1`, `subscribe/1`,
  `respond_permission/4`, `cancel_permission/3` — production leader lifecycle
  and workspace-safe approval surface.

## Invariants & gotchas

- **Detection is read-only (M7).** `Casein.Agents` and `LocalAdapter` observe
  only; they never start agents or grant permissions. Don't add side effects to
  the detection path. Side-effecting ACP lifecycle belongs in the dedicated
  agent-session modules.
- **Web layer depends on context, not the reverse.** `TerminalMCPCapability` /
  `PreviewMCPCapability` / `ArtifactMCPCapability` / `TidewaveCapability` resolve the endpoint base URL
  through a configured MFA (`:tidewave_url_provider`, etc.) so context code never
  references `CaseinWeb.Endpoint`. Keep this inversion.
- **Bearer token is fully trusted on the host.** Scoping, not auth, is what
  keeps agents inside their workspace. Terminal tools only touch `casein_`-prefixed
  sessions; `workspace_id` resolves both the manager UUID *and* the workspace
  **name** to tmux prefixes (sessions are `casein_<name>_<sid>`). Cross-workspace
  access is rejected with `:workspace_mismatch`.
- **Pass `workspace_id` on every call.** Generated configs append
  `?workspace_id=<uuid>` so the transport injects it; without it, tools can see
  every `casein_*` session on the host.
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
  `CASEIN_AGENT_AUTH_FALLBACK=none` so a workspace fails closed until its owner
  signs in. Run `casein agent auth signin <runtime>` from a Casein workspace
  once per provider, or `casein agent auth signin <owner> <runtime>` outside a
  workspace. Workspaces named `<owner>-...` use that owner's profile after
  sign-in. Use `casein agent auth status [workspace] [runtime]` or `casein agent
  auth list` to audit profile and sign-in state.
- **Registered owners never fall back to the host global login.**
  `~/.casein/agent-auth/owners` lists owner slugs (one per line, `#` comments)
  managed with `casein agent auth register <owner>` / `unregister <owner>`.
  For a registered owner the profile dir applies even before sign-in, so
  Claude/Codex prompt for their own login inside the profile instead of using
  the host global account. `CASEIN_AGENT_AUTH_FALLBACK=none` treats every
  owner as registered. Per-owner registration remains opt-in for compatibility;
  fail-closed authentication for every owner is the recommended policy for
  multi-user deployments.
- **`review_command` argv is fixed at compile time.** Users pick an id from the
  allowlist; they never supply argv. `requires` is matched against detected
  `Capability.kind`s before a `Run` starts.
- **A pane id from `spawn-agent-worker.sh` means a live agent, not a window.**
  `tmux new-window -P` returns a pane id the moment the window exists, and the
  window survives its launch command failing late — which produced spawns that
  reported success for a window holding nothing but a shell, and callers that
  briefed a pane which could never answer. The helper now waits for the runtime's
  own process (the same executable `real_agent_bin` resolves for
  `launch-casein-agent.sh`) to appear in the pane's **process tree**, not just for
  a live pane: tmux runs the launch command under a shell that does not exec the
  tail of an `&&` chain, so the agent is a child of the pane process. Matching on
  `pane_current_command` alone is not enough either — a healthy Codex pane reports
  `node`. On failure it prints the pane tail, closes the window (or renames it
  `failed-worker-<slug>` under `CASEIN_SPAWN_KEEP_FAILED_WINDOW=1`), and exits
  non-zero. Budget is `CASEIN_SPAWN_READY_SECONDS` (default 120; `0` waives for
  callers running their own readiness check). Verify a box end to end with
  `scripts/smoke-spawn-agent-worker.sh <runtime>`, which re-checks the tree
  itself rather than trusting the exit code.

## See also

- [`../terminal_mcp.md`](../terminal_mcp.md) — Terminal MCP endpoint, wire shape,
  scoping, and tool reference.
- [`../preview_mcp.md`](../preview_mcp.md) — Preview MCP endpoint, tool flow, and
  pane lifecycle.
- [`../architecture.md`](../architecture.md) — system-level first principles
  (FP-10: agent MCP tool calls leave reviewable evidence).
- [`../glossary.md`](../glossary.md) — term constraints (workspace, session,
  capability).
