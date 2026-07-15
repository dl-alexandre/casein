defmodule DevIDE.Panes.Events do
  @moduledoc """
  Generic, type-agnostic pane lifecycle PubSub.

  Every feature-pane registry (previews, files) broadcasts through here so the
  web layer maintains a single `:feature_panes` assign and dispatches render/input
  through `DevIDE.Panes.Pane` callbacks instead of per-type plumbing.

  ## Alias awareness

  Fan-out mirrors the preview broadcasts: an event for `workspace_id` is published
  to `"panes:" <> alias_id` for every id in `WorkspaceAliases.viewer_ids/1`, so
  manager/folder-attached viewers see pane state for the workspaces they alias.
  Subscribers call `subscribe/1` with the workspace id they are attached as; the
  registry-side `broadcast/1` expands aliases.

  ## Message shape

      {:pane_event, %{
        reason: :registered | :updated | :removed | :heartbeat,
        type: :preview | :file,
        pane_id: String.t(),
        workspace_id: String.t(),
        tmux_session: String.t() | nil,
        payload: map()
      }}

  `payload` is the implementation's `render_payload/1` result for the pane (empty
  map on `:removed`). The explicit `:heartbeat` reason lets the web layer refresh a
  registration without treating it as a focus-changing event (preserves the tmux
  focus-churn guard the preview path relies on).
  """

  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases

  @pubsub DevIDE.PubSub
  @topic_prefix "panes:"

  @type reason :: :registered | :updated | :removed | :heartbeat

  @type event :: %{
          reason: reason(),
          type: atom(),
          pane_id: String.t(),
          workspace_id: String.t(),
          tmux_session: String.t() | nil,
          payload: map()
        }

  @doc "Topic for a single (already alias-resolved) workspace id."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc """
  Subscribe the caller to every alias topic `workspace_id` participates in.

  Returns the list of topics subscribed so the caller can unsubscribe later.
  """
  @spec subscribe(String.t()) :: [String.t()]
  def subscribe(workspace_id) when is_binary(workspace_id) do
    for id <- WorkspaceAliases.viewer_ids(workspace_id) do
      topic = topic(id)
      :ok = Phoenix.PubSub.subscribe(@pubsub, topic)
      topic
    end
  end

  @doc "Unsubscribe the caller from a previously subscribed topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Broadcast a pane event, expanding workspace aliases.

  `event` must carry at least `:reason`, `:type`, `:pane_id`, `:workspace_id`;
  `:tmux_session` and `:payload` default to `nil`/`%{}`.
  """
  @spec broadcast(event()) :: :ok
  def broadcast(%{workspace_id: workspace_id} = event) when is_binary(workspace_id) do
    normalized = normalize(event)

    for id <- WorkspaceAliases.viewer_ids(workspace_id) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(id),
        {:pane_event, %{normalized | workspace_id: id}}
      )
    end

    :ok
  end

  defp normalize(event) do
    %{
      reason: Map.fetch!(event, :reason),
      type: Map.fetch!(event, :type),
      pane_id: Map.fetch!(event, :pane_id),
      workspace_id: Map.fetch!(event, :workspace_id),
      tmux_session: Map.get(event, :tmux_session),
      payload: Map.get(event, :payload, %{})
    }
  end
end
