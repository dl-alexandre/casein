# LiveView terminal hot-path diff payload measure (#899)

**Status:** instrumentation only. No optimisation in this change.

## Why this exists

Week-22 research checkpoint found:

| Signal | Value |
|--------|------:|
| `workspace_live/show.ex` lines / `assign(` calls | 4 320 / 272 |
| `temporary_assigns` across `lib/casein_web` | **0** |
| LiveView modules under `lib/casein_web` | 76 |
| `{assigns}` spreads on mobile hot path | 2 (`terminal_panel.ex` → `mobile_key_bar` / `mobile_nav_sheet`) |

Zero `temporary_assigns` is a **finding**, not a mandate. Prior art in this
codebase: “add `:__changed__` to `Map.take`” does **not** restore tracking when
the template already depends on the full assigns map — LV disables change
tracking for assigns-dependent dynamic parts. Only explicit attrs help.

So we measure wire + dirty-assign bytes first; a follow-up issue uses the
numbers as justification (or refutation) for any `temporary_assigns` / stream
work.

## What is instrumented

| Probe | Module | Telemetry |
|-------|--------|-----------|
| **Wire** (browser-bound iodata) | `CaseinWeb.LiveDiffMeasure.Serializer` on `/live` | `[:casein, :live_view, :diff_wire]` → `payload_bytes`, tags `kind` (`diff_push` \| `reply_diff`), `event` |
| **Changed assigns** (server term size) | `:after_render` on `WorkspaceLive.Show` | `[:casein, :live_view, :changed_assigns]` → `payload_bytes`, `changed_count`; metadata `top` / `top_keys` ranked worst-first |

Gate: `config :casein, live_diff_measure: true|false` or env
`CASEIN_LIVE_DIFF_MEASURE=0` to disable. Default on.

## How to collect a ranked report on a live box

```bash
# LiveDashboard / telemetry_poller already lists the summaries.
# Or attach a one-shot handler in remote_console:

handler = fn
  [:casein, :live_view, :diff_wire], %{payload_bytes: b}, %{kind: k}, acc ->
    update_in(acc, [:wire, k], fn v -> [b | v || []] end)
  [:casein, :live_view, :changed_assigns], %{payload_bytes: b}, %{top_keys: keys}, acc ->
    acc
    |> update_in([:assigns_total], fn v -> [b | v || []] end)
    |> update_in([:top_keys], fn v -> (keys || []) ++ (v || []) end)
  _, _, _, acc ->
    acc
end

:telemetry.attach_many(
  "lv-diff-sample",
  [[:casein, :live_view, :diff_wire], [:casein, :live_view, :changed_assigns]],
  handler,
  %{}
)

# Drive the cockpit (pane focus, window switch, mobile nav, tmux topology
# tick) for ~60s, then:

# :telemetry.list_handlers(...) or hold acc in an Agent — rank max/p50/p95.
```

### Suspected worst offenders (pre-measure hypothesis — not yet ranked by wire)

These are the keys the after_render probe is expected to surface first when the
terminal hot path ticks; **replace this table with live p95 once sampled**:

| Rank (hyp) | Assign / path | Why it is on the hot path |
|-----------:|---------------|---------------------------|
| 1 | `pane_data` | Per-pane Ghostty/frame state; updates with every worker flush path that also dirties LV assigns |
| 2 | `tmux_window_tabs` / `session_tabs` | Session bar + fleet chrome; rebuilt on topology |
| 3 | `tmux_windows` | Full window list for geometry |
| 4 | `{assigns}` → `mobile_key_bar` / `mobile_nav_sheet` | Spreads disable tracking for the mobile chrome subtree |
| 5 | `preview_panes` / `feature_panes` | Overlay lists co-rendered with terminal |
| 6 | `fleet_board` | Fleet drawer projection |

Wire kinds to compare:

* `diff_push` — unsolicited LV diffs (handle_info / topology)
* `reply_diff` — diffs attached to event replies (clicks, keybar)

## Explicitly out of scope here

* Adding `temporary_assigns` or converting assigns → streams
* “Fixing” change tracking via `__changed__` in `Map.take`
* Changing `terminal_panel.ex` attr surface (measurement may *justify* that later)
* Ghostty `push_event` frame bytes (already under `casein.terminal.live_view.push_frame`)

## Follow-up

Open a perf issue titled from the **measured** top offender (e.g. “cap
`pane_data` diff p95 180 KB on topology tick”) and link this doc + a sample
window. Do not start that work in the same PR as the probes.
