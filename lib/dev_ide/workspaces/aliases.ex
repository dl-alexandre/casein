defmodule DevIDE.Workspaces.Aliases do
  @moduledoc false

  alias DevIDE.Workspaces

  @doc """
  Workspace ids that should receive preview/browser broadcasts for `workspace_id`.

  Manager workspaces and folder-attached workspaces that point at the same host
  path are treated as one viewer audience so MCP opens reach whichever tab the
  human has open.
  """
  @spec viewer_ids(String.t()) :: [String.t()]
  def viewer_ids(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    workspace_id
    |> linked_ids()
    |> Enum.uniq()
  end

  def viewer_ids(_), do: []

  @doc "True when two workspace ids refer to the same on-disk workspace path."
  @spec linked?(String.t(), String.t()) :: boolean()
  def linked?(left, right) when is_binary(left) and is_binary(right) do
    left == right or same_host_path?(left, right)
  end

  def linked?(_, _), do: false

  @doc "Folder-attached workspace id for an absolute host path."
  @spec folder_id_for_path(String.t()) :: String.t()
  def folder_id_for_path(path) when is_binary(path) do
    "folder:" <> Base.url_encode64(Path.expand(path), padding: false)
  end

  defp linked_ids(workspace_id) do
    case expanded_host_path(workspace_id) do
      path when is_binary(path) ->
        [workspace_id, folder_id_for_path(path)] ++ manager_ids_for_path(path)

      _ ->
        [workspace_id]
    end
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp same_host_path?(left, right) do
    case {expanded_host_path(left), expanded_host_path(right)} do
      {path, path} when is_binary(path) -> true
      _ -> false
    end
  end

  defp expanded_host_path(workspace_id) do
    cond do
      path = Workspaces.decode_folder_id(workspace_id) ->
        Path.expand(path)

      path = host_path_from_record(workspace_id) ->
        Path.expand(path)

      true ->
        case Workspaces.get(workspace_id) do
          {:ok, workspace} ->
            case Workspaces.safe_host_path(workspace) do
              {:ok, path} -> Path.expand(path)
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp host_path_from_record(workspace_id) do
    case DevIDE.Workspaces.State.get(workspace_id) do
      {:ok, %{host_path: path}} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp manager_ids_for_path(path) do
    expanded = Path.expand(path)

    DevIDE.Workspaces.State.list()
    |> Enum.filter(fn record ->
      case record.host_path do
        host_path when is_binary(host_path) -> Path.expand(host_path) == expanded
        _ -> false
      end
    end)
    |> Enum.map(& &1.external_id)
  end
end
