defmodule DevIDE.Palette.Actions do
  @moduledoc """
  Fixed allowlist of palette actions.

  Each action carries a payload that names an existing LiveView event the
  Show LiveView already handles (`switch_tab`, `run:start`, `tree:refresh`,
  `isolation:refresh`, `agents:refresh`). The palette never invents new
  mutation events; it only routes to gated existing ones.
  """

  alias DevIDE.Commands
  alias DevIDE.Palette.Item

  @tabs ~w(terminal files search diff run agents logs)

  @spec all() :: [Item.t()]
  def all do
    tab_items() ++ command_items() ++ refresh_items()
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
      },
      # Raw shell is the escape hatch from the governed terminal. The LV's
      # `terminal:set_mode` handler still enforces `raw_terminal_allowed?`
      # (manual mode + local host), so the entry is safe to surface
      # unconditionally — denied attempts flash.
      %Item{
        id: "action:terminal:raw",
        kind: :action,
        label: "Terminal: enter raw shell",
        detail: "Full local PTY — requires manual workspace mode",
        payload: %{event: "terminal:set_mode", params: %{"mode" => "raw"}}
      },
      %Item{
        id: "action:terminal:governed",
        kind: :action,
        label: "Terminal: return to governed",
        detail: "Exit raw shell, back to inspection-only commands",
        payload: %{event: "terminal:set_mode", params: %{"mode" => "governed"}}
      },
      %Item{
        id: "action:terminal:toggle_chrome",
        kind: :action,
        label: "Terminal: toggle focus mode (hide/show chrome)",
        detail: "Maximize terminal space — hides header and utility bar",
        payload: %{event: "terminal:toggle_chrome", params: %{}}
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
      "terminal:toggle_chrome"
    ])
  end
end
