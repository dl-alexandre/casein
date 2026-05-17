defmodule DevIDE.Workspaces do
  @moduledoc """
  Public workspaces facade.

  Returns `DevIDE.Workspace` values from the configured
  `DevIDE.WorkspaceSource` backend. The default source
  (`DevIDE.WorkspaceSource.Local`) discovers workspaces as directories
  under `:dev_ide, :workspaces_root`; production deployments select a
  different source via config — see that module's docstring.

  All consumers (LiveViews, channels, plugs) should depend on this
  module — never on a specific source implementation.
  """

  alias DevIDE.{Workspace, WorkspaceSource}
  alias DevIDE.Workspaces.State

  @type auth :: WorkspaceSource.auth()

  @spec list(keyword(), auth()) :: {:ok, [Workspace.t()]} | {:error, term()}
  def list(opts \\ [], auth \\ nil) do
    case WorkspaceSource.impl().list(opts, auth) do
      {:ok, workspaces} = ok ->
        for ws <- workspaces, do: _ = State.sync(ws)
        ok

      other ->
        other
    end
  end

  @spec get(String.t(), auth()) :: {:ok, Workspace.t()} | {:error, term()}
  def get(id, auth \\ nil) do
    case WorkspaceSource.impl().get(id, auth) do
      {:ok, ws} = ok ->
        _ = State.sync(ws)
        ok

      other ->
        other
    end
  end

  def create(params, auth \\ nil), do: WorkspaceSource.impl().create(params, auth)
  def start(id, auth \\ nil), do: WorkspaceSource.impl().start(id, auth)
  def stop(id, auth \\ nil), do: WorkspaceSource.impl().stop(id, auth)
  def delete(id, opts \\ [], auth \\ nil), do: WorkspaceSource.impl().delete(id, opts, auth)

  def stream_logs(id, service, pid \\ self()),
    do: WorkspaceSource.impl().stream_logs(id, service, pid)

  @doc """
  True when `username` owns `workspace`. Pure comparison; callers decide
  *whether* to enforce ownership (e.g. forward-auth mode).
  """
  @spec owns?(Workspace.t() | map(), String.t()) :: boolean()
  def owns?(%{user: ws_user}, username) when is_binary(ws_user) and is_binary(username),
    do: ws_user == username

  def owns?(_, _), do: false

  @spec safe_host_path(Workspace.t() | map()) :: {:ok, String.t()} | {:error, atom()}
  def safe_host_path(workspace), do: WorkspaceSource.impl().safe_host_path(workspace)

  @typedoc "Where a workspace physically lives."
  @type workspace_loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  @spec safe_host_loc(Workspace.t() | map()) ::
          {:ok, workspace_loc()} | {:error, atom()}
  def safe_host_loc(workspace), do: WorkspaceSource.impl().safe_host_loc(workspace)

  @doc """
  Filesystem roots a workspace path may live under. Generic across sources.
  Configure with `:dev_ide, :workspaces_root` (and the additive
  `:workspaces_roots` list).
  """
  @spec allowed_roots() :: [String.t()]
  def allowed_roots do
    config = Application.get_env(:dev_ide, :workspaces_roots, [])
    primary = Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    [primary | config] |> Enum.uniq() |> Enum.map(&Path.expand/1)
  end
end
