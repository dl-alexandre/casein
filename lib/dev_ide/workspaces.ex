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
    # Folder-attach workspaces have a "folder:" prefix. They bypass the source
    # (which knows nothing about arbitrary paths) and are reconstructed directly
    # from the encoded path, falling back to the persisted record if available.
    case decode_folder_id(id) do
      path when is_binary(path) ->
        cond do
          not File.dir?(path) ->
            {:error, :not_found}

          not path_under_allowed_roots?(path) ->
            {:error, :outside_allowed_roots}

          true ->
            ws = build_attached_workspace(path)
            _ = State.sync(ws)
            {:ok, ws}
        end

      nil ->
        case WorkspaceSource.impl().get(id, auth) do
          {:ok, ws} = ok ->
            _ = State.sync(ws)
            ok

          other ->
            other
        end
    end
  end

  def create(params, auth \\ nil), do: WorkspaceSource.impl().create(params, auth)
  def start(id, auth \\ nil), do: WorkspaceSource.impl().start(id, auth)
  def stop(id, auth \\ nil), do: WorkspaceSource.impl().stop(id, auth)
  def delete(id, opts \\ [], auth \\ nil), do: WorkspaceSource.impl().delete(id, opts, auth)

  def create_form_fields, do: WorkspaceSource.create_form_fields()

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
  def safe_host_path(%Workspace{metadata: %{attached_folder: true}, path: path})
      when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, :not_found}
    end
  end

  def safe_host_path(workspace), do: WorkspaceSource.impl().safe_host_path(workspace)

  @typedoc "Where a workspace physically lives."
  @type workspace_loc :: {:local, String.t()} | {:remote, String.t(), String.t()}

  @spec safe_host_loc(Workspace.t() | map()) ::
          {:ok, workspace_loc()} | {:error, atom()}
  def safe_host_loc(%Workspace{metadata: %{attached_folder: true}, path: path})
      when is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      {:ok, {:local, expanded}}
    else
      {:error, :not_found}
    end
  end

  def safe_host_loc(workspace), do: WorkspaceSource.impl().safe_host_loc(workspace)

  @doc """
  Attach to an arbitrary local folder path and return a `%Workspace{}` for it.

  The workspace id is a URL-safe base64 encoding of the absolute path so it
  round-trips cleanly through the router. The workspace is synced into state
  so the cockpit can look it up via `get/2`.

  Returns `{:error, :not_a_directory}` when the path does not point to an
  existing directory.
  """
  @spec attach_folder(String.t()) :: {:ok, Workspace.t()} | {:error, atom()}
  def attach_folder(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      not File.dir?(expanded) ->
        {:error, :not_a_directory}

      not path_under_allowed_roots?(expanded) ->
        {:error, :outside_allowed_roots}

      true ->
        ws = build_attached_workspace(expanded)
        _ = State.sync(ws)
        {:ok, ws}
    end
  end

  @doc """
  Returns the absolute path encoded in a folder-attach workspace id, or `nil`
  when the id is not a folder-attach id.
  """
  @spec decode_folder_id(String.t()) :: String.t() | nil
  def decode_folder_id("folder:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  def decode_folder_id(_), do: nil

  defp build_attached_workspace(expanded_path) do
    id = "folder:" <> Base.url_encode64(expanded_path, padding: false)
    name = Path.basename(expanded_path)

    %Workspace{
      id: id,
      name: name,
      user: nil,
      branch: detect_branch(expanded_path),
      status: :running,
      path: expanded_path,
      metadata: %{attached_folder: true}
    }
  end

  defp detect_branch(path) do
    case System.cmd("git", ["-C", path, "branch", "--show-current"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> then(fn s -> if s == "", do: nil, else: s end)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  Filesystem roots a workspace path may live under. Generic across sources.
  Configure with `:dev_ide, :workspaces_root` (and the additive
  `:workspaces_roots` list).
  """
  @spec allowed_roots() :: [String.t()]
  def allowed_roots do
    config = Application.get_env(:dev_ide, :workspaces_roots) || []
    primary = Application.get_env(:dev_ide, :workspaces_root, "/workspaces")
    [primary | config] |> Enum.uniq() |> Enum.map(&Path.expand/1)
  end

  @doc false
  def path_under_allowed_roots?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Enum.any?(allowed_roots(), fn root ->
      expanded == root or String.starts_with?(expanded, root <> "/")
    end)
  end
end
