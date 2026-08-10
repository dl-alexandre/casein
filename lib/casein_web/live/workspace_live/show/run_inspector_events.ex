defmodule CaseinWeb.WorkspaceLive.Show.RunInspectorEvents do
  # Palette entry point for opening a run inspector (#694).
  #
  # Human-facing event name is `run:open_in_pane` (palette / chrome). The open
  # path itself is InspectorEvents / `run:open_inspector`, which uses
  # `Casein.Cockpit.Inspectors.open/3` (`inspector_slots` + geometry tree).
  #
  # Agent MCP surfaces go through `Casein.Inspectors.Run.surface/2` →
  # `Inspectors.request_open/2` → `{:inspector_open, attrs}` (already handled
  # by Show → InspectorEvents). This module does not invent a second bus.
  @moduledoc false

  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  def handle_event("run:open_in_pane", params, socket) when is_map(params) do
    InspectorEvents.handle_event("run:open_inspector", normalize_params(params), socket)
  end

  def handle_event("run:open_in_pane", _params, socket), do: {:noreply, socket}

  defp normalize_params(params) when is_map(params) do
    run_id = Map.get(params, "run_id") || Map.get(params, :run_id)

    case run_id do
      id when is_binary(id) -> %{"run_id" => id}
      _ -> %{}
    end
  end
end
