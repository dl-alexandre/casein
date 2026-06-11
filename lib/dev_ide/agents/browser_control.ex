defmodule DevIDE.Agents.BrowserControl do
  @moduledoc """
  Workspace-scoped browser control for connected DevIDE LiveView clients.

  The server cannot directly manipulate a human's browser tab, but it can ask
  connected workspace LiveViews to run narrow client-side actions through
  `push_event/3`. These broadcasts are best-effort: callers get a queued status,
  not a delivery receipt from every open tab.
  """

  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases

  @pubsub DevIde.PubSub
  @topic_prefix "workspace_browser:"

  @type action :: String.t()
  @type result :: %{
          status: String.t(),
          action: action(),
          workspace_id: String.t(),
          request_id: String.t()
        }

  @doc "Subscribe the caller to browser-control events for a workspace."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
  end

  def subscribe(_), do: {:error, :workspace_id_required}

  @doc "Ask connected DevIDE workspace viewers to reload the active preview iframe."
  @spec reload_preview_iframe(map(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_preview_iframe(workspace, opts \\ []) do
    broadcast(workspace, "reload_preview_iframe", opts)
  end

  @doc "Ask connected DevIDE workspace viewers to reload the whole workspace page."
  @spec reload_page(map(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_page(workspace, opts \\ []) do
    broadcast(workspace, "reload_page", opts)
  end

  defp broadcast(workspace, action, opts) when is_map(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) and id != "" ->
        payload = event_payload(id, action, opts)

        for viewer_id <- WorkspaceAliases.viewer_ids(id) do
          :ok =
            Phoenix.PubSub.broadcast(
              @pubsub,
              topic(viewer_id),
              {:browser_control, Map.put(payload, "workspace_id", viewer_id)}
            )
        end

        {:ok,
         %{
           status: "queued",
           action: action,
           workspace_id: id,
           request_id: payload["request_id"]
         }}

      _ ->
        {:error, :workspace_id_required}
    end
  end

  defp broadcast(_workspace, _action, _opts), do: {:error, :workspace_id_required}

  defp event_payload(workspace_id, action, opts) do
    %{
      "action" => action,
      "workspace_id" => workspace_id,
      "request_id" => request_id(),
      "actor_id" => Keyword.get(opts, :actor_id),
      "reason" => Keyword.get(opts, :reason)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp workspace_id(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp topic(workspace_id), do: @topic_prefix <> workspace_id

  defp request_id do
    9
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
