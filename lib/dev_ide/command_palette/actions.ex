defmodule DevIDE.CommandPalette.Actions do
  @moduledoc """
  Fixed allowlist of command palette actions.

  Each action carries a payload that names an existing LiveView event the
  Show LiveView already handles (`switch_tab`, `run:start`, `tree:refresh`,
  `isolation:refresh`, `terminal:set_mode`,
  `terminal:toggle_chrome`, fixed tmux verbs such as
  `tmux:consolidate_sessions`, and the structural pane verbs `split_right`,
  `split_down`, `equalize_layout`, `pane:close_focused`,
  `pane:close_others`, `pane:cycle_layout`, `pane:focus_next`,
  `pane:focus_previous`, and `pane:zoom_focused`). Preview items are not
  static — `PaletteItems.preview_surface_items/3` derives them per workspace
  from `DevIDE.Previews.surfaces/1`; `preview:open` stays in
  `allowed_events/0` for that path. The palette never
  invents new mutation events; it only routes to gated existing ones, and it
  never sends arbitrary keystrokes to a pane.
  """

  alias DevIDE.Commands.Allowlist
  alias DevIDE.CommandPalette.Item
  alias DevIDE.Terminals.Theme

  @tabs ~w(terminal files search diff artifacts run proposals logs history)

  @spec all() :: [Item.t()]
  def all do
    tab_items() ++
      command_items() ++
      tmux_items() ++
      theme_items() ++ agents_items() ++ refresh_items() ++ view_items()
  end

  defp tab_items do
    Enum.map(@tabs, fn tab ->
      %Item{
        id: "tab:" <> tab,
        kind: :tab,
        category: :view,
        label: "Open tab: " <> tab,
        detail: "switch to " <> tab,
        payload: %{event: "switch_tab", params: %{"tab" => tab}}
      }
    end)
  end

  # UI presentation toggles, grouped under the palette's View tab. Each one
  # routes to an existing gated LiveView event that only changes how the
  # workspace is rendered — never what it can mutate.
  defp view_items do
    [
      %Item{
        id: "view:window_sidebar",
        kind: :action,
        category: :view,
        label: "Open window sidebar",
        detail: "Transient vertical window rail beside the terminal (desktop)",
        payload: %{event: "sidebar:open", params: %{}}
      }
    ]
  end

  # Deliberate-failure fixture for exercising run plumbing; stays runnable via
  # the exec allowlist but has no business in a user-facing picker.
  @palette_hidden_commands ~w(dogfood.fail)

  defp command_items do
    Allowlist.all()
    |> Map.drop(@palette_hidden_commands)
    |> Enum.sort_by(fn {id, _argv} -> id end)
    |> Enum.map(fn {id, argv} ->
      %Item{
        id: "command:" <> id,
        kind: :command,
        label: "Run " <> Enum.join(argv, " "),
        detail: "policy-gated, persisted",
        payload: %{event: "run:start", params: %{"id" => id}}
      }
    end)
  end

  # Structural tmux/pane verbs. Each routes to an existing param-less LiveView
  # event that operates on the focused pane / whole layout — no arbitrary
  # keystrokes are ever sent (that would breach the "no free-form mutation"
  # invariant). Kept under the Tmux category tab. Terminal mode/chrome entries
  # keep `kind: :action` (LV-side filtering and tests key off the id) but ride
  # in an explicit `category` tab (Tmux for the raw-shell entry, View for the
  # chrome toggle).
  #
  # `hint` strings mirror the leader bindings in
  # assets/js/workspace_leader.js (LEADER_ACTIONS) — keep the two in sync.
  defp tmux_items do
    [
      %Item{
        id: "tmux:new_window",
        kind: :action,
        category: :tmux,
        label: "New tmux window",
        detail: "Create a window in the active session",
        hint: "C-b c",
        payload: %{event: "tmux:new_window", params: %{}}
      },
      %Item{
        id: "tmux:last_window",
        kind: :action,
        category: :tmux,
        label: "Last tmux window",
        detail: "Toggle back to the previous window",
        hint: "C-b l",
        payload: %{event: "tmux:last_window", params: %{}}
      },
      %Item{
        id: "tmux:consolidate_sessions",
        kind: :action,
        category: :tmux,
        label: "Consolidate session",
        detail: "Move this workspace's other sessions into the active session as windows",
        payload: %{event: "tmux:consolidate_sessions", params: %{}}
      },
      %Item{
        id: "tmux:split_right",
        kind: :action,
        category: :tmux,
        label: "Split Horizontal",
        detail: "New pane beside the focused one",
        keywords: ~w(vsplit),
        hint: "C-b %",
        payload: %{event: "split_right", params: %{}}
      },
      %Item{
        id: "tmux:split_down",
        kind: :action,
        category: :tmux,
        label: "Split Vertical",
        detail: "New pane below the focused one",
        keywords: ~w(hsplit),
        hint: "C-b \"",
        payload: %{event: "split_down", params: %{}}
      },
      %Item{
        id: "tmux:next_pane",
        kind: :action,
        category: :tmux,
        label: "Next Pane",
        detail: "Focus the next pane in layout order",
        hint: "C-b o",
        payload: %{event: "pane:focus_next", params: %{}}
      },
      %Item{
        id: "tmux:previous_pane",
        kind: :action,
        category: :tmux,
        label: "Previous Pane",
        detail: "Focus the previous pane in layout order",
        payload: %{event: "pane:focus_previous", params: %{}}
      },
      %Item{
        id: "tmux:zoom",
        kind: :action,
        category: :tmux,
        label: "Zoom / Unzoom",
        detail: "Toggle the focused pane full-size",
        keywords: ~w(maximize fullscreen),
        hint: "C-b z",
        payload: %{event: "pane:zoom_focused", params: %{}}
      },
      %Item{
        id: "tmux:cycle_layout",
        kind: :action,
        category: :tmux,
        label: "Cycle Pane Layout",
        detail: "Rotate split direction for the workspace pane tree",
        payload: %{event: "pane:cycle_layout", params: %{}}
      },
      %Item{
        id: "tmux:equalize",
        kind: :action,
        category: :tmux,
        label: "Equalize Pane Sizes",
        detail: "Reset every split to uniform ratios",
        keywords: ~w(balance),
        payload: %{event: "equalize_layout", params: %{}}
      },
      %Item{
        id: "tmux:close_pane",
        kind: :action,
        category: :tmux,
        label: "Close Pane",
        detail: "Kill the focused pane's tmux session",
        hint: "C-b x",
        payload: %{event: "pane:close_focused", params: %{}}
      },
      %Item{
        id: "tmux:close_other_panes",
        kind: :action,
        category: :tmux,
        label: "Close Other Panes",
        detail: "Keep the focused pane and close the rest",
        keywords: ~w(only),
        payload: %{event: "pane:close_others", params: %{}}
      },
      %Item{
        id: "tmux:library",
        kind: :action,
        category: :tmux,
        label: "Browse session templates",
        detail: "Open the template library (save, apply, preview)",
        keywords: ~w(layout template),
        payload: %{event: "tmux:open_template_library", params: %{}}
      },
      # Terminals are always raw; this entry (re)focuses the raw surface.
      %Item{
        id: "action:terminal:raw",
        kind: :action,
        category: :tmux,
        label: "Focus terminal",
        detail: "Focus the terminal pane (full local PTY)",
        keywords: ~w(shell pty),
        payload: %{event: "terminal:set_mode", params: %{"mode" => "raw"}}
      },
      %Item{
        id: "action:terminal:toggle_chrome",
        kind: :action,
        category: :view,
        label: "View: toggle focus mode (hide/show chrome)",
        detail: "Maximize terminal space — hides header and utility bar",
        keywords: ~w(zen fullscreen focus),
        payload: %{event: "terminal:toggle_chrome", params: %{}}
      }
    ]
  end

  defp theme_items do
    Enum.map(Theme.list_presets(), fn preset ->
      %Item{
        id: "terminal:theme:" <> preset.id,
        kind: :action,
        category: :tmux,
        label: "Terminal theme: " <> preset.label,
        detail: preset.detail,
        payload: %{event: "terminal:set_preset", params: %{"preset" => preset.id}}
      }
    end)
  end

  defp refresh_items do
    [
      %Item{
        id: "action:tree:refresh",
        kind: :action,
        label: "Refresh file tree",
        payload: %{event: "tree:refresh", params: %{}}
      },
      %Item{
        id: "action:isolation:refresh",
        kind: :action,
        label: "Refresh DB isolation",
        payload: %{event: "isolation:refresh", params: %{}}
      },
      # Ghostty grid captures — audit-logged, read-only, flash-only when no
      # live terminal is attached.
      %Item{
        id: "action:snapshot",
        kind: :action,
        label: "Snapshot focused terminal",
        detail: "Capture the focused pane's screen to a file",
        keywords: ~w(capture screenshot),
        payload: %{event: "ghostty:snapshot", params: %{}}
      },
      %Item{
        id: "action:snapshot_all",
        kind: :action,
        label: "Snapshot all terminals",
        detail: "Capture every live pane's screen to files",
        keywords: ~w(capture screenshot),
        payload: %{event: "snapshot_all", params: %{}}
      }
    ]
  end

  defp agents_items do
    [
      %Item{
        id: "agents:apply_pair",
        kind: :action,
        category: :agents,
        label: "Apply agent pair layout",
        detail: "Operator, agent, and verify panes",
        payload: %{event: "tmux:apply_template", params: %{"template-id" => "agent_pair"}}
      },
      %Item{
        id: "audit:drawer",
        kind: :action,
        category: :agents,
        label: "Open audit drawer",
        detail: "Inspect recent workspace events",
        payload: %{event: "audit_drawer:toggle", params: %{}}
      }
    ]
  end

  @doc "Allowlist of LiveView events the palette is permitted to dispatch."
  def allowed_events do
    MapSet.new([
      "switch_tab",
      "run:start",
      "tree:refresh",
      "isolation:refresh",
      "annotation:open",
      "attach_terminal_session",
      "terminal:set_mode",
      "terminal:switch_to_shell",
      "terminal:toggle_chrome",
      "terminal:set_preset",
      "sidebar:open",
      "sidebar:close",
      "tmux:new_window",
      "tmux:last_window",
      "tmux:consolidate_sessions",
      "tmux:select_window",
      "tmux:select_pane",
      "tmux:apply_template",
      "tmux:preview_template",
      "tmux:open_template_library",
      "tmux:rename_start",
      "terminal:rename_session_start",
      "ghostty:snapshot",
      "snapshot_all",
      "audit_drawer:toggle",
      "split_right",
      "split_down",
      "equalize_layout",
      "pane:close_focused",
      "pane:close_others",
      "pane:cycle_layout",
      "pane:focus_next",
      "pane:focus_previous",
      "pane:zoom_focused",
      "preview:open"
    ])
  end
end
