defmodule TmuxCtl.Topology.Watcher do
  @moduledoc """
  GenServer that polls tmux topology and broadcasts changes over PubSub.

  Inject `pubsub`, `registry`, `supervisor`, `broadcast_tag`, `tmux_resolver`,
  and optional `on_session_terminated` via start options. Timing defaults come
  from `config :tmux_ctl` keys `:topology_refresh_ms`, `:topology_idle_stop_ms`,
  and `:topology_topic_prefix`.

  Optional `:event_source` (`{module, arg}`) switches the *trigger* from the
  fast poll to control-mode events while keeping snapshot/version/broadcast
  machinery byte-identical. Event-triggered refreshes are coalesced with a
  min-interval equal to `:refresh_ms` (the old poll period). A slower
  `:reconcile_ms` timer (default 10s) remains as the correctness backbone.
  Listener down / flag off falls back to the original poll cadence automatically.
  """

  use GenServer

  alias TmuxCtl.Topology

  @default_refresh_ms 300
  @default_reconcile_ms 10_000
  @default_topic_prefix "terminal_topology:"
  @retry_event_subscribe_ms 5_000

  @type on_session_terminated :: (map(), atom() -> :ok)

  @doc "Return the current window topology for a session via the watcher."
  @spec get(String.t(), keyword()) :: Topology.t()
  def get(session, opts \\ []) when is_binary(session) do
    if Keyword.has_key?(opts, :tmux) do
      snapshot(session, opts)
    else
      case ensure_started(session, opts) do
        {:ok, pid} -> call_or_snapshot(pid, :get, session, opts)
        {:error, _reason} -> snapshot(session, opts)
      end
    end
  end

  @doc "Start the topology watcher for a tmux session if needed."
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session, opts \\ []) when is_binary(session) do
    registry = Keyword.fetch!(opts, :registry)

    case Registry.lookup(registry, session) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        supervisor = Keyword.fetch!(opts, :supervisor)

        case DynamicSupervisor.start_child(supervisor, {__MODULE__, {session, opts}}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  @doc "Request an immediate refresh from the topology watcher."
  @spec refresh(String.t(), keyword()) :: :ok | {:error, term()}
  def refresh(session, opts \\ []) when is_binary(session) do
    case ensure_started(session, opts) do
      {:ok, pid} ->
        GenServer.cast(pid, :refresh)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Update polling options for a running topology watcher."
  @spec configure(String.t(), keyword()) :: :ok | {:error, term()}
  def configure(session, opts) when is_binary(session) and is_list(opts) do
    case ensure_started(session, opts) do
      {:ok, pid} -> GenServer.call(pid, {:configure, opts})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Refresh the watcher immediately and return the updated topology."
  @spec refresh_now(String.t(), keyword()) :: Topology.t()
  def refresh_now(session, opts \\ []) when is_binary(session) do
    if Keyword.has_key?(opts, :tmux) do
      snapshot(session, opts)
    else
      case ensure_started(session, opts) do
        {:ok, pid} -> call_or_snapshot(pid, :refresh, session, opts)
        {:error, _reason} -> snapshot(session, opts)
      end
    end
  end

  @doc "Subscribe the caller to topology updates for a tmux session."
  @spec subscribe(String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(session, opts \\ []) when is_binary(session) do
    pubsub = Keyword.get_lazy(opts, :pubsub, &pubsub/0)
    Phoenix.PubSub.subscribe(pubsub, topic(session, opts))
  end

  @doc "Register the caller as a live consumer of the session's watcher."
  @spec watch(String.t(), keyword()) :: :ok | {:error, term()}
  def watch(session, opts \\ []) when is_binary(session) do
    case ensure_started(session, opts) do
      {:ok, pid} ->
        GenServer.call(pid, {:watch, self()})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deregister the caller as a consumer of the session's watcher."
  @spec unwatch(String.t(), keyword()) :: :ok
  def unwatch(session, opts \\ []) when is_binary(session) do
    registry = Keyword.fetch!(opts, :registry)

    case Registry.lookup(registry, session) do
      [{pid, _}] ->
        GenServer.call(pid, {:unwatch, self()})
        :ok

      [] ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Moves the caller's topology subscription from `old_session` to `new_session`.

  The returned `:pid` is the watcher serving the subscription (nil when it could
  not be reached). Callers should monitor it: `{:watch, self()}` registrations do
  not survive a watcher restart, and a restarted watcher with no registered
  watchers idle-stops — so a subscriber that does not re-register after a crash
  goes permanently, silently stale.
  """
  @spec switch_subscription(String.t() | nil, String.t(), keyword()) ::
          {:ok,
           %{
             session: String.t(),
             generation: pos_integer() | nil,
             topology: Topology.t(),
             pid: pid() | nil
           }}
  def switch_subscription(old_session, new_session, opts \\ []) when is_binary(new_session) do
    {read, opts} = Keyword.pop(opts, :read, :refresh)
    pubsub = Keyword.get_lazy(opts, :pubsub, &pubsub/0)

    if is_binary(old_session) and old_session != new_session do
      Phoenix.PubSub.unsubscribe(pubsub, topic(old_session, opts))
      unwatch(old_session, opts)
    end

    Phoenix.PubSub.unsubscribe(pubsub, topic(new_session, opts))
    :ok = subscribe(new_session, opts)

    case ensure_started(new_session, opts) do
      {:ok, pid} ->
        try do
          :ok = GenServer.call(pid, {:watch, self()})
          topology = GenServer.call(pid, read)

          {:ok,
           %{
             session: new_session,
             generation: Map.get(topology, :generation),
             topology: topology,
             pid: pid
           }}
        catch
          :exit, _ ->
            {:ok,
             %{
               session: new_session,
               generation: nil,
               topology: snapshot(new_session, opts),
               pid: nil
             }}
        end

      {:error, _reason} ->
        {:ok,
         %{
           session: new_session,
           generation: nil,
           topology: snapshot(new_session, opts),
           pid: nil
         }}
    end
  end

  @doc "Return the PubSub topic used for a tmux session."
  @spec topic(String.t(), keyword()) :: String.t()
  def topic(session, opts \\ []) when is_binary(session) do
    prefix = Keyword.get(opts, :topic_prefix, topic_prefix())
    prefix <> session
  end

  def child_spec({session, opts}) do
    %{
      id: {__MODULE__, session},
      start: {__MODULE__, :start_link, [{session, opts}]},
      restart: :transient
    }
  end

  @spec start_link({String.t(), keyword()}) :: GenServer.on_start()
  def start_link({session, opts}) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via_tuple(session, opts))
  end

  @impl true
  def init({session, opts}) do
    tmux_opt = Keyword.get(opts, :tmux)
    refresh_ms = normalize_refresh_ms(Keyword.get(opts, :refresh_ms, refresh_ms(opts)))

    reconcile_ms =
      normalize_refresh_ms(Keyword.get(opts, :reconcile_ms, reconcile_ms(opts)))

    polling_enabled? = Keyword.get(opts, :enabled, true)
    workspace_id = Keyword.get(opts, :workspace_id)
    generation = System.unique_integer([:positive, :monotonic])
    event_source = Keyword.get(opts, :event_source)

    topology_transform = topology_transform(opts)

    topology =
      session
      |> Topology.snapshot(tmux: tmux_opt || tmux_resolver(opts).())
      |> Map.put(:generation, generation)

    topology = topology_transform.(topology)

    now_ms = System.monotonic_time(:millisecond)

    state = %{
      session: session,
      workspace_id: workspace_id,
      tmux_opt: tmux_opt,
      tmux_resolver: tmux_resolver(opts),
      refresh_ms: refresh_ms,
      reconcile_ms: reconcile_ms,
      polling_enabled?: polling_enabled?,
      generation: generation,
      topology: topology,
      topology_transform: topology_transform,
      timer_ref: nil,
      watchers: %{},
      idle_stop_ms: idle_stop_ms(opts),
      idle_timer: nil,
      pubsub: Keyword.fetch!(opts, :pubsub),
      broadcast_tag: Keyword.get(opts, :broadcast_tag, __MODULE__),
      topic_prefix: Keyword.get(opts, :topic_prefix, topic_prefix()),
      on_session_terminated: Keyword.get(opts, :on_session_terminated, fn _, _ -> :ok end),
      event_source: event_source,
      event_mode?: false,
      listener_pid: nil,
      listener_ref: nil,
      last_refresh_ms: now_ms,
      pending_refresh_ref: nil,
      retry_subscribe_ref: nil,
      # Events absorbed by coalescing since the last event/coalesced snapshot
      # (Slice 3 observability — events_absorbed measurement).
      events_absorbed: 0
    }

    state =
      state
      |> maybe_subscribe_event_source()
      |> schedule_refresh()
      |> schedule_idle_stop()

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.topology, state}

  def handle_call({:watch, pid}, _from, state) do
    state =
      if Map.has_key?(state.watchers, pid) do
        state
      else
        ref = Process.monitor(pid)
        cancel_idle_timer(%{state | watchers: Map.put(state.watchers, pid, ref)})
      end

    {:reply, :ok, state}
  end

  def handle_call({:unwatch, pid}, _from, state) do
    {:reply, :ok, drop_watcher(state, pid)}
  end

  def handle_call(:refresh, _from, state) do
    case refresh_state(state, :manual) do
      {:ok, state} ->
        {:reply, state.topology, state}

      {:terminated, state} ->
        {:stop, :normal, state.topology, state}
    end
  end

  def handle_call({:configure, opts}, _from, state) do
    state =
      state
      |> cancel_refresh_timer()
      |> Map.put(
        :refresh_ms,
        normalize_refresh_ms(Keyword.get(opts, :refresh_ms, state.refresh_ms))
      )
      |> Map.put(
        :reconcile_ms,
        normalize_refresh_ms(Keyword.get(opts, :reconcile_ms, state.reconcile_ms))
      )
      |> Map.put(:polling_enabled?, Keyword.get(opts, :enabled, state.polling_enabled?))
      |> maybe_put_workspace_id(Keyword.get(opts, :workspace_id))
      |> schedule_refresh()

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    case refresh_state(state, :manual) do
      {:ok, state} -> {:noreply, state}
      {:terminated, state} -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    source = if state.event_mode?, do: :reconcile, else: :poll_fallback

    case refresh_state(state, source) do
      {:ok, state} ->
        {:noreply, schedule_refresh(state)}

      {:terminated, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({TmuxCtl.Events, {:tmux_event, _event}}, state) do
    case maybe_event_refresh(state) do
      {:ok, state} -> {:noreply, state}
      {:terminated, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({TmuxCtl.Events, {:listener_down, _label}}, state) do
    {:noreply, enter_poll_fallback(state)}
  end

  def handle_info({TmuxCtl.Events, {:listener_up, _label}}, %{event_mode?: true} = state) do
    # Already in event mode: a duplicate listener_up (e.g. queued broadcasts
    # around a reconnect) must not trigger another uncoalesced snapshot.
    {:noreply, state}
  end

  def handle_info({TmuxCtl.Events, {:listener_up, _label}}, state) do
    case enter_event_mode(state) do
      {:ok, state} -> {:noreply, state}
      {:terminated, state} -> {:stop, :normal, state}
    end
  end

  def handle_info(:coalesced_refresh, state) do
    state = %{state | pending_refresh_ref: nil}

    case refresh_state(state, :event) do
      {:ok, state} -> {:noreply, state}
      {:terminated, state} -> {:stop, :normal, state}
    end
  end

  def handle_info(:retry_event_subscribe, state) do
    state = %{state | retry_subscribe_ref: nil}

    cond do
      is_nil(state.event_source) or state.event_mode? ->
        {:noreply, state}

      true ->
        # Drop any stale monitor before re-subscribing.
        state = demonitor_listener(state)
        state = maybe_subscribe_event_source(state)

        if state.event_mode? do
          case enter_event_mode(state) do
            {:ok, state} -> {:noreply, state}
            {:terminated, state} -> {:stop, :normal, state}
          end
        else
          {:noreply, schedule_retry_subscribe(state)}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{listener_ref: ref} = state)
      when not is_nil(ref) do
    state = %{state | listener_ref: nil, listener_pid: nil}
    {:noreply, enter_poll_fallback(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_watcher(state, pid)}
  end

  def handle_info(:idle_stop, state) do
    if map_size(state.watchers) == 0 do
      {:stop, :normal, %{state | idle_timer: nil}}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  defp call_or_snapshot(pid, request, session, opts) do
    GenServer.call(pid, request)
  catch
    :exit, _ -> snapshot(session, opts)
  end

  defp snapshot(session, opts) do
    topology = Topology.snapshot(session, snapshot_opts(opts))
    topology_transform(opts).(topology)
  end

  defp snapshot_opts(opts) do
    Keyword.put_new_lazy(opts, :tmux, fn -> tmux_resolver(opts).() end)
  end

  defp topology_transform(opts) do
    Keyword.get(opts, :topology_transform, fn topology -> topology end)
  end

  defp refresh_state(state, source) do
    adapter = state.tmux_opt || state.tmux_resolver.()

    topology =
      state.session
      |> Topology.snapshot(tmux: adapter)
      |> Map.put(:generation, state.generation)

    topology = state.topology_transform.(topology)
    now_ms = System.monotonic_time(:millisecond)
    events_absorbed = Map.get(state, :events_absorbed, 0)
    emit_refresh_telemetry(state, source, events_absorbed)

    if topology.windows == [] and topology.panes == [] do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.session, topic_prefix: state.topic_prefix),
        {state.broadcast_tag,
         {:session_terminated,
          %{session: state.session, generation: state.generation, reason: :session_not_alive}}}
      )

      state.on_session_terminated.(state, :session_not_alive)

      {:terminated, cancel_refresh_timer(%{state | last_refresh_ms: now_ms, events_absorbed: 0})}
    else
      if topology.version != state.topology.version do
        Phoenix.PubSub.broadcast(
          state.pubsub,
          topic(state.session, topic_prefix: state.topic_prefix),
          {state.broadcast_tag, {:updated, topology}}
        )
      end

      {:ok, %{state | topology: topology, last_refresh_ms: now_ms, events_absorbed: 0}}
    end
  end

  # Events are triggers only — rate-capped at the old poll period so storms
  # can never exceed today's subprocess load.
  defp maybe_event_refresh(%{event_mode?: false} = state), do: {:ok, state}

  defp maybe_event_refresh(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_refresh_ms
    min_interval = state.refresh_ms
    # Count every event that reaches the coalescer, including the one that
    # triggers a snapshot (absorbed=1 on immediate path; N when coalesced).
    state = %{state | events_absorbed: Map.get(state, :events_absorbed, 0) + 1}

    cond do
      elapsed >= min_interval and is_nil(state.pending_refresh_ref) ->
        refresh_state(state, :event)

      is_nil(state.pending_refresh_ref) ->
        delay = max(min_interval - elapsed, 0)
        ref = Process.send_after(self(), :coalesced_refresh, delay)
        {:ok, %{state | pending_refresh_ref: ref}}

      true ->
        {:ok, state}
    end
  end

  defp emit_refresh_telemetry(state, source, events_absorbed)
       when source in [:event, :reconcile, :poll_fallback, :manual] do
    :telemetry.execute(
      [:tmux_ctl, :topology, :watcher, :refresh],
      %{count: 1, events_absorbed: events_absorbed},
      %{source: source, session: state.session, event_mode?: state.event_mode?}
    )
  end

  defp emit_refresh_telemetry(_state, _source, _events_absorbed), do: :ok

  defp maybe_subscribe_event_source(%{event_source: nil} = state), do: state

  defp maybe_subscribe_event_source(%{event_source: {mod, arg}} = state) do
    case mod.subscribe(arg, self()) do
      {:ok, %{listener: listener, connected?: connected?}} when is_pid(listener) ->
        ref = Process.monitor(listener)

        %{
          state
          | event_mode?: connected?,
            listener_pid: listener,
            listener_ref: ref
        }

      {:ok, %{listener: listener}} when is_pid(listener) ->
        ref = Process.monitor(listener)

        %{
          state
          | event_mode?: true,
            listener_pid: listener,
            listener_ref: ref
        }

      {:error, :unavailable} ->
        schedule_retry_subscribe(%{
          state
          | event_mode?: false,
            listener_pid: nil,
            listener_ref: nil
        })

      _other ->
        schedule_retry_subscribe(%{
          state
          | event_mode?: false,
            listener_pid: nil,
            listener_ref: nil
        })
    end
  end

  defp maybe_subscribe_event_source(state), do: state

  defp enter_event_mode(state) do
    state =
      state
      |> cancel_retry_subscribe()
      |> cancel_pending_refresh()
      |> Map.put(:event_mode?, true)
      |> cancel_refresh_timer()

    # Snapshot-then-listen after listener_up / successful resubscribe — same
    # path as a reconcile tick (state unknown; no event replay).
    case refresh_state(state, :reconcile) do
      {:ok, state} -> {:ok, schedule_refresh(state)}
      {:terminated, state} -> {:terminated, state}
    end
  end

  defp enter_poll_fallback(state) do
    state
    |> Map.put(:event_mode?, false)
    |> cancel_pending_refresh()
    |> cancel_refresh_timer()
    |> schedule_refresh()
    |> schedule_retry_subscribe()
  end

  defp schedule_refresh(%{polling_enabled?: false} = state), do: %{state | timer_ref: nil}

  defp schedule_refresh(state) do
    period = if state.event_mode?, do: state.reconcile_ms, else: state.refresh_ms
    timer_ref = Process.send_after(self(), :refresh, period)
    %{state | timer_ref: timer_ref}
  end

  defp cancel_refresh_timer(%{timer_ref: nil} = state), do: state

  defp cancel_refresh_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp cancel_pending_refresh(%{pending_refresh_ref: nil} = state), do: state

  defp cancel_pending_refresh(%{pending_refresh_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | pending_refresh_ref: nil}
  end

  defp schedule_retry_subscribe(%{event_source: nil} = state), do: state

  defp schedule_retry_subscribe(%{retry_subscribe_ref: ref} = state) when not is_nil(ref) do
    state
  end

  defp schedule_retry_subscribe(state) do
    ref = Process.send_after(self(), :retry_event_subscribe, @retry_event_subscribe_ms)
    %{state | retry_subscribe_ref: ref}
  end

  defp cancel_retry_subscribe(%{retry_subscribe_ref: nil} = state), do: state

  defp cancel_retry_subscribe(%{retry_subscribe_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | retry_subscribe_ref: nil}
  end

  defp demonitor_listener(%{listener_ref: nil} = state), do: state

  defp demonitor_listener(%{listener_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | listener_ref: nil, listener_pid: nil}
  end

  defp drop_watcher(state, pid) do
    case Map.pop(state.watchers, pid) do
      {nil, _watchers} ->
        state

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | watchers: watchers}
        if map_size(watchers) == 0, do: schedule_idle_stop(state), else: state
    end
  end

  defp schedule_idle_stop(%{idle_timer: nil} = state) do
    %{state | idle_timer: Process.send_after(self(), :idle_stop, state.idle_stop_ms)}
  end

  defp schedule_idle_stop(state), do: state

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: idle_timer} = state) do
    Process.cancel_timer(idle_timer)
    %{state | idle_timer: nil}
  end

  defp idle_stop_ms(opts) do
    Keyword.get(
      opts,
      :idle_stop_ms,
      Application.get_env(:tmux_ctl, :topology_idle_stop_ms, 60_000)
    )
  end

  defp maybe_put_workspace_id(state, nil), do: state
  defp maybe_put_workspace_id(state, ""), do: state
  defp maybe_put_workspace_id(state, workspace_id), do: %{state | workspace_id: workspace_id}

  defp via_tuple(session, opts) do
    registry = Keyword.fetch!(opts, :registry)
    {:via, Registry, {registry, session}}
  end

  defp refresh_ms(opts) do
    Keyword.get(
      opts,
      :refresh_ms,
      Application.get_env(:tmux_ctl, :topology_refresh_ms, @default_refresh_ms)
    )
  end

  defp reconcile_ms(opts) do
    Keyword.get(
      opts,
      :reconcile_ms,
      Application.get_env(:tmux_ctl, :topology_reconcile_ms, @default_reconcile_ms)
    )
  end

  defp normalize_refresh_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_refresh_ms(_), do: @default_refresh_ms

  defp tmux_resolver(opts) do
    Keyword.get_lazy(opts, :tmux_resolver, fn ->
      adapter = Application.get_env(:tmux_ctl, :adapter, TmuxCtl.Client)
      fn -> adapter end
    end)
  end

  defp pubsub do
    case Application.get_env(:tmux_ctl, :pubsub) do
      nil -> raise ArgumentError, "config :tmux_ctl, :pubsub is required for topology PubSub"
      pubsub -> pubsub
    end
  end

  defp topic_prefix do
    Application.get_env(:tmux_ctl, :topology_topic_prefix, @default_topic_prefix)
  end
end
