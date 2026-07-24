# Casein documentation index

> When implementation and docs diverge, **the docs win: fix the code.** Every
> doc here is a contract the code is judged against, not a transcript of what
> the code currently happens to do. Reported divergences live in
> [`coverage_map.md`](coverage_map.md#gaps--divergences) — they are open items
> against the code, not corrections to the docs.

[`architecture.md`](architecture.md) is the authoritative narrative for the
whole system: the first principles (§FP-1…FP-10), the subsystem map, and the
trust boundaries. Start there. Everything below either elaborates one slice of
that narrative (subsystem docs), pins an external contract (reference docs), or
runs the box (operations docs).

For the term constraints the architecture is stated in, see
[`glossary.md`](glossary.md). For the doc↔code ownership table and the running
list of divergences and `@moduledoc` gaps, see [`coverage_map.md`](coverage_map.md).

## Architecture & product

The cross-cutting narrative — read these to understand *why* the system is
shaped the way it is before diving into any one subsystem.

| Doc | Description |
|-----|-------------|
| [`architecture.md`](architecture.md) | Authoritative narrative: first principles, subsystem map, trust boundaries, authority map. |
| [`product.md`](product.md) | Product framing — what Casein is, the server/client boundary (§4), and the decision rules (§13). |
| [`glossary.md`](glossary.md) | Term constraints the invariants are stated in (authority, workspace, clients, sessions, policy, evidence). |
| [`naming-gate.md`](naming-gate.md) | Casein launch decision, objective naming evidence, accepted risks, and deferred follow-up checks. |
| [`state_machines.md`](state_machines.md) | The lifecycle state machines (workspace mode, runtime, run status). |
| [`sequence_diagrams.md`](sequence_diagrams.md) | End-to-end sequences across the web tier, terminals, agents, and audit. |

## Subsystem reference

One doc per `lib/` subsystem. Each owns a slice of the architecture narrative
and is the authoritative home for that slice's invariants. See
[`coverage_map.md`](coverage_map.md) for the directory→doc ownership table.

| Doc | Subsystem |
|-----|-----------|
| [`subsystems/terminals.md`](subsystems/terminals.md) | The server-side PTY/tmux session core: durable tmux-backed PTYs (one per workspace/sid), multi-viewer output fan-out with focused-viewer resize, scrollback replay, the tmux control plane, session templates, and raw-terminal admission. |
| [`subsystems/tmux_terminal_ctl.md`](subsystems/tmux_terminal_ctl.md) | In-repo, app-agnostic tmux control plane (topology reads/watcher, subprocess client/runner, adapter behaviour) plus PTY byte-stream helpers, forming the durable-session persistence boundary (FP-2). |
| [`subsystems/web_cockpit.md`](subsystems/web_cockpit.md) | The Phoenix/LiveView web cockpit that renders a workspace's durable terminal, tmux topology, files, runs, audit, and previews into the browser, where the browser is a viewer of a server-side PTY (FP-1), not an argv source. |
| [`subsystems/agents.md`](subsystems/agents.md) | Detects a workspace's agent capabilities and gives external coding agents narrow, audited MCP tool access to its tmux sessions and preview surfaces. |
| [`subsystems/previews.md`](subsystems/previews.md) | Opens, controls, observes, and embeds workspace-scoped browser previews for humans and MCP agents within the workspace-origin trust boundary. |
| [`subsystems/preview_ctl.md`](subsystems/preview_ctl.md) | The standalone in-repo preview/browser control library — origin guards, an ETS session registry, an adapter behaviour, and an optional Node Playwright bridge — that the Casein host wraps for persistence, allowlists, and iframe broadcasts. |
| [`subsystems/workspaces.md`](subsystems/workspaces.md) | The source-agnostic workspace aggregate (the addressable unit, §FP-5) plus its pluggable discovery/lifecycle source, redacted observed-state cache with mode resolution, and read-only DB-isolation classifier. |
| [`subsystems/runtimes.md`](subsystems/runtimes.md) | A record-only registry that projects where a workspace's work has executed (hosts, agent worktrees, lifecycle) without ever holding command-execution authority. |
| [`subsystems/code_intelligence.md`](subsystems/code_intelligence.md) | Read-only-by-default workspace navigation surfaces — path-safe file I/O, ripgrep search, git context/inspection, and lightweight Elixir introspection — all rooted in one workspace path that callers cannot escape. |
| [`subsystems/proposals.md`](subsystems/proposals.md) | Surfaces agent-produced unified-diff/patch artifacts for human review only — discovering, parsing, and risk-classifying them against the working tree, never applying them. |
| [`subsystems/palette_commands.md`](subsystems/palette_commands.md) | Turns a typed query into a ranked list of allowlisted actions and dispatches the selected one through an existing gated LiveView event, never a free-form command; adjacent Labels and Annotations subsystems supply ephemeral pane chrome and durable context notes. |
| [`subsystems/audit_activity.md`](subsystems/audit_activity.md) | The durable evidence plane that records every policy decision, agent MCP call, raw-terminal attach, and review-run lifecycle event as an append-only audit record, read back as a run ledger and evidence feed. |
| [`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md) | Server-side admission decision value types (FP-1), devbox release deploy/drain/drift coordination, and the redacted API export surface. |
| [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md) | The dependency-free `dev_ide_core` path package — `ExecCtl` (OS process execution + the authoritative command allowlist), `GitCtl` (git worktree inspection + ETS cache), and `McpCtl` (MCP tool-schema fragments) — the generic mechanism the `Casein.*` facades delegate into. |
| [`subsystems/push_notifications.md`](subsystems/push_notifications.md) | OS push fan-out (APNs/FCM) for session alerts and high-priority mobile cards — the offline counterpart to the live channel that reaches a backgrounded `devide_mob` app: native token acquisition, channel handoff, in-memory token registry, dispatcher, platform-routing providers, and the `CASEIN_*` runtime config to go live. |

## External surface reference

The contracts other systems (browsers, operator tools, coding agents) bind to.
Change these only by changing the doc first.

| Doc | Surface |
|-----|---------|
| [`reference/http_api.md`](reference/http_api.md) | The HTTP/LiveView/MCP route table and Phoenix channel topics — the thin transport tier mapping browser, operator-tool, and agent traffic onto `Casein.*` context calls. |
| [`reference/mcp_tools.md`](reference/mcp_tools.md) | The external MCP tool surface: narrow, bearer-gated, workspace-scoped JSON-RPC tools (terminal, preview, annotations) that drive Casein's tmux and browser previews, plus the external dev-only Tidewave endpoint. |
| [`reference/cli_and_keys.md`](reference/cli_and_keys.md) | The operator-facing surface: the `devide runtimes` CLI, mix tasks, the static command allowlist that gates palette/agent runs, and the `C-b` leader-key bindings. |
| [`deep_links.md`](deep_links.md) | Deep-link URL shapes into the cockpit (workspace/session/pane addressing). |
| [`workspace_sources.md`](workspace_sources.md) | The `Casein.WorkspaceSource` behaviour contract (Boundary 3). |
| [`leader_keys.md`](leader_keys.md) | Authoritative `C-b` leader-key bindings and how to add one. |
| [`terminal.md`](terminal.md) | Terminal renderer / raw path narrative (see terminals subsystem doc for the current server-core reality). |
| [`terminal_mcp.md`](terminal_mcp.md) | Terminal MCP tool contract for agents. |
| [`preview_mcp.md`](preview_mcp.md) | Preview MCP tool contract for agents. |
| [`tmux_control_plane.md`](tmux_control_plane.md) | tmux control-plane error/behaviour contract. |

## Operations

Running and shipping the box.

| Doc | Description |
|-----|-------------|
| [`deploy.md`](deploy.md) | Authoritative deploy runbook (Docker/compose path; on-box systemd specifics in `integrations/manager.md`). |
| [`lan-release-updates.md`](lan-release-updates.md) | LAN self-hosted update contract: relmeta metadata, channel manifests, `devide version` / `devide update check`, symlinked release layout. |
| [`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md) | The on-box deploy machinery: heartbeat registry, `current.sock` symlink, graceful drain, drift detection, deploy-status health probe. |
| [`audit_local.md`](audit_local.md) | Local/in-memory audit adapter behaviour and the run ledger as read locally. |
| [`audit_remote.md`](audit_remote.md) | Ecto-backed (prod default) audit adapter and the `audit_events` table. |
| [`hardening.md`](hardening.md) | Production hardening checklist (CSP, forward-auth, secrets). |
| [`integrations/manager.md`](integrations/manager.md) | devbox-manager / Caddy integration and the on-box systemd deploy path. |

## Working in this repo

Conventions and tracked follow-ups for contributors (human or agent).

| Doc | Description |
|-----|-------------|
| [`development-workflow.md`](development-workflow.md) | Canonical workflow: primary checkout is deploy-only, agents launch in reported worktrees, branching/integration/deploy tiers, subsystem freeze. **Start here.** |
| [`in-progress.md`](in-progress.md) | Direction-of-record for active subsystems — frozen paths while work is in flight. |
| [`agent_concurrency.md`](agent_concurrency.md) | How to work safely when multiple agents share this checkout: isolated worktrees, verify against `HEAD`, commit only your pathspecs. |
| [`coverage_map.md`](coverage_map.md) | Doc↔code ownership table, reported divergences, and the citation-verification record. |
| [`code_cleanup_backlog.md`](code_cleanup_backlog.md) | Actionable code findings (dead code, duplication, spec mismatches, stale comments) surfaced during documentation. |

> The doc-citation guard (`scripts/check-doc-citations.sh`, run by the pre-push
> gate) fails the push if any `Module` cited in `docs/subsystems`/`docs/reference`
> stops resolving — keeping these docs from silently rotting.

> Not indexed above (historical / evaluation notes, kept for context):
> `dogfood_phase_2.md`, `odysseus_evaluation.md`.
