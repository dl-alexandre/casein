defmodule Casein.Terminals.AgentState.Server do
  @moduledoc false

  use GenServer

  alias Casein.Agents.{Activity, AgentEvents}
  alias Casein.Audit
  alias Casein.Export.Sanitizer
  alias Phoenix.PubSub

  @topic_prefix "agent_state:"
  @max_entries 500
  @registered_name :"Elixir.Casein.Terminals.AgentState"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, @registered_name))
  end

  def report(
        workspace_id,
        tmux_session,
        pane_id,
        state,
        message,
        source,
        tool,
        transcript_path,
        agent_session_id
      ) do
    # Causality handoff: the reporter is usually an MCP tool call, so an
    # agent.blocked audit emitted inside the server correlates back to it.
    signals_ctx = Casein.Signals.Context.snapshot()

    GenServer.cast(
      @registered_name,
      {:report, workspace_id, tmux_session, pane_id, state, message, source, tool,
       transcript_path, agent_session_id, signals_ctx}
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

  # State: `entries` holds live per-pane reports; `evicted` keeps a bounded
  # `{key => %{state: ..., reported_at: ...}}` tombstone for entries dropped by
  # trim/prune, so a re-report of an unchanged state after eviction does not
  # masquerade as a fresh transition and write a spurious durable audit row.
  @impl true
  def init(_state), do: {:ok, %{entries: %{}, evicted: %{}}}

  @impl true
  # Not a plain KV store: this GenServer dedupes semantic-state reports (so hook
  # spam does not wake subscribers), computes the freshest live state per session,
  # and PubSub-broadcasts transitions to workspace LiveViews.
  # credo:disable-for-next-line ExSlop.Check.Warning.GenserverAsKvStore
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.entries, key), state}
  end

  def handle_call({:for_session, tmux_session}, _from, state) do
    entries =
      for {{session, pane}, entry} <- state.entries,
          session == tmux_session,
          into: %{},
          do: {pane, entry}

    {:reply, entries, state}
  end

  def handle_call({:freshest, tmux_session, now, max_age_seconds}, _from, state) do
    freshest =
      state.entries
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

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{entries: %{}, evicted: %{}}}

  @impl true
  def handle_cast(
        {:report, workspace_id, tmux_session, pane_id, rstate, message, source, tool,
         transcript_path, agent_session_id, signals_ctx},
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
      agent_session_id: agent_session_id,
      reported_at: now
    }

    case Map.get(state.entries, key) do
      %{
        state: ^rstate,
        message: ^message,
        transcript_path: ^transcript_path,
        agent_session_id: ^agent_session_id
      } = current ->
        # Same state, message, and runtime metadata: refresh freshness silently,
        # never broadcast. This makes high-frequency PreToolUse hooks cheap.
        {:noreply, put_entry(state, key, %{current | reported_at: now})}

      %{state: ^rstate, message: ^message} = current ->
        # State unchanged but runtime metadata may have arrived late — refresh silently.
        {:noreply,
         put_entry(state, key, %{
           current
           | reported_at: now,
             transcript_path: transcript_path,
             agent_session_id: agent_session_id
         })}

      previous ->
        # The last known state survives eviction in the tombstone map, so an
        # evicted pane re-reporting an unchanged state is still a re-report,
        # not a transition.
        prior_state = prior_state(previous, Map.get(state.evicted, key))

        state =
          %{state | entries: Map.put(state.entries, key, entry)}
          |> Map.update!(:evicted, &Map.delete(&1, key))
          |> trim_size()

        broadcast(workspace_id, tmux_session, pane_id, entry)

        Casein.Signals.Context.with_snapshot(signals_ctx, fn ->
          maybe_emit_state_changed(prior_state, entry, tmux_session, pane_id)
          record_transition(prior_state, entry, tmux_session, pane_id)
          maybe_emit_blocked(prior_state, entry, tmux_session, pane_id)
        end)

        {:noreply, state}
    end
  end

  def handle_cast({:prune_session, tmux_session, pane_ids}, state) do
    {pruned, kept} =
      Map.split_with(state.entries, fn {{session, pane}, _entry} ->
        session == tmux_session and not MapSet.member?(pane_ids, pane)
      end)

    {:noreply, %{state | entries: kept, evicted: tombstone(state.evicted, pruned)}}
  end

  # Every real semantic-state transition gets a durable timeline row. The
  # dedupe clauses above absorb identical re-reports while the entry is live,
  # the tombstone map covers re-reports after eviction/prune, and a changed
  # message with an unchanged state is not a transition, so volume stays
  # bounded at actual state flips.
  defp maybe_emit_state_changed(prior_state, entry, tmux_session, pane_id)
       when is_binary(entry.workspace_id) do
    if prior_state == nil or prior_state != entry.state do
      Audit.emit!(%{
        workspace_id: entry.workspace_id,
        actor_id: "agent",
        action: "agent.state_changed",
        source: "agent_state",
        target_type: "tmux_pane",
        target_ref: pane_id,
        metadata: %{
          from: prior_state,
          to: entry.state,
          pane: pane_id,
          tmux_session: tmux_session,
          tool: entry.tool,
          message: sanitize_message(entry.message),
          agent_session_id: entry.agent_session_id
        }
      })
    end

    :ok
  end

  defp maybe_emit_state_changed(_prior_state, _entry, _tmux_session, _pane_id), do: :ok

  # Reports arrive pre-truncated (AgentState.@message_limit); redact before the
  # text lands in a persisted audit row.
  defp sanitize_message(message) when is_binary(message), do: Sanitizer.redact_text(message)
  defp sanitize_message(_message), do: nil

  # Emit a durable audit event only on a *transition* into :blocked, so a
  # re-reported blocked (e.g. a new message) does not re-alert. Alerts.@titles
  # carries "agent.blocked", so this reaches the in-app banner and OS push.
  defp maybe_emit_blocked(prior_state, %{state: :blocked} = entry, tmux_session, pane_id)
       when is_binary(entry.workspace_id) do
    if prior_state != :blocked do
      Audit.emit!(%{
        workspace_id: entry.workspace_id,
        actor_id: "agent",
        action: "agent.blocked",
        target_type: "tmux_pane",
        target_ref: pane_id,
        metadata: %{
          session: tmux_session,
          pane: pane_id,
          message: sanitize_message(entry.message),
          agent_session_id: entry.agent_session_id
        }
      })
    end

    :ok
  end

  defp maybe_emit_blocked(_prior_state, _entry, _tmux_session, _pane_id), do: :ok

  defp prior_state(%{state: state}, _tombstone), do: state
  defp prior_state(nil, %{state: state}), do: state
  defp prior_state(nil, nil), do: nil

  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}

  defp record_transition(prior_state, entry, tmux_session, pane_id) do
    if prior_state == nil or prior_state != entry.state do
      append_transition(prior_state, entry, tmux_session, pane_id)
    else
      :ok
    end
  end

  defp append_transition(prior_state, entry, tmux_session, pane_id) do
    attrs = %{
      workspace_id: entry.workspace_id,
      tmux_session_id: tmux_session,
      pane_id: pane_id,
      agent_session_id: entry.agent_session_id,
      state: entry.state,
      prior_state: prior_state,
      source: entry.source,
      tool: entry.tool,
      message: entry.message
    }

    case AgentEvents.append_state_transition(attrs) do
      {:ok, event, :inserted} ->
        _ =
          Activity.record(%{
            id: event.id,
            workspace_id: event.workspace_id,
            source: :agent_state,
            tool: "agent_state",
            summary: event.summary,
            status: :ok,
            inserted_at: event.occurred_at,
            metadata: %{
              event: "agent_state",
              state: entry.state,
              prior_state: prior_state,
              agent_session_id: entry.agent_session_id,
              session: tmux_session,
              pane: pane_id
            }
          })

        :ok

      _result ->
        :ok
    end
  end

  defp trim_size(state) do
    if map_size(state.entries) <= @max_entries, do: state, else: trim_oldest(state)
  end

  defp trim_oldest(state) do
    {evicted, kept} =
      state.entries
      |> Enum.sort_by(fn {_key, %{reported_at: at}} -> at end, DateTime)
      |> Enum.split(-@max_entries)

    %{state | entries: Map.new(kept), evicted: tombstone(state.evicted, evicted)}
  end

  # Tombstones are state-only (no message) and share the entry cap; when full,
  # the oldest tombstones fall away first.
  defp tombstone(evicted, dropped) do
    dropped
    |> Enum.reduce(evicted, fn {key, %{state: state, reported_at: at}}, acc ->
      Map.put(acc, key, %{state: state, reported_at: at})
    end)
    |> trim_tombstones()
  end

  defp trim_tombstones(evicted) when map_size(evicted) <= @max_entries, do: evicted

  defp trim_tombstones(evicted) do
    evicted
    |> Enum.sort_by(fn {_key, %{reported_at: at}} -> at end, DateTime)
    |> Enum.take(-@max_entries)
    |> Map.new()
  end

  defp broadcast(workspace_id, tmux_session, pane_id, entry) when is_binary(workspace_id) do
    PubSub.broadcast(
      Casein.PubSub,
      @topic_prefix <> workspace_id,
      {:agent_state_updated, tmux_session, pane_id, entry}
    )
  end

  defp broadcast(_workspace_id, _tmux_session, _pane_id, _entry), do: :ok
end
