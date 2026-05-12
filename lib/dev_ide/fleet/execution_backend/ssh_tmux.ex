defmodule DevIDE.Fleet.ExecutionBackend.SshTmux do
  @moduledoc """
  SSH/tmux-backed execution infrastructure.

  The module prepares remote worktree metadata and tmux attachment commands.
  It deliberately returns infrastructure handles only; orchestration state is
  still reported through the fleet protocol.
  """

  @behaviour DevIDE.Fleet.ExecutionBackend

  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.WorkspaceContext
  alias DevIDE.Terminals.TmuxAdapter
  alias DevIDE.Workspaces.State

  @impl true
  def prepare_workspace(workspace_id, opts \\ []) do
    with {:ok, context} <- WorkspaceContext.validate(workspace_id) do
      observed = observed_workspace(workspace_id)
      metadata = (observed && observed.manager_payload) || %{}
      remote_host = Keyword.get(opts, :host) || metadata_value(metadata, "host")
      remote_path = Keyword.get(opts, :remote_path) || context.worktree_path

      {:ok,
       %{
         workspace_id: context.workspace_id,
         git_sha: context.git_sha || metadata_value(metadata, "git_sha"),
         branch: metadata_value(metadata, "branch"),
         local_path: context.worktree_path,
         remote_host: remote_host,
         remote_path: remote_path
       }}
    end
  end

  @impl true
  def start_session(execution_id, workspace, opts \\ []) do
    tmux = Keyword.get(opts, :tmux_adapter, TmuxAdapter)
    worktree_path = Map.fetch!(workspace, :remote_path)

    with {:ok, session} <- tmux.create_session(execution_id, worktree_path: worktree_path) do
      {:ok,
       %{
         execution_id: execution_id,
         tmux_session: session,
         attach_command: tmux.attach_command(session),
         remote_host: Map.get(workspace, :remote_host),
         worktree_path: worktree_path
       }}
    end
  end

  @impl true
  def attach(execution_id, opts \\ []) do
    tmux = Keyword.get(opts, :tmux_adapter, TmuxAdapter)

    with {:ok, projection} <- ExecutionProjectionStore.get(execution_id),
         session when is_binary(session) <- projection.tmux_session,
         true <- tmux.session_alive?(session) || {:error, :session_not_alive} do
      {:ok,
       %{
         execution_id: execution_id,
         tmux_session: session,
         attach_command: tmux.attach_command(session),
         historical_chunks: ArtifactStore.chunks(execution_id)
       }}
    else
      :error -> {:error, :execution_not_found}
      nil -> {:error, :no_tmux_session}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def resume(execution_id, opts \\ []) do
    attach(execution_id, opts)
  end

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
  end

  defp metadata_value(_value, _key), do: nil

  defp observed_workspace(workspace_id) do
    case State.get(workspace_id) do
      {:ok, workspace} -> workspace
      :error -> nil
    end
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
