defmodule DevIDE.Agents.BrowserControl do
  @moduledoc """
  Workspace-scoped browser control for connected DevIDE LiveView clients.

  The server cannot directly manipulate a human's browser tab, but it can ask
  connected workspace LiveViews to run narrow client-side actions through
  `push_event/3`. These broadcasts are best-effort: callers get a queued status,
  not a delivery receipt from every open tab.
  """

  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIDE.PreviewActivity

  @pubsub DevIde.PubSub
  @topic_prefix "workspace_browser:"
  @default_action_timeout_ms 1_000

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

  @doc "Ask connected DevIDE workspace viewers to switch to and focus a preview pane."
  @spec focus_preview_pane(map(), String.t() | nil, String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def focus_preview_pane(workspace, tmux_session, pane_id, opts \\ [])

  def focus_preview_pane(workspace, tmux_session, pane_id, opts)
      when is_binary(pane_id) and pane_id != "" do
    opts =
      opts
      |> Keyword.put(:tmux_session, tmux_session)
      |> Keyword.put(:pane_id, pane_id)

    broadcast(workspace, "focus_preview_pane", opts)
  end

  def focus_preview_pane(_workspace, _tmux_session, _pane_id, _opts),
    do: {:error, :pane_id_required}

  @doc "Ask a connected DevIDE preview pane iframe to run a visible mutation and wait for ack."
  @spec mutate_preview_pane(map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_preview_pane(workspace, pane_id, action, target, opts \\ [])

  def mutate_preview_pane(workspace, pane_id, action, target, opts)
      when is_binary(pane_id) and pane_id != "" and is_binary(action) and is_map(target) do
    request_id = request_id()
    workspace_id = workspace_id(workspace)
    timeout = Keyword.get(opts, :timeout_ms, @default_action_timeout_ms)

    if is_binary(workspace_id) and workspace_id != "" do
      workspace_ids = WorkspaceAliases.viewer_ids(workspace_id)
      Enum.each(workspace_ids, &PreviewActivity.subscribe/1)

      payload =
        opts
        |> Keyword.put(:pane_id, pane_id)
        |> Keyword.put(:request_id, request_id)
        |> Keyword.put(:preview_action, action)
        |> Keyword.put(:preview_target, target)

      with {:ok, queued} <- broadcast_with_request_id(workspace, "preview_pane_action", payload) do
        await_preview_action_ack(workspace_ids, pane_id, request_id, timeout, queued)
      end
    else
      {:error, :workspace_id_required}
    end
  end

  def mutate_preview_pane(_workspace, _pane_id, _action, _target, _opts),
    do: {:error, :pane_id_required}

  defp broadcast(workspace, action, opts) when is_map(workspace) do
    broadcast_with_request_id(workspace, action, Keyword.put(opts, :request_id, request_id()))
  end

  defp broadcast(_workspace, _action, _opts), do: {:error, :workspace_id_required}

  defp broadcast_with_request_id(workspace, action, opts) when is_map(workspace) do
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

  defp event_payload(workspace_id, action, opts) do
    %{
      "action" => action,
      "workspace_id" => workspace_id,
      "request_id" => Keyword.get(opts, :request_id),
      "actor_id" => Keyword.get(opts, :actor_id),
      "reason" => Keyword.get(opts, :reason),
      "tmux_session" => Keyword.get(opts, :tmux_session),
      "pane_id" => Keyword.get(opts, :pane_id),
      "preview_action" => Keyword.get(opts, :preview_action),
      "target" => Keyword.get(opts, :preview_target)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp await_preview_action_ack(_workspace_ids, _pane_id, _request_id, timeout, queued)
       when timeout <= 0 do
    {:error, Map.put(queued, :reason, :visible_action_ack_timeout)}
  end

  defp await_preview_action_ack(workspace_ids, pane_id, request_id, timeout, queued) do
    receive do
      {:preview_activity, entry} ->
        if preview_action_ack?(entry, workspace_ids, pane_id, request_id) do
          case Map.get(entry.metadata || %{}, "status") do
            "ok" ->
              {:ok,
               queued
               |> Map.put(:status, "confirmed")
               |> Map.put(:pane_id, pane_id)
               |> Map.put(:event, entry.event)
               |> Map.put(:metadata, entry.metadata)}

            status ->
              {:error,
               queued
               |> Map.put(:status, status || "error")
               |> Map.put(:pane_id, pane_id)
               |> Map.put(:event, entry.event)
               |> Map.put(:metadata, entry.metadata)
               |> Map.put(:reason, Map.get(entry.metadata || %{}, "reason") || status)}
          end
        else
          await_preview_action_ack(workspace_ids, pane_id, request_id, timeout, queued)
        end
    after
      timeout ->
        {:error,
         queued
         |> Map.put(:status, "timeout")
         |> Map.put(:pane_id, pane_id)
         |> Map.put(:reason, :visible_action_ack_timeout)}
    end
  end

  defp preview_action_ack?(entry, workspace_ids, pane_id, request_id) do
    entry.source == :browser and entry.pane_id == pane_id and entry.workspace_id in workspace_ids and
      Map.get(entry.metadata || %{}, "request_id") == request_id and
      entry.event in ["visible_click", "visible_type", "visible_press"]
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
