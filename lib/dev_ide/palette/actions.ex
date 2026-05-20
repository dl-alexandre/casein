defmodule DevIDE.Palette.Actions do
  @moduledoc """
  Fixed allowlist of palette actions.

  Each action carries a payload that names an existing LiveView event the
  Show LiveView already handles (`switch_tab`, `run:start`, `tree:refresh`,
  `isolation:refresh`, `agents:refresh`, `terminal:set_mode`,
  `terminal:toggle_chrome`, and the structural pane verbs `split_right`,
  `split_down`, `equalize_layout`, `pane:close_focused`). The palette never
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
        id: "tmux:split_right",
        kind: :action,
        category: :tmux,
        label: "Tmux: split pane right (horizontal)",
        detail: "New pane beside the focused one",
        payload: %{event: "split_right", params: %{}}
      },
      %Item{
        id: "tmux:split_down",
        kind: :action,
        category: :tmux,
        label: "Tmux: split pane down (vertical)",
        detail: "New pane below the focused one",
        payload: %{event: "split_down", params: %{}}
      },
      %Item{
        id: "tmux:equalize",
        kind: :action,
        category: :tmux,
        label: "Tmux: equalize split sizes",
        detail: "Reset every split to uniform ratios",
        payload: %{event: "equalize_layout", params: %{}}
      },
      %Item{
        id: "tmux:close_pane",
        kind: :action,
        category: :tmux,
        label: "Tmux: close focused pane",
        detail: "Kill the focused pane's tmux session",
        payload: %{event: "pane:close_focused", params: %{}}
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
      "terminal:set_mode",
      "terminal:toggle_chrome",
      "split_right",
      "split_down",
      "equalize_layout",
      "pane:close_focused"
    ])
  end
end
