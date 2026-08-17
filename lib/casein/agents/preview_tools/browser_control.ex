defmodule Casein.Agents.PreviewTools.BrowserControl do
  @moduledoc """
  Workspace-scoped browser control for connected Casein LiveView clients.

  The server cannot directly manipulate a human's browser tab, but it can ask
  connected workspace LiveViews to run narrow client-side actions through
  `push_event/3`.

  Every action here is viewer-gated: the only subscriber to the broadcast topic
  is a *connected* `WorkspaceLive.Show`, and the acks come from its JS hook. With
  no tab open there is nothing to receive the message and nothing that can ever
  ack it. `Phoenix.PubSub.broadcast/3` returns `:ok` with zero subscribers, so
  presence is tracked in a duplicate `Registry` instead — the same approach
  `Casein.Inspectors.Diff` uses, and for the same reason: so a caller can tell
  "nobody is watching" from "a viewer got it".

  Statuses are `"delivered"` (a viewer was present and the broadcast went to it —
  not an ack) and `"no_viewer"` (nothing happened, and nothing will). Never
  queues: there is no buffer and no replay on viewer mount, so reporting queued
  work would be a claim this module cannot honour.
  """

  alias Casein.Previews.Deps
  alias Casein.PreviewActivity

  @pubsub Casein.PubSub
  @topic_prefix "workspace_browser:"
  @default_action_timeout_ms 1_000
  @viewer_registry __MODULE__.ViewerRegistry

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

  @doc """
  Register the calling process as a connected browser-control viewer.

  Process-linked via a duplicate Registry, so the registration vanishes when the
  LiveView exits with no explicit unregister. Call this wherever `subscribe/1` is
  called — presence and subscription must describe the same tab or the status
  this module reports is worse than useless.
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

  @doc "True when at least one workspace LiveView is registered for the workspace."
  @spec viewer_present?(String.t()) :: boolean()
  def viewer_present?(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    match?([_ | _], Registry.lookup(@viewer_registry, workspace_id))
  end

  def viewer_present?(_), do: false

  # A workspace id can fan out to several viewer ids (linked manager/folder
  # workspaces), and a viewer watching any one of them will receive the
  # broadcast, so presence is the union rather than the caller's id alone.
  defp any_viewer_present?(workspace_ids) do
    Enum.any?(workspace_ids, &viewer_present?/1)
  end

  @doc "Ask connected Casein workspace viewers to reload the active preview iframe."
  @spec reload_preview_iframe(map(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_preview_iframe(workspace, opts \\ []) do
    broadcast(workspace, "reload_preview_iframe", opts)
  end

  @doc "Ask connected Casein workspace viewers to reload the whole workspace page."
  @spec reload_page(map(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_page(workspace, opts \\ []) do
    broadcast(workspace, "reload_page", opts)
  end

  @doc "Ask connected Casein workspace viewers to switch to and focus a preview pane."
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

  # The ack can only come from a viewer's JS hook. With no viewer, waiting the
  # full timeout buys nothing and reports `visible_action_ack_timeout`, which
  # reads like the hook misbehaved and sends callers chasing reloads that also
  # cannot be delivered. Say what is actually wrong instead.
  defp dispatch_visible_action(workspace_ids, workspace, pane_id, action, target, meta) do
    if any_viewer_present?(workspace_ids) do
      Enum.each(workspace_ids, &PreviewActivity.subscribe/1)

      payload =
        meta
        |> Keyword.fetch!(:opts)
        |> Keyword.put(:pane_id, pane_id)
        |> Keyword.put(:request_id, Keyword.fetch!(meta, :request_id))
        |> Keyword.put(:preview_action, action)
        |> Keyword.put(:preview_target, target)

      with {:ok, queued} <- broadcast_with_request_id(workspace, "preview_pane_action", payload) do
        await_preview_action_ack(
          workspace_ids,
          pane_id,
          Keyword.fetch!(meta, :request_id),
          Keyword.fetch!(meta, :timeout),
          queued
        )
      end
    else
      {:error,
       %{
         status: "no_viewer",
         reason: :no_connected_viewer,
         pane_id: pane_id,
         request_id: Keyword.fetch!(meta, :request_id),
         workspace_id: Keyword.fetch!(meta, :workspace_id)
       }}
    end
  end

  @doc "Ask a connected Casein preview pane iframe to run a visible mutation and wait for ack."
  @spec mutate_preview_pane(map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_preview_pane(workspace, pane_id, action, target, opts \\ [])

  def mutate_preview_pane(workspace, pane_id, action, target, opts)
      when is_binary(pane_id) and pane_id != "" and is_binary(action) and is_map(target) do
    request_id = request_id()
    workspace_id = workspace_id(workspace)
    timeout = Keyword.get(opts, :timeout_ms, @default_action_timeout_ms)

    if is_binary(workspace_id) and workspace_id != "" do
      workspace_id
      |> then(&Deps.impl(:workspaces).viewer_ids(&1, resolve_remote?: true))
      |> dispatch_visible_action(workspace, pane_id, action, target,
        opts: opts,
        request_id: request_id,
        timeout: timeout,
        workspace_id: workspace_id
      )
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

        viewer_ids = Deps.impl(:workspaces).viewer_ids(id, resolve_remote?: true)

        for viewer_id <- viewer_ids do
          :ok =
            Phoenix.PubSub.broadcast(
              @pubsub,
              topic(viewer_id),
              {:browser_control, Map.put(payload, "workspace_id", viewer_id)}
            )
        end

        {:ok,
         %{
           status: if(any_viewer_present?(viewer_ids), do: "delivered", else: "no_viewer"),
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
