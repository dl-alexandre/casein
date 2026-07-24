defmodule CaseinWeb.WorkspaceLive.Show.SituationEvents do
  # Situation risk badge/drawer state + handle_info/handle_event clauses,
  # delegated from CaseinWeb.WorkspaceLive.Show (mirrors HistoryEvents).
  #
  # Reflect-only: the LiveView never *starts* a SituationServer — it renders
  # the badge only when the :situation_server flag is on AND a server is
  # already running for the workspace (spawned by the first digest request).
  # The "situation:<ws>" subscription is taken eagerly when the flag is on,
  # so a server that appears later lights the badge on its first transition.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias Casein.Operator.SituationServer

  @doc """
  Mount-time state: subscribe (flag on + connected) and defer the risk seed.

  The seed is a GenServer.call into the SituationServer, which may be busy in
  a full rebuild (tmux snapshots, worktree listing) — per Show's rule, that
  read must not delay first paint, so mount only schedules `:situation_seed`
  and renders an empty badge until it lands.
  """
  def mount(socket) do
    workspace_id = socket.assigns.workspace.id
    enabled? = SituationServer.enabled?()

    if enabled? and connected?(socket) do
      _ = SituationServer.subscribe(workspace_id)
      send(self(), :situation_seed)
    end

    socket
    |> assign(:situation_enabled, enabled? and SituationServer.whereis(workspace_id) != nil)
    |> assign(:situation_drawer_open, false)
    |> assign(:situation_risks, [])
  end

  # Any transition (and the deferred mount seed) re-reads the server's active
  # set (whereis-safe) instead of replaying raise/clear deltas — one code
  # path, no drift.
  def handle_info(:situation_seed, socket), do: refresh_risks(socket)

  def handle_info({:situation_risk, _kind, _risk}, socket), do: refresh_risks(socket)

  defp refresh_risks(socket) do
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
