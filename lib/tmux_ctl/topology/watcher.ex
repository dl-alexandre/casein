defmodule TmuxCtl.Topology.Watcher do
  @moduledoc """
  GenServer that polls tmux topology and broadcasts changes over PubSub.

  Inject `pubsub`, `registry`, `supervisor`, `broadcast_tag`, `tmux_resolver`,
  and optional `on_session_terminated` via start options. Timing defaults come
  from `config :tmux_ctl` keys `:topology_refresh_ms`, `:topology_idle_stop_ms`,
  and `:topology_topic_prefix`.
  """

  use GenServer

  alias TmuxCtl.Topology

  @default_refresh_ms 300
  @default_topic_prefix "terminal_topology:"

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
  """
  @spec switch_subscription(String.t() | nil, String.t(), keyword()) ::
          {:ok, %{session: String.t(), generation: pos_integer() | nil, topology: Topology.t()}}
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
           %{session: new_session, generation: Map.get(topology, :generation), topology: topology}}
        catch
          :exit, _ ->
            {:ok,
             %{
               session: new_session,
               generation: nil,
               topology: snapshot(new_session, opts)
             }}
        end

      {:error, _reason} ->
        {:ok,
         %{
           session: new_session,
           generation: nil,
           topology: snapshot(new_session, opts)
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
    polling_enabled? = Keyword.get(opts, :enabled, true)
    workspace_id = Keyword.get(opts, :workspace_id)
    generation = System.unique_integer([:positive, :monotonic])

    topology_transform = topology_transform(opts)

    topology =
      session
      |> Topology.snapshot(tmux: tmux_opt || tmux_resolver(opts).())
      |> Map.put(:generation, generation)

    topology = topology_transform.(topology)

    state = %{
      session: session,
      workspace_id: workspace_id,
      tmux_opt: tmux_opt,
      tmux_resolver: tmux_resolver(opts),
      refresh_ms: refresh_ms,
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
      on_session_terminated: Keyword.get(opts, :on_session_terminated, fn _, _ -> :ok end)
    }

    {:ok, state |> schedule_refresh() |> schedule_idle_stop()}
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
    case refresh_state(state) do
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
      |> Map.put(:polling_enabled?, Keyword.get(opts, :enabled, state.polling_enabled?))
      |> maybe_put_workspace_id(Keyword.get(opts, :workspace_id))
      |> schedule_refresh()

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    case refresh_state(state) do
      {:ok, state} -> {:noreply, state}
      {:terminated, state} -> {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    case refresh_state(state) do
      {:ok, state} ->
        {:noreply, schedule_refresh(state)}

      {:terminated, state} ->
        {:stop, :normal, state}
    end
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

  defp refresh_state(state) do
    adapter = state.tmux_opt || state.tmux_resolver.()

    topology =
      state.session
      |> Topology.snapshot(tmux: adapter)
      |> Map.put(:generation, state.generation)

    topology = state.topology_transform.(topology)

    if topology.windows == [] and topology.panes == [] do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(state.session, topic_prefix: state.topic_prefix),
        {state.broadcast_tag,
         {:session_terminated,
          %{session: state.session, generation: state.generation, reason: :session_not_alive}}}
      )

      state.on_session_terminated.(state, :session_not_alive)

      {:terminated, cancel_refresh_timer(state)}
    else
      if topology.version != state.topology.version do
        Phoenix.PubSub.broadcast(
          state.pubsub,
          topic(state.session, topic_prefix: state.topic_prefix),
          {state.broadcast_tag, {:updated, topology}}
        )
      end

      {:ok, %{state | topology: topology}}
    end
  end

  defp schedule_refresh(%{polling_enabled?: false} = state), do: %{state | timer_ref: nil}

  defp schedule_refresh(%{refresh_ms: refresh_ms} = state) do
    timer_ref = Process.send_after(self(), :refresh, refresh_ms)
    %{state | timer_ref: timer_ref}
  end

  defp cancel_refresh_timer(%{timer_ref: nil} = state), do: state

  defp cancel_refresh_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
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
