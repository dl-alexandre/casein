defmodule CaseinWeb.WorkspaceLive.PickerBadges do
  @moduledoc """
  Presentation helpers for workspace rows: status colors, per-session agent
  badges, and the workspace agent-layout badge.

  Shared by the dashboard (and the legacy picker until it is deleted) so the
  enriched-row rendering stays identical across both surfaces.
  """

  def mode_class(:local), do: "bg-green-50 text-green-700 border border-green-200"
  def mode_class(:remote), do: "bg-blue-50 text-blue-700 border border-blue-200"
  def mode_class(_), do: "bg-zinc-50 text-zinc-600 border border-zinc-200"

  def status_class(:running), do: "text-green-700"
  def status_class(:stopped), do: "text-zinc-500"
  def status_class(_), do: "text-amber-700"

  def session_agent_status(%{agent_status: status}) when is_binary(status) and status != "",
    do: status

  def session_agent_status(%{"agent_status" => status}) when is_binary(status) and status != "",
    do: status

  def session_agent_status(_session), do: nil

  def workspace_agent_layout_status(ws) do
    layout = Map.get(ws, :agent_layout) || Map.get(ws, "agent_layout") || %{}

    case Map.get(layout, :status) || Map.get(layout, "status") do
      "ready" -> "ready"
      "missing_agent_pane" -> "missing_agent_pane"
      _ -> nil
    end
  end

  def workspace_agent_layout_label("ready"), do: "agent ready"
  def workspace_agent_layout_label("missing_agent_pane"), do: "agent pane missing"

  def workspace_agent_layout_icon("ready"), do: "hero-check-circle"
  def workspace_agent_layout_icon("missing_agent_pane"), do: "hero-exclamation-triangle"

  def workspace_agent_layout_class("ready") do
    "inline-flex items-center gap-0.5 rounded border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700"
  end

  def workspace_agent_layout_class("missing_agent_pane") do
    "inline-flex items-center gap-0.5 rounded border border-amber-200 bg-amber-50 px-1.5 py-0.5 text-[10px] font-medium text-amber-800"
  end

  def workspace_agent_layout_title(ws) do
    layout = Map.get(ws, :agent_layout) || Map.get(ws, "agent_layout") || %{}

    case Map.get(layout, :suggested_template) || Map.get(layout, "suggested_template") do
      template when is_binary(template) and template != "" ->
        "Role-marked agent pane: #{template}"

      _ ->
        "Role-marked agent pane"
    end
  end

  def session_agent_status_title(session) do
    title =
      Map.get(session, :agent_title) ||
        Map.get(session, "agent_title") ||
        Map.get(session, :title) ||
        Map.get(session, "title")

    case title do
      value when is_binary(value) and value != "" -> value
      _ -> "Latest agent prompt status"
    end
  end

  def agent_session_status_class("attention"),
    do: "rounded border border-red-200 bg-red-50 px-1 py-0.5 text-[10px] font-medium text-red-700"

  def agent_session_status_class("done"),
    do:
      "rounded border border-emerald-200 bg-emerald-50 px-1 py-0.5 text-[10px] font-medium text-emerald-700"

  def agent_session_status_class("running"),
    do:
      "rounded border border-blue-200 bg-blue-50 px-1 py-0.5 text-[10px] font-medium text-blue-700"

  def agent_session_status_class(_status),
    do:
      "rounded border border-zinc-200 bg-zinc-50 px-1 py-0.5 text-[10px] font-medium text-zinc-600"

  def session_share_url(href) when is_binary(href) and href != "" do
    CaseinWeb.Endpoint.url() <> href
  end
end
