defmodule Casein.Terminals.AgentState.Server do
  @moduledoc false

  use GenServer

  alias Casein.Agents.{Activity, AgentEvents}
  alias Casein.Audit
  alias Casein.Export.Sanitizer
  alias Casein.Runs.AgentLifecycle
  alias Phoenix.PubSub

  @topic_prefix "agent_state:"
  @max_entries 500
  @registered_name :"Elixir.Casein.Terminals.AgentState"
  # How far back the durable timeline is replayed at boot. Rehydration only
  # ever feeds "last reported" provenance (everything here is far beyond the
  # assert/TTL windows), and the panes that need it most are the old ones: a
  # worker whose PR merged a day or two ago and has stood quiet since is the
  # exact reap-gate case (#20022 - %25 fell 1h outside a 24h window). A week
  # of transitions is ~5k rows; the scan stays bounded by the limit either way.
  @rehydrate_window_seconds 7 * 24 * 3600
  @rehydrate_limit 20_000
  @rehydrate_retry_ms 5_000
  @rehydrate_attempts 6

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

  @doc """
  Replay the newest durable `agent.state_changed` row per pane into the live
  map (entries already present win). Runs automatically after start; exposed
  so tests and operators can drive it. Returns the number of panes seeded.
  """
  def rehydrate(server \\ @registered_name), do: GenServer.call(server, :rehydrate)

  # State: `entries` holds live per-pane reports; `evicted` keeps a bounded
  # `{key => %{state: ..., reported_at: ...}}` tombstone for entries dropped by
  # trim/prune, so a re-report of an unchanged state after eviction does not
  # masquerade as a fresh transition and write a spurious durable audit row.
  # The map is process memory: every canary deploy started from nothing, and a
  # pane that had gone quiet before the swap never re-reported, so its history
  # was simply gone (#20022). Seed from the durable timeline once the process
  # is up, off the init path so a slow or not-yet-started Repo cannot block
  # the supervisor.
  @impl true
  def init(_state) do
    {:ok, %{entries: %{}, evicted: %{}, rehydrated_at: nil},
     {:continue, {:rehydrate, @rehydrate_attempts}}}
  end

  @impl true
  def handle_continue({:rehydrate, attempts_left}, state) do
    case rehydrate_entries(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _reason} when attempts_left > 1 ->
        Process.send_after(self(), {:rehydrate, attempts_left - 1}, @rehydrate_retry_ms)
        {:noreply, state}

      {:error, reason} ->
        require Logger
        Logger.warning("agent state rehydration gave up: #{inspect(reason)}")
        {:noreply, state}
    end
  end

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

  def handle_call(:clear, _from, _state),
    do: {:reply, :ok, %{entries: %{}, evicted: %{}, rehydrated_at: nil}}

  def handle_call(:rehydrate, _from, state) do
    before = map_size(state.entries)

    case rehydrate_entries(state) do
      {:ok, state} -> {:reply, {:ok, map_size(state.entries) - before}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:rehydrate, attempts_left}, state) do
    handle_continue({:rehydrate, attempts_left}, state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(
        {:report, workspace_id, tmux_session, pane_id, rstate, message, source, tool,
         transcript_path, agent_session_id, signals_ctx},
        state
      ) do
    key = {tmux_session, pane_id}
    now = DateTime.utc_now()

    previous = Map.get(state.entries, key)
    {kept_path, kept_session} = keep_runtime_meta(previous, transcript_path, agent_session_id)

    entry = %{
      state: rstate,
      message: message,
      source: source,
      tool: tool,
      workspace_id: workspace_id,
      transcript_path: kept_path,
      agent_session_id: kept_session,
      reported_at: now
    }

    case previous do
      %{
        state: ^rstate,
        message: ^message,
        transcript_path: ^kept_path,
        agent_session_id: ^kept_session
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
             transcript_path: kept_path,
             agent_session_id: kept_session
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
          # Lifecycle altitude: Ledger write lives in AgentLifecycle, not here.
          maybe_observe_lifecycle(prior_state, entry, tmux_session, pane_id)
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

  # Only real transitions feed the Run bracket. Identical re-reports are
  # absorbed above, so this stays at lifecycle altitude rather than tool-call.
  defp maybe_observe_lifecycle(prior_state, entry, tmux_session, pane_id)
       when is_binary(entry.workspace_id) do
    if prior_state == nil or prior_state != entry.state do
      AgentLifecycle.observe_state(%{
        workspace_id: entry.workspace_id,
        tmux_session: tmux_session,
        pane_id: pane_id,
        state: entry.state,
        message: entry.message,
        tool: entry.tool,
        agent_session_id: entry.agent_session_id,
        source: entry.source,
        actor_id: "agent"
      })
    end

    :ok
  end

  defp maybe_observe_lifecycle(_prior_state, _entry, _tmux_session, _pane_id), do: :ok

  # Newest durable transition per {session, pane} within the window becomes a
  # `:durable` entry: state and time only (messages are not persisted), no
  # broadcast, no audit — it is a memory, not a new event. Live entries win.
  defp rehydrate_entries(state) do
    since = DateTime.add(DateTime.utc_now(), -@rehydrate_window_seconds, :second)

    rows =
      Casein.Agents.AgentEvents.latest_state_transitions(
        since: since,
        limit: @rehydrate_limit
      )

    entries =
      Enum.reduce(rows, state.entries, fn row, acc ->
        case durable_entry(row) do
          {key, entry} -> Map.put_new(acc, key, entry)
          nil -> acc
        end
      end)

    {:ok, trim_size(%{state | entries: entries, rehydrated_at: DateTime.utc_now()})}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp durable_entry(%{tmux_session_id: session, pane_id: pane} = row)
       when is_binary(session) and session != "" and is_binary(pane) and pane != "" do
    with state when not is_nil(state) <- durable_state(row),
         %DateTime{} = at <- Map.get(row, :occurred_at) do
      {{session, pane},
       %{
         state: state,
         message: nil,
         source: :durable,
         tool: nil,
         workspace_id: Map.get(row, :workspace_id),
         transcript_path: nil,
         agent_session_id: Map.get(row, :agent_session_id),
         reported_at: at
       }}
    else
      _ -> nil
    end
  end

  defp durable_entry(_row), do: nil

  defp durable_state(row) do
    payload = Map.get(row, :payload) || %{}

    case Map.get(payload, "state") || Map.get(row, :status) do
      "working" -> :working
      "blocked" -> :blocked
      "done" -> :done
      "idle" -> :idle
      "errored" -> :errored
      _ -> nil
    end
  end

  defp prior_state(%{state: state}, _tombstone), do: state
  defp prior_state(nil, %{state: state}), do: state
  defp prior_state(nil, nil), do: nil

  defp put_entry(state, key, entry), do: %{state | entries: Map.put(state.entries, key, entry)}

  # A TUI view switch often re-reports state without transcript_path. Nil must
  # not wipe a still-valid pointer; a new agent_session_id does drop the old one.
  defp keep_runtime_meta(previous, transcript_path, agent_session_id) do
    session_id = present(agent_session_id) || previous_value(previous, :agent_session_id)

    path =
      cond do
        present(transcript_path) -> transcript_path
        session_changed?(previous, session_id) -> nil
        true -> previous_value(previous, :transcript_path)
      end

    {path, session_id}
  end

  defp session_changed?(%{agent_session_id: old}, new)
       when is_binary(old) and old != "" and is_binary(new) and new != "",
       do: old != new

  defp session_changed?(_previous, _new), do: false

  defp previous_value(%{} = previous, key), do: present(Map.get(previous, key))
  defp previous_value(_previous, _key), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # No workspace → no durable timeline. Bulk fillers (and any caller that only
  # needs the in-memory map) must not serialize hundreds of AgentEvents /
  # Activity writes on the AgentState GenServer, or a subsequent get/1 times out.
  defp record_transition(prior_state, %{workspace_id: ws} = entry, tmux_session, pane_id)
       when is_binary(ws) and ws != "" do
    if prior_state == nil or prior_state != entry.state do
      append_transition(prior_state, entry, tmux_session, pane_id)
    else
      :ok
    end
  end

  defp record_transition(_prior_state, _entry, _tmux_session, _pane_id), do: :ok

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
