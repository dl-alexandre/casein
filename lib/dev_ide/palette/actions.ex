defmodule DevIDE.Palette.Actions do
  @moduledoc """
  Fixed allowlist of palette actions.

  Each action carries a payload that names an existing LiveView event the
  Show LiveView already handles (`switch_tab`, `run:start`, `tree:refresh`,
  `isolation:refresh`, `agents:refresh`, `terminal:set_mode`,
  `terminal:toggle_chrome`, and the structural pane verbs `split_right`,
  `split_down`, `equalize_layout`, `pane:close_focused`,
  `pane:close_others`, `pane:cycle_layout`, `pane:focus_next`,
  `pane:focus_previous`, and `pane:zoom_focused`). The palette never
  invents new mutation events; it only routes to gated existing ones, and it
  never sends arbitrary keystrokes to a pane.
  """

  alias DevIDE.Commands
  alias DevIDE.Palette.Item

  @tabs ~w(terminal files search diff run agents logs)

  @spec all() :: [Item.t()]
  def all do
    tab_items() ++ command_items() ++ tmux_items() ++ refresh_items()
  end

  defp tab_items do
    Enum.map(@tabs, fn tab ->
      %Item{
        id: "tab:" <> tab,
        kind: :tab,
        label: "Open tab: " <> tab,
        detail: "switch to " <> tab,
        payload: %{event: "switch_tab", params: %{"tab" => tab}}
      }
    end)
  end

  defp command_items do
    Enum.map(Map.keys(Commands.allowlist()) |> Enum.sort(), fn id ->
      %Item{
        id: "command:" <> id,
        kind: :command,
        label: "Run mix " <> id,
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
  # in the Tmux tab via the explicit `category`.
  defp tmux_items do
    [
      %Item{
        id: "tmux:find_pane",
        kind: :action,
        category: :tmux,
        label: "Find Pane",
        detail: "List and focus workspace panes",
        payload: %{event: "palette:find_pane", params: %{}}
      },
      %Item{
        id: "tmux:split_right",
        kind: :action,
        category: :tmux,
        label: "Split Horizontal",
        detail: "New pane beside the focused one",
        payload: %{event: "split_right", params: %{}}
      },
      %Item{
        id: "tmux:split_down",
        kind: :action,
        category: :tmux,
        label: "Split Vertical",
        detail: "New pane below the focused one",
        payload: %{event: "split_down", params: %{}}
      },
      %Item{
        id: "tmux:next_pane",
        kind: :action,
        category: :tmux,
        label: "Next Pane",
        detail: "Focus the next pane in layout order",
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
        payload: %{event: "equalize_layout", params: %{}}
      },
      %Item{
        id: "tmux:close_pane",
        kind: :action,
        category: :tmux,
        label: "Close Pane",
        detail: "Kill the focused pane's tmux session",
        payload: %{event: "pane:close_focused", params: %{}}
      },
      %Item{
        id: "tmux:close_other_panes",
        kind: :action,
        category: :tmux,
        label: "Close Other Panes",
        detail: "Keep the focused pane and close the rest",
        payload: %{event: "pane:close_others", params: %{}}
      },
      # Raw shell is the escape hatch from the governed terminal. The LV's
      # `terminal:set_mode` handler still enforces `raw_terminal_allowed?`
      # (manual mode + local host), so the entry is safe to surface
      # unconditionally — denied attempts flash.
      %Item{
        id: "action:terminal:raw",
        kind: :action,
        category: :tmux,
        label: "Terminal: enter raw shell",
        detail: "Full local PTY — requires manual workspace mode",
        payload: %{event: "terminal:set_mode", params: %{"mode" => "raw"}}
      },
      %Item{
        id: "action:terminal:governed",
        kind: :action,
        category: :tmux,
        label: "Terminal: return to governed",
        detail: "Exit raw shell, back to inspection-only commands",
        payload: %{event: "terminal:set_mode", params: %{"mode" => "governed"}}
      },
      %Item{
        id: "action:terminal:toggle_chrome",
        kind: :action,
        category: :tmux,
        label: "Terminal: toggle focus mode (hide/show chrome)",
        detail: "Maximize terminal space — hides header and utility bar",
        payload: %{event: "terminal:toggle_chrome", params: %{}}
      }
    ]
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
      %Item{
        id: "action:agents:refresh",
        kind: :action,
        label: "Refresh agents",
        payload: %{event: "agents:refresh", params: %{}}
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
      "agents:refresh",
      "annotation:open",
      "palette:find_pane",
      "terminal:set_mode",
      "terminal:toggle_chrome",
      "split_right",
      "split_down",
      "equalize_layout",
      "pane:close_focused",
      "pane:close_others",
      "pane:cycle_layout",
      "pane:focus_next",
      "pane:focus_previous",
      "pane:zoom_focused"
    ])
  end
end
