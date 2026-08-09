defmodule CaseinWeb.WorkspaceLive.Show.DiffEvents do
  # Palette entry point for opening a diff inspector (#693).
  #
  # Human-facing event name is `diff:open_in_pane` (palette / chrome). The open
  # path itself is #691's `InspectorEvents` / `diff:open_inspector`, which uses
  # `Casein.Cockpit.Inspectors.open/3` (`inspector_slots` + geometry tree).
  #
  # Agent MCP surfaces go through `Casein.Inspectors.Diff.surface/2` →
  # `Inspectors.request_open/2` → `{:inspector_open, attrs}` (already handled
  # by Show → InspectorEvents). This module does not invent a second bus.
  @moduledoc false

  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  def handle_event("diff:open_in_pane", params, socket) when is_map(params) do
    InspectorEvents.handle_event("diff:open_inspector", normalize_params(params), socket)
  end

  def handle_event("diff:open_in_pane", _params, socket), do: {:noreply, socket}

  # InspectorEvents reads string keys; palette params are already string-keyed,
  # but normalize for atom-keyed callers in unit tests.
  defp normalize_params(params) when is_map(params) do
    path = Map.get(params, "path") || Map.get(params, :path)

    case path do
      p when is_binary(p) -> %{"path" => p}
      _ -> %{}
    end
  end
end
