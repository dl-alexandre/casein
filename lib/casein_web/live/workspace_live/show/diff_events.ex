defmodule CaseinWeb.WorkspaceLive.Show.DiffEvents do
  # Palette / MCP entry points for opening a diff inspector.
  #
  # #693 owns the human-facing event name (`diff:open_in_pane`) and the
  # one-shot MCP surface. The actual open/fallback lives in #691's
  # `InspectorEvents` (`diff:open_inspector` + `Casein.Cockpit.Inspectors`).
  # This module is the thin bridge so palette/MCP never invent geometry.
  @moduledoc false

  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  def handle_event("diff:open_in_pane", params, socket) when is_map(params) do
    InspectorEvents.handle_event("diff:open_inspector", normalize_params(params), socket)
  end

  def handle_event("diff:open_in_pane", _params, socket), do: {:noreply, socket}

  @doc false
  def handle_info({:surface_diff, intent}, socket) when is_map(intent) do
    InspectorEvents.handle_event("diff:open_inspector", normalize_params(intent), socket)
  end

  def handle_info({:surface_diff, _}, socket), do: {:noreply, socket}

  # InspectorEvents reads string keys; MCP / PubSub may send atom keys.
  defp normalize_params(params) when is_map(params) do
    path = Map.get(params, "path") || Map.get(params, :path)

    case path do
      p when is_binary(p) -> %{"path" => p}
      _ -> %{}
    end
  end
end
