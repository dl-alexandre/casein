defmodule DevIDE.Terminals.SessionRegistry do
  @moduledoc """
  Registry for discovering attachable terminal sessions.

  This module provides the discovery mechanism used by `DevIDE.Terminals`.
  Over time, more session management logic will move here or into dedicated
  session process management under Jx.
  """

  alias DevIDE.Fleet
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Terminals.Session.Info

  @type session_kind :: :shell | :execution

  @type session :: Info.t()

  @doc """
  Returns all currently attachable terminal sessions for the given workspace.

  Phase 1 scope:
  - Only active (non-terminal) sessions.
  - Workspace shell sessions + fleet execution tmux sessions.
  """
  @spec list_attachable(String.t()) :: [session()]
  def list_attachable(workspace_id) when is_binary(workspace_id) do
    shells = list_workspace_shells(workspace_id)
    executions = list_fleet_executions(workspace_id)

    # Most-recently-started first feels natural for operators
    (shells ++ executions)
    |> Enum.sort_by(&sort_key/1, {:desc, DateTime})
  end

  # --- Workspace Shell Sessions (current Terminals.Session path) ---

  defp list_workspace_shells(workspace_id) do
    # Phase 1: Use Registry.select to discover currently active shell sessions
    # for this workspace. This makes workspace shells also appear in the
    # unified list (even if the primary one is usually the one in the main tab).
    Registry.select(DevIDE.Terminals.Registry, [
      {
        {{:"$1", :"$2"}, :_, :_},
        [{:==, :"$1", workspace_id}],
        [{{:"$1", :"$2"}}]
      }
    ])
    |> Enum.map(fn {ws_id, sid} ->
      Info.new_shell(ws_id, sid)
    end)
  end

  # --- Fleet Execution Tmux Sessions ---

  defp list_fleet_executions(workspace_id) do
    Fleet.list_execution_projections()
    |> Enum.filter(fn %ExecutionProjection{} = proj ->
      proj.workspace_id == workspace_id &&
        not Fleet.execution_terminal?(proj.state) &&
        proj.tmux_session != nil
    end)
    |> Enum.map(&projection_to_session/1)
  end

  defp projection_to_session(%ExecutionProjection{} = proj) do
    Info.new_execution(proj.id, proj.tmux_session,
      workspace_id: proj.workspace_id,
      runner_id: proj.runner_id,
      metadata: %{
        assignment_id: proj.assignment_id,
        started_at: proj.started_at
      }
    )
  end

  # --- Helpers ---

  defp sort_key(%{metadata: %{started_at: %DateTime{} = dt}}), do: dt
  defp sort_key(_), do: DateTime.utc_now()

  # --- Future extension points (Phase 1.5 / Phase 2) ---

  @doc """
  Resolves a session identifier (sid) into attachment information.

  Used by TerminalChannel during join.
  """
  @spec resolve(String.t()) :: {:ok, Info.t()} | :error
  def resolve("exec_" <> execution_id) do
    case Fleet.get_execution_projection(execution_id) do
      {:ok, %ExecutionProjection{tmux_session: tmux} = proj} when tmux != nil ->
        {:ok, projection_to_session(proj)}

      _ ->
        {:ok, Info.new_execution(execution_id, "devide_#{execution_id}")}
    end
  end

  def resolve(sid) when is_binary(sid) do
    {:ok, Info.new_shell(nil, sid)}
  end

  def resolve(_), do: :error
end
