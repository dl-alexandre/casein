defmodule CaseinWeb.WorkspaceLive.Show.AfterMount do
  # After-mount handle_info clauses extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  #
  # Owns: :after_mount_side_panels, :after_mount_runs, :after_mount_agents.
  # `:after_mount` itself stays on Show — it starts the raw terminal and is
  # not one of the three deferred hydration steps this module holds.
  #
  # Constraints (do not "fix" as a side effect of this split):
  # - Behaviour-preserving only. A bug found while splitting is a new issue,
  #   not a change in this PR.
  # - Do not touch Show's handle_event dispatch table or authz_gate/3.
  # - Do not "fix" LiveView change tracking. Adding :__changed__ to a
  #   Map.take does not restore tracking for assigns-dependent dynamic
  #   parts; that is a separate, already-understood problem.
  @moduledoc false

  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias CaseinWeb.WorkspaceLive.Show.CockpitData
  alias CaseinWeb.WorkspaceLive.Show.CodexEvents
  alias CaseinWeb.WorkspaceLive.Show.PreviewPaneEvents
  alias CaseinWeb.WorkspaceLive.Show.RunEvents

  def handle_info(:after_mount_side_panels, socket) do
    if connected?(socket) do
      host_loc = socket.assigns[:host_loc]
      host_path = socket.assigns[:host_path]
      workspace = socket.assigns.workspace
      tree = socket.assigns.tree
      actor_id = current_actor_id(socket)

      # start_async + plain assigns in handle_async — NOT assign_async: the
      # templates and refresh paths (render_diff, refresh_tree,
      # handle_async(:refresh_git_status)) all consume :git_status/:tree as
      # plain values, and the :agents_mount results are post-processed by the
      # handle_async clause below (assign_async would bypass it entirely).
      # Capture workspace / host_path before the closures (same pattern as
      # neighboring asyncs) — discover_surfaces + load_feature_panes are the
      # expensive scans previously on connected mount.
      path_result = host_path
      ws = workspace

      socket =
        socket
        |> start_async(:load_side_panels, fn ->
          fetch_side_panels(host_loc, host_path, tree)
        end)
        |> start_async(:agents_mount, fn ->
          fetch_agents_panels(workspace, host_path, actor_id)
        end)
        |> start_async(:load_preview_state, fn ->
          %{
            workspace_id: ws.id,
            preview_surfaces: Casein.Previews.discover_surfaces(ws),
            feature_panes: PreviewPaneEvents.load_feature_panes(ws, path_result)
          }
        end)

      send(self(), :after_mount_runs)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_runs, socket) do
    if connected?(socket) do
      socket =
        if socket.assigns[:tab] == "run" do
          socket
          |> RunEvents.attach_existing_run()
          |> RunEvents.refresh_run_ledger()
        else
          socket
        end

      send(self(), :after_mount_agents)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_agents, socket) do
    socket =
      if connected?(socket) do
        CodexEvents.open(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  defp fetch_side_panels(host_loc, host_path, tree) do
    CockpitData.fetch_side_panels(host_loc, host_path, tree)
  end

  defp fetch_agents_panels(workspace, host_path, actor_id) do
    CockpitData.fetch_agents_panels(workspace, host_path, actor_id)
  end
end
