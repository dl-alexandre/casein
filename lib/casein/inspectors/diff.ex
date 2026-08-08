defmodule Casein.Inspectors.Diff do
  @moduledoc """
  One-shot intent to surface a git diff to a connected cockpit viewer.

  A diff is a viewport over derived git state — not a durable pane handle. Agents
  declare **what** to show; Casein owns placement. If nobody is watching the
  workspace the broadcast is a no-op (do not queue, retry, or persist).

  The LiveView-owned inspector region (#690/#691) is not required for the
  full-area `diff` tab fallback used today. When that API lands, the mounted
  cockpit upgrades the same `{:surface_diff, intent}` message.
  """

  @pubsub Casein.PubSub
  @topic_prefix "inspectors:diff:"
  @viewer_registry Casein.Inspectors.Diff.ViewerRegistry

  @type intent :: %{
          optional(:path) => String.t() | nil,
          optional(:actor_id) => String.t() | nil,
          optional(:request_id) => String.t()
        }

  @doc "PubSub topic for diff surface intents on a workspace."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc "Subscribe the calling LiveView to diff surface intents."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
  end

  def subscribe(_), do: {:error, :workspace_id_required}

  @doc """
  Register the calling process as a watching cockpit viewer.

  Uses a duplicate Registry so presence is process-linked: when the LiveView
  exits the registration vanishes with no explicit unregister.
  """
  @spec register_viewer(String.t()) :: :ok | {:error, term()}
  def register_viewer(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case Registry.register(@viewer_registry, workspace_id, true) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def register_viewer(_), do: {:error, :workspace_id_required}

  @doc "True when at least one cockpit LiveView is registered for the workspace."
  @spec viewer_present?(String.t()) :: boolean()
  def viewer_present?(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    match?([_ | _], Registry.lookup(@viewer_registry, workspace_id))
  end

  def viewer_present?(_), do: false

  @doc """
  Surface a diff intent to connected viewers.

  Returns `{:ok, %{status: "surfaced" | "no_viewer", ...}}`. Never queues when
  idle — a viewport with no watcher is correctly a no-op.
  """
  @spec surface(String.t(), intent()) :: {:ok, map()}
  def surface(workspace_id, intent \\ %{})

  def surface(workspace_id, intent)
      when is_binary(workspace_id) and workspace_id != "" and is_map(intent) do
    request_id = intent_request_id(intent)
    path = intent_path(intent)

    payload =
      %{
        workspace_id: workspace_id,
        path: path,
        actor_id: intent_actor(intent),
        request_id: request_id
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    if viewer_present?(workspace_id) do
      :ok = Phoenix.PubSub.broadcast(@pubsub, topic(workspace_id), {:surface_diff, payload})

      {:ok,
       %{
         status: "surfaced",
         workspace_id: workspace_id,
         path: path,
         request_id: request_id
       }
       |> compact()}
    else
      {:ok,
       %{
         status: "no_viewer",
         workspace_id: workspace_id,
         path: path,
         request_id: request_id
       }
       |> compact()}
    end
  end

  def surface(_, _), do: {:error, :workspace_id_required}

  defp intent_path(intent) do
    case Map.get(intent, :path) || Map.get(intent, "path") do
      path when is_binary(path) ->
        path = String.trim(path)
        if path == "", do: nil, else: path

      _ ->
        nil
    end
  end

  defp intent_actor(intent) do
    case Map.get(intent, :actor_id) || Map.get(intent, "actor_id") do
      actor when is_binary(actor) and actor != "" -> actor
      _ -> nil
    end
  end

  defp intent_request_id(intent) do
    case Map.get(intent, :request_id) || Map.get(intent, "request_id") do
      id when is_binary(id) and id != "" -> id
      _ -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    end
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
