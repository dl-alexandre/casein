# Doc ↔ code coverage map

> Companion to [`README.md`](README.md) and [`architecture.md`](architecture.md).
> Maps every `lib/` subsystem directory to its owning doc, then aggregates the
> divergences each documenting pass reported. Per the **docs-win** ethos, the
> divergences below are open items against the *code* — the docs are the
> contract; the code is what needs to change to match.

## Directory → owning doc

Each `lib/` subsystem directory and its authoritative doc. The "Cross-link"
column names the pre-existing doc the subsystem doc threads back into.

### `lib/dev_ide/*` (the DevIDE app)

| Directory | Owning doc | Cross-link |
|-----------|------------|------------|
| `lib/dev_ide/terminals/` | [`subsystems/terminals.md`](subsystems/terminals.md) | `terminal.md` |
| `lib/dev_ide/agents/` | [`subsystems/agents.md`](subsystems/agents.md) | `terminal_mcp.md` |
| `lib/dev_ide/artifact_projects/` (+ `lib/dev_ide/artifact_projects.ex`) | [`subsystems/artifact_projects.md`](subsystems/artifact_projects.md) | `subsystems/runtimes.md` / `preview_mcp.md` |
| `lib/dev_ide/previews/` | [`subsystems/previews.md`](subsystems/previews.md) | `preview_mcp.md` |
| `lib/dev_ide/preview_control/` | [`subsystems/previews.md`](subsystems/previews.md) + [`subsystems/preview_ctl.md`](subsystems/preview_ctl.md) | `preview_mcp.md` |
| `lib/dev_ide/runtimes/` | [`subsystems/runtimes.md`](subsystems/runtimes.md) | — |
| `lib/dev_ide/workspaces/` | [`subsystems/workspaces.md`](subsystems/workspaces.md) | `state_machines.md` |
| `lib/dev_ide/workspace_source/` | [`subsystems/workspaces.md`](subsystems/workspaces.md) | `workspace_sources.md` |
| `lib/dev_ide/proposals/` | [`subsystems/proposals.md`](subsystems/proposals.md) | `architecture.md` |
| `lib/dev_ide/audit/` | [`subsystems/audit_activity.md`](subsystems/audit_activity.md) | `audit_local.md` / `audit_remote.md` |
| `lib/dev_ide/runs/` | [`subsystems/audit_activity.md`](subsystems/audit_activity.md) | `audit_local.md` |
| `lib/dev_ide/logs/` | [`subsystems/audit_activity.md`](subsystems/audit_activity.md) | `audit_local.md` |
| `lib/dev_ide/files/` | [`subsystems/code_intelligence.md`](subsystems/code_intelligence.md) | `architecture.md` |
| `lib/dev_ide/search/` | [`subsystems/code_intelligence.md`](subsystems/code_intelligence.md) | `architecture.md` |
| `lib/dev_ide/git/` | [`subsystems/code_intelligence.md`](subsystems/code_intelligence.md) | `architecture.md` |
| `lib/dev_ide/elixir/` | [`subsystems/code_intelligence.md`](subsystems/code_intelligence.md) | `architecture.md` |
| `lib/dev_ide/palette/` | [`subsystems/palette_commands.md`](subsystems/palette_commands.md) | `leader_keys.md` |
| `lib/dev_ide/commands/` | [`subsystems/palette_commands.md`](subsystems/palette_commands.md) + [`reference/cli_and_keys.md`](reference/cli_and_keys.md) | `leader_keys.md` |
| `lib/dev_ide/labels/` | [`subsystems/palette_commands.md`](subsystems/palette_commands.md) | `leader_keys.md` |
| `lib/dev_ide/annotations/` | [`subsystems/palette_commands.md`](subsystems/palette_commands.md) | `leader_keys.md` |
| `lib/dev_ide/policy/` | [`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md) | `deploy.md` |
| `lib/dev_ide/deployment/` | [`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md) | `deploy.md` |
| `lib/dev_ide/export/` | [`subsystems/policy_deploy_export.md`](subsystems/policy_deploy_export.md) | `deploy.md` |
| `lib/dev_ide/cli/` | [`reference/cli_and_keys.md`](reference/cli_and_keys.md) | `leader_keys.md` |
| `lib/dev_ide/integrations/` | [`integrations/manager.md`](integrations/manager.md) | `deploy.md` |

### `lib/*` (in-repo libraries) and the `dev_ide_web` tier

| Directory | Owning doc | Cross-link |
|-----------|------------|------------|
| `lib/dev_ide_web/` | [`subsystems/web_cockpit.md`](subsystems/web_cockpit.md) + [`reference/http_api.md`](reference/http_api.md) | `architecture.md` |
| `lib/tmux_ctl/` | [`subsystems/tmux_terminal_ctl.md`](subsystems/tmux_terminal_ctl.md) | `tmux_control_plane.md` |
| `lib/terminal_ctl/` | [`subsystems/tmux_terminal_ctl.md`](subsystems/tmux_terminal_ctl.md) | `tmux_control_plane.md` |
| `lib/preview_ctl/` | [`subsystems/preview_ctl.md`](subsystems/preview_ctl.md) | `preview_mcp.md` |
| `lib/mix/tasks/` | [`reference/cli_and_keys.md`](reference/cli_and_keys.md) | `leader_keys.md` |

### `dev_ide_core/lib/*` (path-dependency package)

These generic, dependency-free BEAM primitives back DevIDE-app facades and are
now owned by [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md).

| Directory | Owning doc | Cross-link |
|-----------|------------|------------|
| `dev_ide_core/lib/exec_ctl/` | [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md) | `subsystems/palette_commands.md` / `reference/cli_and_keys.md` (allowlist source-of-truth) |
| `dev_ide_core/lib/git_ctl/` | [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md) | `subsystems/code_intelligence.md` (inspector/cache backing) |
| `dev_ide_core/lib/mcp_ctl/` | [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md) | `reference/mcp_tools.md` (JSON-RPC primitives) |

## Subsystems with NO owning doc

> ✅ None. Every `lib/`, `lib/dev_ide_web/`, in-repo `lib/*` library, and
> `dev_ide_core/lib/` subsystem now maps to an owning doc in the tables above.
> The last gaps closed in the follow-up pass:
>
> - **`dev_ide_core/lib/{exec_ctl,git_ctl,mcp_ctl}/`** — now owned by
>   [`subsystems/dev_ide_core.md`](subsystems/dev_ide_core.md). `ExecCtl.Allowlist`
>   is the authoritative command id→argv map that `DevIDE.Commands.Allowlist`
>   (and thus `DevIDE.Policy`) delegates into.
> - **`lib/dev_ide/integrations/manager/`** — owned by
>   [`integrations/manager.md`](integrations/manager.md) (see the `lib/dev_ide/*`
>   table). It was only ever a mapping gap, not a missing doc.

## Gaps & divergences

Aggregated from every documenting pass, grouped by kind. Each is an open item
against the **code** (docs win).

### `doc-stale` — doc describes a no-longer-true behaviour

1. **terminals** — `docs/terminal.md` ("Current state" / "Ghostty raw renderer")
   describes the prod raw path as `PaneWorker` driving a dedicated
   `Ghostty.PTY` (forkpty) per pane with `tmux new-session -A`, never
   mentioning `SessionOwner`/`Attachment`. In code, `PaneWorker` defaults to
   backend `:session_owner` (`pane_worker.ex:113`), routing raw joins **and**
   LiveView panes through `DevIDE.Terminals.SessionOwner → Attachment →
   Session` (one shared tmux-backed `Session` per `{workspace,sid}`).
   `:ghostty_pty` and `:shared_session` are retained only for tests/rollback.
2. **terminals** — `docs/terminal.md` ("Multi-tab behaviour") says resize shrinks
   the shared session to the **smallest** attached viewport and to "accept this;
   it's tmux behaviour." The server core now overrides this:
   `SessionOwner.authoritative_size/1` sizes the PTY to the **most-recently-active
   (focused)** viewer, falling back to the **largest** area — explicitly not
   smallest. (Matches MEMORY "Terminal multi-viewer resize corruption".)
3. **terminals** — `docs/terminal.md`'s snapshot-wiring narrative
   (`@ghostty_term_id`, `start_ghostty_terminal/1`, `cleanup_ghostty_resources/1`
   in `show.ex`) describes the `:ghostty_pty` render path, now the non-default
   backend; under `:session_owner` the snapshot/render wiring differs. Flagged
   as potentially-stale rather than confirmed dead.
4. **audit-activity** — `DevIDE.Audit` and `DevIDE.Audit.MemoryAdapter`
   `@moduledoc`s still describe the Ecto adapter as future ("M11", "Swap with an
   Ecto-backed adapter in M11"). The `EctoAdapter` is fully implemented and is
   the prod default per `audit_remote.md`. (`audit.ex:2-8`,
   `memory_adapter.ex:1-4`.)
5. **audit-activity** — `DevIDE.Audit.Event` `@moduledoc` references "the M11
   Ecto migration" as future; that migration / `audit_events` table and the
   mapping already exist. (`event.ex:2-5`.)
6. **web** — `show.ex:164` carries an inline comment "NOTE: in-flight refactor
   adds `ChannelAuth.sign_terminal_capability/3`", but that function already
   exists (`channel_auth.ex:59`) and is already called (`show.ex:1812`). Stale
   note; drop it.
7. **ref-mcp** — `docs/preview_mcp.md` (lines 148-149) treats `tidewave` as a
   preview surface/origin alongside `app`/`api`, but DevIDE does not implement,
   proxy, or serve any Tidewave MCP tools; `TidewaveMCP`/`TidewaveCapability`
   only resolve a URL to the external dev-only `:tidewave` dep (compiled only in
   `MIX_ENV=dev`). New reference documents the distinction; `preview_mcp.md`
   unchanged.
8. **tmux-ctl** — `docs/tmux_control_plane.md:185` lists
   `workspace_root_unavailable` and `outside_root` among common errors, but
   those are emitted by the DevIDE/API facade (template/cwd validation), not by
   any `TmuxCtl.Client` function. Expected (the doc spans the product layer);
   noted because those atoms are not code-derivable from `lib/tmux_ctl/`.
9. **ref-cli** — `docs/leader_keys.md` "Adopting" tables omit the `C` /
   `new-window-tab` binding present in `LEADER_ACTIONS`
   (`workspace_leader.js`). Code has Shift-C; doc is silent.

### `doc-references-dead-code` — doc points at code that is inert/unreachable

1. **terminals** — `docs/terminal.md` "Ghostty raw renderer" references
   `ghostty_snapshot.ex` disk writes wired from `show.ex`. The file still exists
   and matches, but the snapshot wiring it narrates describes the now-non-default
   `:ghostty_pty` path. Flagged potentially-stale, not confirmed dead.
2. **policy-deploy-export** — `docs/architecture.md` Authority-map row "Read
   workspace status" / Export pipeline vs
   `export/workspace_status.ex:248,324`: `active_run_summary/1` always returns
   `nil` and `run_artifacts/1` always returns `[]` (retired with the
   delegated-execution/batch-command stack). The export payload still emits an
   empty `artifacts: []` and a `nil` active_run — permanently inert fields.
3. **dev_ide_core** — `ExecCtl.Port` (`dev_ide_core/lib/exec_ctl/port.ex`) has
   **no production caller**: the only callers are `test/exec_ctl/port_test.exs`
   and the unused `DevIdeCore.exec_run/3` facade. The app's real subprocess
   executor, `DevIDE.Commands.spawn/3` (`lib/dev_ide/commands.ex`), reimplements
   the same erlexec-proxy-and-monitor plumbing inline rather than delegating to
   `ExecCtl.Port`. Parallel/duplicated logic; candidate for consolidation.
4. **dev_ide_core** — the `DevIdeCore` convenience facade
   (`git_inspect/1`, `exec_run/3`, `mcp_tool/3`) is unused in `lib/`; callers
   reach `GitCtl.Inspector` / `McpCtl.Tool` directly. Self-described "thin
   documentation/convenience facade", not on any app call path.

### `code-undocumented-area` — code behaviour with no doc home (until this pass)

1. **runtimes** — `runtimes.ex:list_agent_worktrees/1` filters out a `"failed"`
   status, but `StateMachine.statuses/0` defines only
   requested/provisioned/expired/cleaned and no transition produces `"failed"`.
   The `"failed"` branch (and `Runtime.failure_reason`) is dead/unreachable
   under the current state machine.
2. **runtimes** — `Profile` `@builtins` carry an executable-looking `command`
   (`mix phx.server`, `npm run dev`) yet the subsystem is record-only with no
   execution authority. The command is intent-metadata for a not-yet-existing
   provisioner; nothing consumes or runs it.
3. **audit-activity** — `DevIDE.Runs.Status` carries first-class semantics for
   legacy delegated-execution statuses (`expired` = "runner lease expired",
   `abandoned`, and `assignment_id`/`protocol`/`safe_action_id` fields surfaced
   by `Runs.Ledger.run_summary`). `architecture.md` says that stack "has been
   removed", yet these strings/keys remain live for backward-compatible
   timelines with no doc explaining the retention.
   (`status.ex:12-16,98-105`; `ledger.ex:226-231`.)
4. **code-intel** — the public facades callers actually invoke (`DevIDE.Files`,
   `DevIDE.Search`, `DevIDE.Git`, `DevIDE.Elixir`) and the dispatch wrapper
   `DevIDE.Workspaces.FileAccess` live one directory *up* from the
   implementation modules. They have moduledocs but no subsystem-level home
   until now.
5. **code-intel** — `DevIDE.Git.Inspector` delegates worktree/checkout detection
   and ETS caching to `GitCtl.Inspector` / `GitCtl.Cache` in the
   `dev_ide_core` umbrella sibling — the git-inspection behavior is split across
   two apps; the GitCtl side is unowned.
6. **palette-commands** — the palette's true runtime entry point is
   `DevIdeWeb.WorkspaceLive.Show.PaletteItems`
   (`palette_items.ex:46-140`), which merges static `DevIDE.Palette.query`
   results with dynamically-generated session/window/pane/template/workflow
   rows. Those dynamic rows (`resolve/3`) bypass `Actions.allowed_events/0`
   entirely — guarded only by re-checking current socket state. The two-layer
   (static facade + live orchestrator) structure and the dynamic-id guard path
   were undocumented.
7. **palette-commands** — `DevIDE.Commands.Allowlist` is a thin `defdelegate` to
   `ExecCtl.Allowlist` (`dev_ide_core`); the real id→argv map lives there.
   (`commands/allowlist.ex:10-13`.)
8. **palette-commands** — `Annotation.preview_id` is intentionally a nullable
   `:binary_id` and **not** a foreign key because the preview persistence model
   has not landed; `attach_to_preview/2` sets it but nothing enforces
   referential integrity. (`annotations/annotation.ex:30`.) Known incomplete
   area, not a mismatch.
9. **policy-deploy-export** — `DevIDE.Export.Sanitizer.redact_text/1`
   (`sanitizer.ex:34-49`) is public, `@doc`'d and `@spec`'d but has **zero
   callers** anywhere in `lib/`. Dead/orphan despite presenting as part of the
   egress-redaction API.
10. **policy-deploy-export** — `docs/deploy.md` documents the Docker/compose
    path and defers the systemd path to `integrations/manager.md`, but does not
    describe the on-box deploy machinery this code implements (heartbeat
    `Registry`, `/run/devide/current.sock` symlink, graceful `Drain` via POST
    `/api/drain`, `Drift` vs `origin/master`, `/api/deploy_status` `Health`
    probe). The new companion doc covers these; `deploy.md` intentionally
    unmodified.
11. **web** — `show.ex` is a 5,496-line LiveView (now `@moduledoc`-added) holding
    the entire cockpit's socket state and orchestration; most
    handle_event/handle_info clauses remain inline rather than in `Show.*`
    submodules. No doc enumerates which event families are inline (`workspace:*`,
    `pane:*`, `split_*`, `preview-pane:*`, `audit_drawer:*`, `search:*`,
    `ghostty:snapshot`) versus delegated.
12. **web** — `PaneWorker` backend selection (`:session_owner` default, with
    `:shared_session` and legacy `:ghostty_pty` for tests/rollback) is
    undocumented at the architecture level; the per-pane worker draining model
    and the backend-swap escape hatch have no architecture-doc home.
13. **web** — `TerminalChannel` keeps an ETS fast-path cache
    (`:dev_ide_terminal_fast_path_cache`, 60s TTL) to skip workspace-manager
    access checks on reconnect storms. This per-socket capability-token bypass of
    manager re-checks is not described in `architecture.md` Boundary 2.
14. **tmux-ctl** — `adapter.ex:25` `@callback directory_inventory/0` is typed
    `… | {:error, term()}`, but the impl `TmuxCtl.Client.directory_inventory/0`
    returns `… | :error` (bare atom). The client's own `@spec` is correct; the
    behaviour callback contract is the one that is wrong. Spec/impl mismatch
    within the subsystem.
15. **ref-mcp** — `GET /api/{terminals,preview}/mcp` (the `:info` action) returns
    HTTP 405 `method_not_allowed` (POST/JSON-RPC only, no SSE). Neither
    `terminal_mcp.md` nor `preview_mcp.md` mentioned the GET behaviour; the new
    reference records it. (`preview_mcp_controller.ex:34-37`,
    `router.ex:157,162`.)
16. **ref-http** — `architecture.md`'s Authority map / route narrative does not
    enumerate the deploy-control HTTP surface (`GET /api/deploy_status`, `POST
    /api/drain`). Documented in `policy_deploy_export.md` but not findable from
    the top-level architecture doc.
17. **ref-http** — the `/preview-proxy/:workspace_id/:port/*path` reverse proxy
    and its dedicated `:preview_proxy` pipeline (CSP-omitting, ForwardAuth-gated)
    are not in `architecture.md`'s trust-boundary or subsystem map; only the
    controller's own moduledoc described it until the new `http_api.md`.
18. **ref-cli** — `docs/leader_keys.md` "Bigger lifts (planned)" list is
    mis-numbered (1, 2, 4 — no item 3). Cosmetic; not a behavioral divergence.

## `@moduledoc` additions

Files that gained a `@moduledoc` during this documenting pass.

| File | Pass |
|------|------|
| `lib/dev_ide/agents/mcp_urls.ex` | agents-mcp |
| `lib/dev_ide/agents/pane_env.ex` | agents-mcp |
| `lib/dev_ide/agents/mcp_materializer.ex` | agents-mcp |
| `lib/dev_ide/previews/preview.ex` | previews |
| `lib/dev_ide/previews/control_session.ex` | previews |
| `lib/dev_ide/previews/control_action.ex` | previews |
| `lib/dev_ide/previews/control_observation.ex` | previews |
| `lib/preview_ctl/registry.ex` | preview-ctl |
| `lib/preview_ctl/playwright/bridge.ex` | preview-ctl |
| `lib/dev_ide_web/live/workspace_live/show.ex` | web |
| `lib/dev_ide_web/router.ex` | ref-http |
| `lib/dev_ide_web/controllers/page_controller.ex` | ref-http |
| `lib/dev_ide_web/controllers/preview_artifact_controller.ex` | ref-http |
| `lib/dev_ide_web/channels/user_socket.ex` | ref-http |

Subsystems whose passes added **no** moduledocs (docs-only, code untouched):
terminals, runtimes, workspaces, proposals, audit-activity, code-intel,
palette-commands, policy-deploy-export, tmux-ctl, ref-mcp, ref-cli.

## Verification

After generation, every module/file identifier cited in `docs/subsystems/*` and
`docs/reference/*` was checked against real `defmodule`s (in `lib/`,
`dev_ide_core/`, and `test/support/`) plus registered process/Registry names.
**Result: all cited modules resolve.** No fabricated module citations were found.

> ✅ **Preview-control / tmux-adapter dead-code removal — landed.** The refactor
> that was in flight during the documenting pass committed as
> `0737aa0 "Remove dead preview/tmux adapters; wire TmuxServer test sandbox"`
> (on the `chore/self-hosted-deploy-poller` deploy branch; not yet on `master`).
> It deleted `lib/dev_ide/preview_control/{adapter,memory_adapter,playwright_adapter,playwright_bridge}.ex`,
> `lib/dev_ide/terminals/tmux_adapter.ex`, and `lib/mix/tasks/dev_ide.preview.demo.ex`.
> These docs have been updated to match: the `DevIDE.PreviewControl.*Adapter` /
> `PlaywrightBridge` rows and the `DevIDE.Terminals.TmuxAdapter` row are dropped;
> `DevIDE.PreviewControl` now drives `PreviewCtl.*` directly via
> `PreviewCtl.Session.adapter_for/1`, and `DevIDE.PreviewControl.Registry` (which
> survives) still `defdelegate`s to `PreviewCtl.Registry`.

### Function-level verification (839 claims)

A second adversarial pass put one agent per doc to work trying to **refute**
every checkable claim — function names/arities, `file:line` citations, and
behavioural assertions — against frozen `HEAD`. Of ~839 claims, **12 were false
and have been corrected**, including:

- `previews.md` — the preview-proxy iframe path is `/preview-proxy/:workspace_id/:port/*path` (the `/preview-proxy` scope prefix was missing).
- `audit_activity.md` — `EctoAdapter` is the default for **every** env (`config.exs`); only `config/test.exs` overrides to `MemoryAdapter` (was wrongly "dev/test default MemoryAdapter"). Also: `Export.WorkspaceStatus` does **not** call `Runs.Status.*`.
- `tmux_terminal_ctl.md` — the "user field placed last" format-string invariant holds only for the directory/janitor formats; `@topology_window_fmt` puts `window_name` mid-string and relies on `parts:`-capped splitting.
- `proposals.md` — the public consumer is `Export.WorkspaceStatus.proposals/1` (delegating to the private `recent_proposals/2`).
- `workspaces.md`, `dev_ide_core.md`, `cli_and_keys.md` — assorted exact-set / type / error-string corrections.

The doc-citation guard (`scripts/check-doc-citations.sh`, wired into the
pre-push gate) now blocks any push that orphans a module reference in these docs.

> Residual scope note: `file:line` numbers cited inline were checked where an
> agent flagged them, but line numbers drift with edits — treat them as hints,
> not contracts.
