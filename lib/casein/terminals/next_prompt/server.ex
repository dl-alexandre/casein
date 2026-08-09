defmodule Casein.Terminals.NextPrompt.Server do
  @moduledoc false

  use GenServer

  alias Casein.Terminals.AgentState
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.NextPrompt.Delivery
  alias Phoenix.PubSub

  @registered_name :"Elixir.Casein.Terminals.NextPrompt"
  @max_entries 200
  @max_attempts 2
  @sweep_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(opts, :name, @registered_name))
  end

  def set(tmux_session, pane_id, text, opts) do
    GenServer.call(@registered_name, {:set, tmux_session, pane_id, text, opts})
  end

  def get(tmux_session, pane_id) do
    GenServer.call(@registered_name, {:get, {tmux_session, pane_id}})
  end

  def clear(tmux_session, pane_id, coalesce_key) do
    GenServer.call(@registered_name, {:clear, {tmux_session, pane_id}, coalesce_key})
  end

  def for_session(tmux_session) do
    GenServer.call(@registered_name, {:for_session, tmux_session})
  end

  def prune_session(tmux_session, pane_ids) do
    GenServer.cast(@registered_name, {:prune_session, tmux_session, MapSet.new(pane_ids)})
  end

  def clear_all, do: GenServer.call(@registered_name, :clear_all)

  @impl true
  def init(opts) do
    schedule_sweep()

    {:ok,
     %{
       entries: %{},
       workspaces: %{},
       subscribed: MapSet.new(),
       revision: 0,
       deliver: Keyword.get(opts, :deliver)
     }}
  end

  @impl true
  # Not a KV store: this GenServer owns the single-slot coalescing rule, the
  # per-workspace agent_state subscriptions that drive delivery, and the
  # expiry sweep. Reads exist so callers can render what is pending.
  # credo:disable-for-next-line ExSlop.Check.Warning.GenserverAsKvStore
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state.entries, key), state}

  def handle_call({:for_session, tmux_session}, _from, state) do
    entries =
      for {{session, pane}, entry} <- state.entries,
          session == tmux_session,
          into: %{},
          do: {pane, entry}

    {:reply, entries, state}
  end

  def handle_call({:clear, key, coalesce_key}, _from, state) do
    case Map.get(state.entries, key) do
      nil ->
        {:reply, nil, state}

      %{coalesce_key: pending_key} = entry ->
        if is_nil(coalesce_key) or pending_key == coalesce_key do
          {:reply, entry, drop(state, key)}
        else
          {:reply, nil, state}
        end
    end
  end

  def handle_call({:set, tmux_session, pane_id, text, opts}, _from, state) do
    key = {tmux_session, pane_id}
    now = DateTime.utc_now()
    previous = Map.get(state.entries, key)
    state = %{state | revision: state.revision + 1}

    entry = build_entry(tmux_session, pane_id, text, opts, now, state.revision)

    if already_at_target?(entry, Keyword.get(opts, :current_state)) do
      # The edge the caller asked for has already arrived. Parking the message
      # would wait for a transition that may not come for hours.
      state = drop(state, key)
      deliver(state, entry, :immediate)
      {:reply, {:ok, %{status: :delivered, entry: entry, replaced: previous}}, state}
    else
      state = state |> put_entry(key, entry) |> subscribe(entry.workspace_id) |> trim()
      {:reply, {:ok, %{status: :pending, entry: entry, replaced: previous}}, state}
    end
  end

  def handle_call(:clear_all, _from, state) do
    Enum.each(state.subscribed, &unsubscribe/1)
    {:reply, :ok, %{state | entries: %{}, workspaces: %{}, subscribed: MapSet.new()}}
  end

  @impl true
  def handle_cast({:prune_session, tmux_session, pane_ids}, state) do
    dead =
      for {{session, pane} = key, _entry} <- state.entries,
          session == tmux_session,
          not MapSet.member?(pane_ids, pane),
          do: key

    {:noreply, Enum.reduce(dead, state, &drop(&2, &1))}
  end

  @impl true
  def handle_info({:agent_state_updated, tmux_session, pane_id, report}, state) do
    key = {tmux_session, pane_id}

    case Map.get(state.entries, key) do
      nil -> {:noreply, state}
      entry -> {:noreply, evaluate(state, key, entry, report)}
    end
  end

  # A delivery attempt that could not be confirmed goes back in the slot so the
  # pane's next qualifying edge retries it — unless the caller has since staged
  # a newer message, which supersedes it outright.
  def handle_info({:next_prompt_delivery, key, entry, :error}, state) do
    cond do
      Map.has_key?(state.entries, key) -> {:noreply, state}
      entry.attempts >= @max_attempts -> {:noreply, state}
      true -> {:noreply, state |> put_entry(key, entry) |> subscribe(entry.workspace_id)}
    end
  end

  def handle_info({:next_prompt_delivery, _key, _entry, :ok}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    now = DateTime.utc_now()

    expired =
      for {key, entry} <- state.entries, NextPrompt.expired?(entry, now), do: key

    schedule_sweep()
    {:noreply, Enum.reduce(expired, state, &drop(&2, &1))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp evaluate(state, key, entry, report) do
    now = DateTime.utc_now()

    cond do
      NextPrompt.expired?(entry, now) ->
        drop(state, key)

      NextPrompt.superseded?(entry, report) ->
        # The runtime restarted under this pane. The message was addressed to an
        # agent that no longer exists; delivering it now would drop mid-turn
        # context on a stranger.
        Delivery.record_dropped(entry, :agent_session_changed)
        drop(state, key)

      NextPrompt.deliverable?(entry, report, now) ->
        state = drop(state, key)
        deliver(state, entry, report.state)
        state

      true ->
        state
    end
  end

  # Delivery pastes into tmux and then polls the pane to confirm the submit
  # landed, which can take seconds. Running that inline would stall every other
  # pane's state updates behind one slow TUI, so it runs in a task and reports
  # back. The entry is removed from the slot *before* the task starts, so a
  # duplicate state edge cannot deliver it twice.
  defp deliver(state, entry, trigger) do
    key = {entry.tmux_session, entry.pane_id}
    entry = %{entry | attempts: entry.attempts + 1}
    server = self()
    deliver_fun = state.deliver || configured_deliver_fun()

    spawn_delivery(fn ->
      outcome =
        case deliver_fun.(entry, trigger) do
          {:ok, _result} -> :ok
          _error -> :error
        end

      send(server, {:next_prompt_delivery, key, entry, outcome})
    end)
  end

  # The server is supervised without options, so the seam tests need is an
  # application-env override rather than a start_link argument.
  defp configured_deliver_fun do
    case Application.get_env(:casein, :next_prompt_deliver) do
      fun when is_function(fun, 2) -> fun
      _ -> &Delivery.deliver/2
    end
  end

  defp spawn_delivery(fun) do
    case Process.whereis(Casein.TaskSupervisor) do
      nil -> spawn(fun)
      _supervisor -> Task.Supervisor.start_child(Casein.TaskSupervisor, fun)
    end
  end

  defp already_at_target?(_entry, nil), do: false

  defp already_at_target?(entry, current_state) do
    current_state in NextPrompt.target_states(entry.deliver_when)
  end

  defp build_entry(tmux_session, pane_id, text, opts, now, revision) do
    %{
      workspace_id: non_empty(Keyword.get(opts, :workspace_id)),
      tmux_session: tmux_session,
      pane_id: pane_id,
      text: text,
      deliver_when: Keyword.fetch!(opts, :deliver_when),
      coalesce_key: NextPrompt.normalize_coalesce_key(Keyword.get(opts, :coalesce_key)),
      agent_session_id: non_empty(Keyword.get(opts, :agent_session_id)),
      set_by: non_empty(Keyword.get(opts, :set_by)),
      set_at: now,
      expires_at: Keyword.get(opts, :expires_at) || NextPrompt.expires_at(nil, now),
      attempts: 0,
      revision: revision
    }
  end

  defp put_entry(state, key, entry) do
    previous = Map.get(state.entries, key)

    workspaces =
      state.workspaces
      |> bump(previous && previous.workspace_id, -1)
      |> bump(entry.workspace_id, +1)

    %{state | entries: Map.put(state.entries, key, entry), workspaces: workspaces}
  end

  defp drop(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        workspaces = bump(state.workspaces, entry.workspace_id, -1)
        state = %{state | entries: entries, workspaces: workspaces}
        maybe_unsubscribe(state, entry.workspace_id)
    end
  end

  # Delivery only ever fires from an `agent_state` broadcast, and those are
  # published per workspace. Subscribing lazily keeps a box with hundreds of
  # workspaces from fanning every state report into this process for nothing.
  # Phoenix.PubSub allows duplicate registrations for one pid, so this
  # subscribes strictly on the 0 → 1 edge; subscribing per `set/4` would
  # deliver every state report N times over.
  defp subscribe(state, nil), do: state

  defp subscribe(state, workspace_id) do
    if Map.get(state.workspaces, workspace_id, 0) > 0 and
         not MapSet.member?(state.subscribed, workspace_id) do
      PubSub.subscribe(Casein.PubSub, AgentState.topic(workspace_id))
      %{state | subscribed: MapSet.put(state.subscribed, workspace_id)}
    else
      state
    end
  end

  defp maybe_unsubscribe(state, nil), do: state

  defp maybe_unsubscribe(state, workspace_id) do
    if Map.get(state.workspaces, workspace_id, 0) <= 0 do
      unsubscribe(workspace_id)

      %{
        state
        | workspaces: Map.delete(state.workspaces, workspace_id),
          subscribed: MapSet.delete(state.subscribed, workspace_id)
      }
    else
      state
    end
  end

  defp unsubscribe(workspace_id) do
    PubSub.unsubscribe(Casein.PubSub, AgentState.topic(workspace_id))
  rescue
    _ -> :ok
  end

  defp bump(workspaces, nil, _delta), do: workspaces

  defp bump(workspaces, workspace_id, delta) do
    Map.update(workspaces, workspace_id, max(delta, 0), &max(&1 + delta, 0))
  end

  # A hard cap so a runaway orchestrator cannot grow this map without bound.
  # The oldest entries go first; an operator message that has been waiting
  # longest is also the one most likely to be stale.
  defp trim(state) when map_size(state.entries) <= @max_entries, do: state

  defp trim(state) do
    state.entries
    |> Enum.sort_by(fn {_key, %{set_at: at}} -> at end, DateTime)
    |> Enum.take(map_size(state.entries) - @max_entries)
    |> Enum.reduce(state, fn {key, _entry}, acc -> drop(acc, key) end)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty(_value), do: nil
end
