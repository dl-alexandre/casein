defmodule DevIDE.Terminals.SessionEvents do
  @moduledoc """
  Content-event bus for terminal sessions.

  `DevIDE.Terminals.SessionOwner` broadcasts here whenever a session's
  backend produces live output, stamped with the owner's monotonic content
  generation. This gives consumers other than the attached viewers — agent
  watchers, activity surfaces, scrollback tooling — a push signal for "this
  session's content changed, and this is how fresh it is" without polling
  tmux or attaching to the PTY stream.

  Events are session-scoped (`{workspace_id, sid}`): the owner sees the tmux
  client stream for the whole session, so per-tmux-pane attribution is not
  possible at this layer (it arrives later with OSC 133 command records).
  """

  @pubsub DevIDE.PubSub

  @type event :: %{
          type: :output,
          workspace_id: String.t(),
          sid: String.t(),
          gen: pos_integer()
        }

  @doc "PubSub topic carrying one session's content events."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(workspace_id, sid), do: "terminal_session_events:#{workspace_id}:#{sid}"

  @doc "Subscribes the caller; events arrive as `{:terminal_session_event, event()}`."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id, sid),
    do: Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id, sid))

  @doc """
  Broadcasts a live-output event for the session.

  A `nil` workspace or sid means the owner has no session identity to publish
  under (e.g. agent runners); the event is dropped rather than published on a
  malformed topic.
  """
  @spec broadcast_output(String.t() | nil, String.t() | nil, pos_integer()) :: :ok
  def broadcast_output(workspace_id, sid, gen)
      when is_binary(workspace_id) and is_binary(sid) and is_integer(gen) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(workspace_id, sid),
      {:terminal_session_event, %{type: :output, workspace_id: workspace_id, sid: sid, gen: gen}}
    )
  end

  def broadcast_output(_workspace_id, _sid, _gen), do: :ok

  @doc """
  Broadcast a recovery notice for the session (tmux recreated empty, history
  reseed, template re-apply). Same topic as content events so existing
  watchers can observe without a second subscription.
  """
  @spec broadcast_recovery(String.t(), String.t(), map()) :: :ok
  def broadcast_recovery(workspace_id, sid, notice)
      when is_binary(workspace_id) and is_binary(sid) and is_map(notice) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(workspace_id, sid),
      {:terminal_session_event,
       Map.put(notice, :workspace_id, workspace_id) |> Map.put(:sid, sid)}
    )
  end

  def broadcast_recovery(_, _, _), do: :ok
end
