# Palette & Commands

> Turn a typed query into a ranked list of **allowlisted** actions and dispatch the selected one through an existing gated LiveView event — never a free-form command.

## Responsibility

The palette is the keyboard-first command surface (opened with `C-b :`, see
[`../leader_keys.md`](../leader_keys.md)). It fuses two static, code-derived
allowlists — workspace files and a fixed action/command set — with a cheap
fuzzy scorer, then resolves the chosen row back to a vetted payload. The hard
invariant: **the palette never synthesises a mutation.** Every result routes to
a LiveView event the `Show` LiveView already handles and gates; the palette
only ranks and routes.

Two adjacent subsystems live in the same documentation neighbourhood because
the palette's file rows open them:

- **Labels** — ephemeral, conversation-aware pane labels derived from MCP /
  agent activity. Pure chrome; they never mutate tmux titles.
- **Annotations** — durable, storage-first human/agent notes pinned to
  terminal / file / preview context. The palette's file rows dispatch
  `annotation:open`.

## Module map

| Module | File | Role |
|---|---|---|
| `Casein.CommandPalette` | `lib/casein/command_palette.ex` *(facade, outside assigned dir)* | Public facade: `query/3` ranks file+action items; `resolve/2` maps a wire id back to an allowlisted payload (file ids re-validated via `PathSafety.resolve/2`). |
| `Casein.CommandPalette.FileIndex` | `lib/casein/command_palette/file_index.ex` | Workspace-rooted file walker. Capped at `@file_cap` 5_000, honours `PathSafety.ignored_dir?/1` / `ignored_path?/1`, never follows symlinks; surfaces only `.formatter`/`.github` dotdirs. |
| `Casein.CommandPalette.Fuzzy` | `lib/casein/command_palette/fuzzy.ex` | Tiered scorer: exact → prefix → substring → scattered/acronym → `nil`. Shorter targets get `length_bonus/1`; empty query returns base score `1`. |
| `Casein.CommandPalette.Item` | `lib/casein/command_palette/item.ex` | Result-row struct (`id`/`kind`/`label`/`detail`/`score`/`category`/`payload`). `category/1` honours an explicit `:category` else derives from `kind`. |
| `Casein.CommandPalette.Actions` | `lib/casein/command_palette/actions.ex` | The fixed action/command/tab/tmux/theme/agents/preview allowlist (`all/0`) and the dispatch guard `allowed_events/0`. |
| `Casein.Commands.Allowlist` | `lib/casein/commands/allowlist.ex` | Thin delegate to `ExecCtl.Allowlist` (id → argv, in `casein_core`). Lets read-only callers enumerate command ids without the execution graph. |
| `Casein.Labels` | `lib/casein/labels.ex` *(GenServer, outside assigned dir)* | Keyed `{tmux_session, pane_id}` label store; debounced, size-capped, PubSub-broadcast on `pane_labels:<workspace_id>`. |
| `Casein.Labels.Derivation` | `lib/casein/labels/derivation.ex` | Pure label derivation from MCP tool args / agent input; truncates to `@max_label_length` 48. |
| `Casein.Annotations` | `lib/casein/annotations.ex` *(context, outside assigned dir)* | CRUD + approval lifecycle for annotations; audits each write and broadcasts on `workspace:<id>`. |
| `Casein.Annotations.Annotation` | `lib/casein/annotations/annotation.ex` | Ecto schema + changeset; `validate_context_present/1` requires at least one of terminal/file/preview/linked context. |
| `CaseinWeb.WorkspaceLive.Show.PaletteItems` | `lib/casein_web/live/workspace_live/show/palette_items.ex` *(web tier)* | Per-request orchestrator: merges static `Palette.query` results with live socket-derived rows (sessions, windows, panes, templates, workflows, shell) and re-`resolve`s dynamic ids. |

## Data flow / lifecycle

**Query (open palette → ranked rows).** `PaletteItems.query/2` is the live
entry point. It:

1. Reads the workspace root (`host_path`) and the selected category tab
   (`palette_category`, one of `:all :files :commands :tmux :agents :preview
   :actions`).
2. Calls `Palette.query(root, q, category: ...)` for the **static** half —
   `FileIndex.list/1` files (skipped entirely for non-file categories) +
   `Actions.all/0`, each scored by `Fuzzy.score/2`, filtered by category,
   sorted by score, capped at 50.
3. Appends **dynamic** rows built from socket assigns — workflows, the
   workspace-shell row, session/window switch rows, session templates, and
   pane-focus rows — each independently `Fuzzy.score`d and score-boosted
   (active session +2_000, shell +1_800, active window +1_500, focused pane
   +1_200, etc.).
  4. Re-sorts the merged list by score and takes the top 50
     (`PaletteItems.max_results/0`). The pre-cap total is exposed via
     `query_with_meta/2` so the panel can show an honest `"N of M"` when the
     cap bites — fuzzy search is least trustworthy exactly when it is
     working hardest. Frecency-promoted row ids ride in the same meta as
     `frequent_ids` (presentation only; ranking is unchanged).

`relabel_terminal_mode_items/2` rewrites the `action:terminal:raw` row to name
the active window; `filter_static_tmux/3` hides multi-pane verbs when only one
pane exists.

**Resolve (select row → dispatched event).** On `palette:execute`,
`PaletteItems.resolve/3` pattern-matches the chosen id prefix. Dynamic ids
(`session:switch:`, `session:window:`, `window:switch:`, `pane:focus:`,
`template:preview:`/`apply:`, `workflow:run:`/`hint:`) are re-validated against
current socket state and emit their own params. Everything else falls through
to `Palette.resolve/2`, which: for `file:<rel>` re-runs
`PathSafety.resolve/2` against root before returning `annotation:open`; for
action ids looks up `Actions.all/0` and only returns the payload if its
`event` is in `Actions.allowed_events/0`. The resolved `%{event, params}` is
then dispatched as the named LiveView event.

**Labels.** Agent/MCP activity → `Labels.propose_from_mcp/4` or
`set_agent_label/5` → `Derivation` shortens the text → a debounced GenServer
`:propose` cast updates the `{tmux_session, pane_id}` entry and broadcasts
`{:pane_label_updated, ...}`. `mark_quiet`/`clear_quiet` append/strip the
` · quiet` suffix; `frozen?` entries (manual labels) are never overwritten.

**Annotations.** `Annotations.create/2` (or `propose_from_agent/2`, which
defaults `approval_state: :pending`) casts through `Annotation.changeset/2`,
inserts, emits an `Audit` event, and broadcasts `{:annotation_created, ...}` on
`workspace:<id>`. `approve/2` / `reject/2` / `attach_to_preview/2` follow the
same audit+broadcast path.

## Public surface

- `Casein.CommandPalette.query/3`, `Casein.CommandPalette.resolve/2` — static facade.
- `Casein.CommandPalette.Actions.all/0`, `allowed_events/0` — action set + dispatch guard.
- `Casein.CommandPalette.Fuzzy.score/2` — reused directly by `PaletteItems` for dynamic rows.
- `Casein.CommandPalette.FileIndex.list/1`, `cap/0`.
- `Casein.CommandPalette.Item.category/1`.
- `Casein.Commands.Allowlist.all/0`, `allowed?/1`, `argv_for/1` (delegating to `ExecCtl.Allowlist`).
- `Casein.Labels` GenServer: `propose_from_mcp/4`, `set_agent_label/5`, `mark_quiet/3`, `clear_quiet/3`, `prune_session/2`, `get/2`, `for_session/1`, `subscribe/1`.
- `Casein.Labels.Derivation.from_mcp/3`, `from_agent_label/1`.
- `Casein.Annotations`: `create/2`, `propose_from_agent/2`, `list_for_workspace/2`, `get/1`, `get!/1`, `approve/2`, `reject/2`, `attach_to_preview/2`, `subscribe/1`.

## Invariants & gotchas

- **No free-form mutation.** The palette never sends raw keystrokes to a pane
  and never invents an event. Static action payloads must name an event in
  `Actions.allowed_events/0`; file rows are re-validated through
  `PathSafety.resolve/2` at resolve time, not just at index time.
- **Dynamic ids bypass `allowed_events/0`.** `PaletteItems.resolve/3` handles
  session/window/pane/template/workflow ids itself and re-checks them against
  *current* socket state (`find_session_tab`, `window_known?`, pane membership,
  `tmux_mutations_allowed?`, `Workflows.palette_runnable?`). That re-check is
  the guard for those rows — `allowed_events/0` only covers the static set.
- **FileIndex is hard-capped at 5_000 files** and short-circuits on
  `PathSafety.ignored_dir?/1`; dotdirs other than `.formatter`/`.github` are
  pruned. Large repos silently truncate.
- **`Fuzzy.score/2` returns `nil` for no-match** (the caller drops the row);
  empty query returns `1` so callers fall back to alphabetical/boost ordering.
- **Labels are chrome, not state.** They live only in the GenServer map (cap
  `@max_entries` 500, debounce `@debounce_ms` 30s) and broadcast; they never
  touch tmux window/pane titles. `frozen?` (manual) labels win over MCP-derived
  updates. This is distinct from the activity/quiet-agent dots documented in
  [`../leader_keys.md`](../leader_keys.md), which ride tmux metadata.
- **Annotations require context.** `validate_context_present/1` rejects an
  annotation that references none of terminal_range/file_path/file_range/
  preview_id/linked_entities. `preview_id` is deliberately a nullable
  `:binary_id`, not an FK — the preview persistence model has not landed.
- **`annotation:open` is the file-open verb.** Selecting a `file:` palette row
  dispatches `annotation:open` (the `Show` LiveView opens the file for
  annotation), which is why that event appears in `allowed_events/0`.

## See also

- [`../leader_keys.md`](../leader_keys.md) — `C-b :` opens the palette; tmux-style leader bindings and pickers.
- [`../architecture.md`](../architecture.md) — first principles (FP-1/FP-3) and the "no arbitrary argv" design invariant the palette honours.
- [`../terminal_mcp.md`](../terminal_mcp.md) — MCP tools whose activity drives `Labels` and `Annotations`.
