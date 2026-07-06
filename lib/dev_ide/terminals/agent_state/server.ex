defmodule DevIDE.Terminals.AgentState.Server do
  @moduledoc false

  use GenServer

  alias DevIDE.Audit
  alias Phoenix.PubSub

  @topic_prefix "agent_state:"
  @max_entries 500
  @registered_name :"Elixir.DevIDE.Terminals.AgentState"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @registered_name))
  end

  def report(workspace_id, tmux_session, pane_id, state, message, source, tool, transcript_path) do
    # Causality handoff: the reporter is usually an MCP tool call, so an
    # agent.blocked audit emitted inside the server correlates back to it.
    signals_ctx = DevIDE.Signals.Context.snapshot()

    GenServer.cast(
      @registered_name,
      {:report, workspace_id, tmux_session, pane_id, state, message, source, tool,
       transcript_path, signals_ctx}
    )
  end

  def get(tmux_session, pane_id) do
    GenServer.call(@registered_name, {:get, {tmux_session, pane_id}})
  end

  def for_session(tmux_session) do
    GenServer.call(@registered_name, {:for_session, tmux_session})
  end

  def freshest(tmux_session, now, max_age_seconds) do
    GenServer.call(@registered_name, {:freshest, tmux_session, now, max_age_seconds})
  end

  def prune_session(tmux_session, pane_ids) do
    GenServer.cast(@registered_name, {:prune_session, tmux_session, MapSet.new(pane_ids)})
  end

  def clear, do: GenServer.call(@registered_name, :clear)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  # Not a plain KV store: this GenServer dedupes semantic-state reports (so hook
  # spam does not wake subscribers), computes the freshest live state per session,
  # and PubSub-broadcasts transitions to workspace LiveViews.
  # credo:disable-for-next-line ExSlop.Check.Warning.GenserverAsKvStore
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call({:for_session, tmux_session}, _from, state) do
    entries =
      for {{session, pane}, entry} <- state, session == tmux_session, into: %{}, do: {pane, entry}

    {:reply, entries, state}
  end

  def handle_call({:freshest, tmux_session, now, max_age_seconds}, _from, state) do
    freshest =
      state
      |> Enum.filter(fn {{session, _pane}, entry} ->
        session == tmux_session and
          DateTime.diff(now, entry.reported_at, :second) <= max_age_seconds
      end)
      |> Enum.max_by(
        fn {_key, entry} -> DateTime.to_unix(entry.reported_at, :microsecond) end,
        fn -> nil end
      )

    reply =
      case freshest do
        {_key, entry} -> entry.state
        nil -> nil
      end

    {:reply, reply, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast(
        {:report, workspace_id, tmux_session, pane_id, rstate, message, source, tool,
         transcript_path, signals_ctx},
        state
      ) do
    key = {tmux_session, pane_id}
    now = DateTime.utc_now()

    entry = %{
      state: rstate,
      message: message,
      source: source,
      tool: tool,
      workspace_id: workspace_id,
      transcript_path: transcript_path,
      reported_at: now
    }

    case Map.get(state, key) do
      %{state: ^rstate, message: ^message, transcript_path: ^transcript_path} = current ->
        # Same state+message+path: refresh freshness silently, never broadcast. This is
        # what makes high-frequency PreToolUse hooks cheap for subscribers.
        {:noreply, Map.put(state, key, %{current | reported_at: now})}

      %{state: ^rstate, message: ^message} = current ->
        # State unchanged but transcript_path may have arrived late — refresh silently.
        {:noreply,
         Map.put(state, key, %{current | reported_at: now, transcript_path: transcript_path})}

      previous ->
        state = state |> Map.put(key, entry) |> trim_size()
        broadcast(workspace_id, tmux_session, pane_id, entry)

        DevIDE.Signals.Context.with_snapshot(signals_ctx, fn ->
          maybe_emit_blocked(previous, entry, tmux_session, pane_id)
        end)

        {:noreply, state}
    end
  end

  def handle_cast({:prune_session, tmux_session, pane_ids}, state) do
    pruned =
      Map.filter(state, fn {{session, pane}, _entry} ->
        session != tmux_session or MapSet.member?(pane_ids, pane)
      end)

    {:noreply, pruned}
  end

  # Emit a durable audit event only on a *transition* into :blocked, so a
  # re-reported blocked (e.g. a new message) does not re-alert. Alerts.@titles
  # carries "agent.blocked", so this reaches the in-app banner and OS push.
  defp maybe_emit_blocked(previous, %{state: :blocked} = entry, tmux_session, pane_id)
       when is_binary(entry.workspace_id) do
    if previous == nil or previous.state != :blocked do
      Audit.emit!(%{
        workspace_id: entry.workspace_id,
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: pane_id,
        metadata: %{session: tmux_session, pane: pane_id, message: entry.message}
      })
    end

    :ok
  end

  defp maybe_emit_blocked(_previous, _entry, _tmux_session, _pane_id), do: :ok

  defp trim_size(state) do
    if map_size(state) <= @max_entries, do: state, else: trim_oldest(state)
  end

  defp trim_oldest(state) do
    state
    |> Enum.sort_by(fn {_key, %{reported_at: at}} -> at end, DateTime)
    |> Enum.take(-@max_entries)
    |> Map.new()
  end

  defp broadcast(workspace_id, tmux_session, pane_id, entry) when is_binary(workspace_id) do
    PubSub.broadcast(
      DevIde.PubSub,
      @topic_prefix <> workspace_id,
      {:agent_state_updated, tmux_session, pane_id, entry}
    )
  end

  defp broadcast(_workspace_id, _tmux_session, _pane_id, _entry), do: :ok
end
