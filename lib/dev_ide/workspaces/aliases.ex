defmodule Casein.Workspaces.Aliases do
  @moduledoc false

  alias Casein.Workspaces

  @doc """
  Workspace ids that should receive preview/browser broadcasts for `workspace_id`.

  Manager workspaces and folder-attached workspaces that point at the same host
  path are treated as one viewer audience so MCP opens reach whichever tab the
  human has open.

  `resolve_remote?` (default `true`) controls the cold-`State` fallback: when a
  workspace has no persisted host_path record, `true` resolves it via a
  `Workspaces.get/1` HTTP call, `false` degrades to the canonical id alone.

  Pass `resolve_remote?: false` from any context that must not block on (or
  crash inside) synchronous HTTP — notably best-effort PubSub broadcast fan-out
  from a long-lived GenServer, where a cold-State HTTP call has no test-owner
  `$callers` bridge and would crash the process. Missing a linked-alias viewer
  on a cold cache is self-healing (its next poll picks up the state); crashing
  the singleton is not.
  """
  @spec viewer_ids(String.t(), keyword()) :: [String.t()]
  def viewer_ids(workspace_id, opts \\ [])

  def viewer_ids(workspace_id, opts) when is_binary(workspace_id) and workspace_id != "" do
    workspace_id
    |> linked_ids(Keyword.get(opts, :resolve_remote?, true))
    |> Enum.uniq()
  end

  def viewer_ids(_, _), do: []

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

  @doc """
  Casein viewer route for a workspace id.

  Manager workspaces use `/workspaces/{uuid}`; folder-attached workspaces use
  `/workspaces/folder:{base64url-absolute-path}`.
  """
  @spec viewer_route_id(String.t()) :: String.t()
  def viewer_route_id(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    "/workspaces/" <> workspace_id
  end

  def viewer_route_id(_), do: "/workspaces"

  defp linked_ids(workspace_id, resolve_remote?) do
    case expanded_host_path(workspace_id, resolve_remote?) do
      path when is_binary(path) ->
        [workspace_id, folder_id_for_path(path)] ++ manager_ids_for_path(path)

      _ ->
        [workspace_id]
    end
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp same_host_path?(left, right) do
    # linked?/2 keeps remote resolution — it answers a correctness question
    # (are these the same on-disk workspace?), not a best-effort fan-out.
    case {expanded_host_path(left, true), expanded_host_path(right, true)} do
      {path, path} when is_binary(path) -> true
      _ -> false
    end
  end

  defp expanded_host_path(workspace_id, resolve_remote?) do
    cond do
      path = Workspaces.decode_folder_id(workspace_id) ->
        Path.expand(path)

      path = host_path_from_record(workspace_id) ->
        Path.expand(path)

      resolve_remote? ->
        case Workspaces.get(workspace_id) do
          {:ok, workspace} ->
            case Workspaces.safe_host_path(workspace) do
              {:ok, path} -> Path.expand(path)
              _ -> nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp host_path_from_record(workspace_id) do
    case Casein.Workspaces.State.get(workspace_id) do
      {:ok, %{host_path: path}} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp manager_ids_for_path(path) do
    expanded = Path.expand(path)

    Casein.Workspaces.State.list()
    |> Enum.filter(fn record ->
      case record.host_path do
        host_path when is_binary(host_path) -> Path.expand(host_path) == expanded
        _ -> false
      end
    end)
    |> Enum.map(& &1.external_id)
  end
end
