defmodule CaseinWeb.WorkspaceLive.Show.CockpitData do
  @moduledoc """
  Read facade for the workspace cockpit's mount and asynchronous hydration data.

  LiveView-specific socket orchestration stays in `WorkspaceLive.Show`; this
  module owns the multi-context reads used to build that state.
  """

  alias Casein.Elixir, as: ElixirNav
  alias Casein.Workspaces
  alias Casein.Workspaces.Isolation
  alias Casein.Workspaces.PathResolver
  alias Casein.Workspaces.SessionSummary
  alias CaseinWeb.Plugs.ForwardAuth
  alias CaseinWeb.WorkspaceLive.Show.FileOperations

  def resolve_mount_workspace(params, user, path_access_pre_authorized?)

  def resolve_mount_workspace(%{"id" => id} = params, user, path_access_pre_authorized?) do
    with {:ok, workspace} <- Workspaces.get(id, user[:email]) do
      if path_access_pre_authorized? do
        case PathResolver.route_for(workspace) do
          {:ok, route} when route != "/" -> {:redirect, route <> id_route_query(params)}
          _ -> mount_workspace(workspace)
        end
      else
        mount_workspace(workspace)
      end
    end
  end

  def resolve_mount_workspace(params, _user, _path_access_pre_authorized?) do
    segments = Map.get(params, "lan_path", [])

    if segments in [nil, []] do
      mount_workspace(Casein.Workspaces.Scratch.workspace())
    else
      resolve_path_mount(segments)
    end
  end

  def lan_path_error(params, reason) do
    segments = normalized_lan_path_segments(Map.get(params, "lan_path", []))
    root = PathResolver.root()
    relative_path = lan_error_relative_path(segments)

    %{
      reason: reason,
      title: lan_path_error_title(reason),
      message: format_lan_path_error(reason),
      route_path: lan_error_route_path(segments),
      relative_path: relative_path,
      root_path: root,
      target_path: lan_error_target_path(root, relative_path, reason)
    }
  end

  def fetch_side_panels(host_loc, host_path, tree) do
    %{
      git_status: FileOperations.git_status(host_loc),
      tree: FileOperations.root_tree(tree, host_loc, host_path)
    }
  end

  def fetch_agents_panels(workspace, host_path, _actor_id) do
    case host_path do
      {:ok, root} ->
        isolation = Isolation.detect(workspace, root)
        _ = Workspaces.persist_isolation(workspace.id, isolation)

        %{
          db_isolation: isolation,
          project_meta: ElixirNav.project(root),
          tooling: ElixirNav.tooling(root),
          isolation_audit: %{
            "isolation" => Atom.to_string(isolation.isolation),
            "source" => Atom.to_string(isolation.source),
            "redacted_summary" => isolation.summary
          }
        }

      _ ->
        %{
          db_isolation: %Casein.Workspaces.DbIsolation{detected_at: DateTime.utc_now()},
          project_meta: %{},
          tooling: %{},
          isolation_audit: nil
        }
    end
  end

  def workspace_summaries_for(workspace) do
    list_sidebar_workspace_records()
    |> ensure_current_workspace_record(workspace)
    |> SessionSummary.build_many()
  end

  def visible_workspace_summaries(summaries, %{} = user) do
    if ForwardAuth.admin?(user), do: summaries, else: []
  end

  def visible_workspace_summaries(_summaries, _user), do: []

  defp mount_workspace(workspace) do
    {:ok, %{workspace: workspace, path_route: nil, workspace_route: nil}}
  end

  @id_redirect_params ~w(session window pane zoom)
  defp id_route_query(params) do
    query =
      params
      |> Map.take(@id_redirect_params)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    if query == "", do: "", else: "?" <> query
  end

  defp resolve_path_mount(segments) do
    case PathResolver.resolve(segments) do
      {:ok, resolution} ->
        with {:ok, workspace} <- Workspaces.workspace_for_host_path(resolution.workspace_path) do
          {:ok,
           %{
             workspace: workspace,
             path_route: resolution.route_path,
             workspace_route: resolution.workspace_route
           }}
        end

      {:error, reason} ->
        {:error, {:lan_path, reason}}
    end
  end

  defp normalized_lan_path_segments(segments) when is_list(segments) do
    Enum.reject(segments, &(&1 in [nil, ""]))
  end

  defp normalized_lan_path_segments(_segments), do: []

  defp lan_error_route_path([]), do: "/"
  defp lan_error_route_path(segments), do: "/" <> Enum.map_join(segments, "/", &URI.encode/1)

  defp lan_error_relative_path([]), do: ""

  defp lan_error_relative_path(segments) do
    if Enum.all?(segments, &is_binary/1), do: Path.join(segments), else: ""
  end

  defp lan_error_target_path(root, relative_path, reason)
       when reason in [:not_found, :outside_root, :symlink_escape] and is_binary(root) and
              root != "" do
    root
    |> Path.join(relative_path)
    |> Path.expand()
  end

  defp lan_error_target_path(_root, _relative_path, _reason), do: nil

  defp lan_path_error_title(:not_found), do: "Directory not found"
  defp lan_path_error_title(:reserved_prefix), do: "Reserved path"
  defp lan_path_error_title(:invalid_path), do: "Invalid path"
  defp lan_path_error_title(:outside_root), do: "Path outside the path root"
  defp lan_path_error_title(:symlink_escape), do: "Path outside the path root"
  defp lan_path_error_title(_reason), do: "Path unavailable"

  defp format_lan_path_error(:invalid_root), do: "path root is not an absolute directory"
  defp format_lan_path_error(:missing_root), do: "path root is not configured"
  defp format_lan_path_error(:reserved_prefix), do: "path is reserved by Casein"
  defp format_lan_path_error(:invalid_path), do: "path is invalid"
  defp format_lan_path_error(:outside_root), do: "path escapes the path root"
  defp format_lan_path_error(:symlink_escape), do: "path follows a symlink outside the path root"
  defp format_lan_path_error(:too_deep), do: "path is too deep"
  defp format_lan_path_error(:not_found), do: "directory was not found"
  defp format_lan_path_error(reason), do: inspect(reason)

  defp list_sidebar_workspace_records do
    Workspaces.list_records(
      exclude_status: Casein.Workspaces.State.WorkspaceRecord.stale_status(),
      limit: 200
    )
  end

  defp ensure_current_workspace_record(records, workspace) do
    if Enum.any?(records, &(Map.get(&1, :external_id) == workspace.id)) do
      records
    else
      [workspace | records]
    end
  end
end
