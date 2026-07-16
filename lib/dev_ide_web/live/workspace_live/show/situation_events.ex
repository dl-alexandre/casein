defmodule DevIdeWeb.WorkspaceLive.Show.SituationEvents do
  # Situation risk badge/drawer state + handle_info/handle_event clauses,
  # delegated from DevIdeWeb.WorkspaceLive.Show (mirrors HistoryEvents).
  #
  # Reflect-only: the LiveView never *starts* a SituationServer — it renders
  # the badge only when the :situation_server flag is on AND a server is
  # already running for the workspace (spawned by the first digest request).
  # The "situation:<ws>" subscription is taken eagerly when the flag is on,
  # so a server that appears later lights the badge on its first transition.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias DevIDE.Operator.SituationServer

  @doc "Mount-time state: subscribe (flag on + connected) and seed active risks."
  def mount(socket) do
    workspace_id = socket.assigns.workspace.id
    enabled? = SituationServer.enabled?()

    if enabled? and connected?(socket) do
      _ = SituationServer.subscribe(workspace_id)
    end

    server_up? = enabled? and SituationServer.whereis(workspace_id) != nil

    socket
    |> assign(:situation_enabled, server_up?)
    |> assign(:situation_drawer_open, false)
    |> assign(
      :situation_risks,
      if(server_up?, do: SituationServer.active_risks(workspace_id), else: [])
    )
  end

  # Any transition re-reads the server's active set (whereis-safe) instead of
  # replaying raise/clear deltas — one code path, no drift.
  def handle_info({:situation_risk, _kind, _risk}, socket) do
    workspace_id = socket.assigns.workspace.id

    {:noreply,
     socket
     |> assign(:situation_enabled, SituationServer.whereis(workspace_id) != nil)
     |> assign(:situation_risks, SituationServer.active_risks(workspace_id))}
  end

  def handle_event("situation_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :situation_drawer_open, not socket.assigns.situation_drawer_open)}
  end

  def handle_event("situation_drawer:close", _params, socket) do
    {:noreply, assign(socket, :situation_drawer_open, false)}
  end
end
