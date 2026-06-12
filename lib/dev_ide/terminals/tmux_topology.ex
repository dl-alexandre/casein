defmodule DevIDE.Terminals.TmuxTopology do
  @moduledoc """
  Read-only tmux topology resource for workspace terminals.

  The LiveView should not know tmux format strings or error handling details.
  The snapshot helpers keep the MVP intentionally small: one session, windows
  as tabs, and a version value that changes when the visible topology changes.

  A lightweight process can also keep that snapshot warm and broadcast changes
  over PubSub. This gives LiveViews and agents a common topology resource
  without coupling the UI to polling mechanics.
  """

  use GenServer

  alias DevIDE.Audit
  alias DevIDE.Terminals.Tmux

  @registry DevIDE.Terminals.TopologyRegistry
  @supervisor DevIDE.Terminals.TopologySupervisor
  @pubsub DevIde.PubSub
  @topic_prefix "terminal_topology:"
  @default_refresh_ms 300

  @type window :: %{
          id: String.t(),
          index: non_neg_integer(),
          name: String.t(),
          active: boolean(),
          panes: pos_integer(),
          pane_list: [pane()],
          activity: non_neg_integer(),
          current_command: String.t()
        }

  @type pane :: %{
          id: String.t(),
          window_id: String.t(),
          index: non_neg_integer(),
          active: boolean(),
          left: non_neg_integer(),
          top: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          current_command: String.t(),
          current_path: String.t(),
          activity: non_neg_integer(),
          activity_flag: boolean(),
          bell: boolean(),
          unseen_changes: boolean()
        }

  @type t :: %{
          :session => String.t(),
          :windows => [window()],
          :panes => [pane()],
          :active_window_id => String.t() | nil,
          :active_pane_id => String.t() | nil,
          :version => non_neg_integer(),
          :structure_version => non_neg_integer(),
          # Watcher-produced topologies carry the watcher incarnation tag;
          # direct snapshot/2 reads do not.
          optional(:generation) => pos_integer()
        }

  @doc """
  Return the current window topology for a session.

  With no options, this uses the supervised watcher when available, starting it
  on demand. Passing `:tmux` preserves the original direct-read behavior for
  tests and call sites that need a specific adapter.
  """
  @spec get(String.t(), keyword()) :: t()
  def get(session, opts \\ []) when is_binary(session) do
    if Keyword.has_key?(opts, :tmux) do
      snapshot(session, opts)
    else
      case ensure_started(session, opts) do
        {:ok, pid} -> GenServer.call(pid, :get)
        {:error, _reason} -> snapshot(session, opts)
      end
    end
  end

  @doc "Read topology directly from tmux without using the watcher process."
  @spec snapshot(String.t(), keyword()) :: t()
  def snapshot(session, opts \\ []) when is_binary(session) do
    adapter = Keyword.get(opts, :tmux, tmux_adapter())
    {windows, panes} = read_topology(adapter, session)
    windows = attach_panes(windows, panes)
    active = Enum.find(windows, & &1.active)
    active_pane = Enum.find(panes, & &1.active)

    %{
      session: session,
      windows: windows,
      panes: panes,
      active_window_id: active && active.id,
      active_pane_id: active_pane && active_pane.id,
      version: :erlang.phash2({windows, panes}),
      structure_version: structure_version(windows, panes)
    }
  end

  # Hash of the topology's *shape* only — window/pane identity, order, names,
  # and the active selection. Excludes per-poll churn (activity timestamps,
  # bell/activity flags, geometry, running command) so consumers that key DOM
  # state off a version attribute (e.g. the window dropdown's data-version)
  # are not patched on every poll. The full `version` stays the watcher's
  # change-detection signal because activity changes must still broadcast.
  defp structure_version(windows, panes) do
    :erlang.phash2({
      Enum.map(windows, &{&1.id, &1.index, &1.name, &1.active, &1.panes}),
      Enum.map(panes, &{&1.id, &1.window_id, &1.index, &1.active})
    })
  end

  @doc "Start the topology watcher for a tmux session if needed."
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session, opts \\ []) when is_binary(session) do
    case Registry.lookup(@registry, session) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {session, opts}}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  @doc "Request an immediate refresh from the topology watcher."
  @spec refresh(String.t()) :: :ok | {:error, term()}
  def refresh(session) when is_binary(session) do
    case ensure_started(session) do
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
  @spec refresh_now(String.t(), keyword()) :: t()
  def refresh_now(session, opts \\ []) when is_binary(session) do
    if Keyword.has_key?(opts, :tmux) do
      snapshot(session, opts)
    else
      case ensure_started(session, opts) do
        {:ok, pid} -> GenServer.call(pid, :refresh)
        {:error, _reason} -> snapshot(session, opts)
      end
    end
  end

  @doc "Subscribe the caller to topology updates for a tmux session."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session) when is_binary(session) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session))
  end

  @doc """
  Register the caller as a live consumer of the session's watcher.

  The watcher monitors registered consumers and stops itself (normally,
  without a `:session_terminated` broadcast) after an idle grace period once
  the last one exits. Watchers that are merely poked (`configure/2`,
  `refresh/1`, one-shot `get/2`) without any registered consumer stop after
  the same grace period instead of polling forever. `switch_subscription/3`
  registers the caller automatically, so LiveViews get this for free.
  """
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
  @spec unwatch(String.t()) :: :ok
  def unwatch(session) when is_binary(session) do
    case Registry.lookup(@registry, session) do
      [{pid, _}] ->
        GenServer.call(pid, {:unwatch, self()})
        :ok

      [] ->
        :ok
    end
  catch
    # Watcher stopped between lookup and call — already the desired outcome.
    :exit, _ -> :ok
  end

  @doc """
  Moves the caller's topology subscription from `old_session` to
  `new_session` in one step: unsubscribes the old topic, (re)subscribes the
  new one without double-subscribing, ensures a watcher, and returns the
  watcher's `generation` plus a topology read.

  This replaces the unsubscribe → assign → subscribe → refresh dance that
  left a window where broadcasts from the old session (or from a previous
  watcher incarnation of the same name) could interleave with the switch.
  Callers should store `{session, generation}`; a `:session_terminated`
  carrying a different generation comes from a dead watcher incarnation and
  must be ignored, while an `:updated` with a new generation signals a
  watcher restart to resync with.

  Options: `:read` — `:refresh` (default) forces a fresh tmux read;
  `:get` returns the watcher's cached topology (cheap, used at mount where
  the watcher just snapshotted in init). Remaining options are passed to
  `ensure_started/2`.
  """
  @spec switch_subscription(String.t() | nil, String.t(), keyword()) ::
          {:ok, %{session: String.t(), generation: pos_integer() | nil, topology: t()}}
  def switch_subscription(old_session, new_session, opts \\ []) when is_binary(new_session) do
    {read, opts} = Keyword.pop(opts, :read, :refresh)

    if is_binary(old_session) and old_session != new_session do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(old_session))
      unwatch(old_session)
    end

    # Unsubscribe-then-subscribe keeps this idempotent: PubSub subscriptions
    # are not deduplicated, and a double subscribe means duplicate messages.
    Phoenix.PubSub.unsubscribe(@pubsub, topic(new_session))
    :ok = subscribe(new_session)

    case ensure_started(new_session, opts) do
      {:ok, pid} ->
        try do
          :ok = GenServer.call(pid, {:watch, self()})
          topology = GenServer.call(pid, read)

          {:ok,
           %{session: new_session, generation: Map.get(topology, :generation), topology: topology}}
        catch
          # The watcher can stop normally mid-call when its tmux session just
          # died (or a stale registry entry raced us). Fall back to a direct
          # read; the next subscribe/refresh starts a fresh watcher.
          :exit, _ ->
            {:ok, %{session: new_session, generation: nil, topology: snapshot(new_session, opts)}}
        end

      {:error, _reason} ->
        {:ok, %{session: new_session, generation: nil, topology: snapshot(new_session, opts)}}
    end
  end

  @doc "Return the PubSub topic used for a tmux session."
  @spec topic(String.t()) :: String.t()
  def topic(session) when is_binary(session), do: @topic_prefix <> session

  def child_spec({session, opts}) do
    %{
      id: {__MODULE__, session},
      start: {__MODULE__, :start_link, [{session, opts}]},
      restart: :transient
    }
  end

  @spec start_link({String.t(), keyword()}) :: GenServer.on_start()
  def start_link({session, opts}) do
    GenServer.start_link(__MODULE__, {session, opts}, name: via_tuple(session))
  end

  @impl true
  def init({session, opts}) do
    # Only an explicitly passed adapter is pinned; otherwise resolve the
    # configured adapter at each read. A watcher outlives the caller that
    # started it, and a stale init-time binding would keep reading through
    # an adapter the environment has since swapped out.
    tmux_opt = Keyword.get(opts, :tmux)
    refresh_ms = normalize_refresh_ms(Keyword.get(opts, :refresh_ms, refresh_ms()))
    polling_enabled? = Keyword.get(opts, :enabled, true)
    workspace_id = Keyword.get(opts, :workspace_id)
    # Identifies this watcher incarnation. Recreated same-name sessions get a
    # fresh watcher with a fresh generation, letting subscribers tell live
    # broadcasts from stale ones still sitting in their mailbox.
    generation = System.unique_integer([:positive, :monotonic])

    topology =
      session
      |> snapshot(tmux: tmux_opt || tmux_adapter())
      |> Map.put(:generation, generation)

    state = %{
      session: session,
      workspace_id: workspace_id,
      tmux_opt: tmux_opt,
      refresh_ms: refresh_ms,
      polling_enabled?: polling_enabled?,
      generation: generation,
      topology: topology,
      timer_ref: nil,
      watchers: %{},
      idle_stop_ms: idle_stop_ms(opts),
      idle_timer: nil
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
      # Nobody is consuming broadcasts — stop polling. The session itself is
      # untouched; the next get/watch/switch_subscription starts a fresh
      # watcher. (Trade-off: a session that dies while unwatched emits no
      # `tmux.session_terminated` audit event.)
      {:stop, :normal, %{state | idle_timer: nil}}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  defp refresh_state(state) do
    adapter = state.tmux_opt || tmux_adapter()

    topology =
      state.session
      |> snapshot(tmux: adapter)
      |> Map.put(:generation, state.generation)

    # A live tmux session always has at least one window and one pane, so an
    # empty snapshot means the session (or the tmux server) is gone. This is
    # the same signal the dedicated `has-session` probe used to provide,
    # without spending an extra subprocess on every poll tick.
    if topology.windows == [] and topology.panes == [] do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.session),
        {__MODULE__,
         {:session_terminated,
          %{session: state.session, generation: state.generation, reason: :session_not_alive}}}
      )

      emit_session_terminated_audit(state, :session_not_alive)

      {:terminated, cancel_refresh_timer(state)}
    else
      if topology.version != state.topology.version do
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(state.session),
          {__MODULE__, {:updated, topology}}
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
      Application.get_env(:dev_ide, :tmux_topology_idle_stop_ms, 60_000)
    )
  end

  defp maybe_put_workspace_id(state, nil), do: state
  defp maybe_put_workspace_id(state, ""), do: state
  defp maybe_put_workspace_id(state, workspace_id), do: %{state | workspace_id: workspace_id}

  defp via_tuple(session), do: {:via, Registry, {@registry, session}}

  defp refresh_ms do
    Application.get_env(:dev_ide, :tmux_topology_refresh_ms, @default_refresh_ms)
  end

  defp normalize_refresh_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_refresh_ms(_), do: @default_refresh_ms

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  # One subprocess instead of two when the adapter supports the merged
  # windows+panes read; test fakes fall back to the two-call path.
  defp read_topology(adapter, session) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :session_topology, 1) do
      adapter.session_topology(session)
    else
      {adapter.list_session_windows(session), list_session_panes(adapter, session)}
    end
  end

  defp emit_session_terminated_audit(%{workspace_id: workspace_id} = state, reason)
       when is_binary(workspace_id) and workspace_id != "" do
    Audit.emit!(%{
      action: "tmux.session_terminated",
      workspace_id: workspace_id,
      actor_id: "system",
      target_type: "tmux_session",
      target_ref: state.session,
      metadata: %{
        session: state.session,
        reason: reason,
        last_topology_version: state.topology.version,
        active_window_id: state.topology.active_window_id,
        active_pane_id: state.topology.active_pane_id
      }
    })
  end

  defp emit_session_terminated_audit(_state, _reason), do: nil

  defp list_session_panes(adapter, session) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :list_session_panes, 1) do
      adapter.list_session_panes(session)
    else
      []
    end
  end

  defp attach_panes(windows, panes) do
    panes_by_window = Enum.group_by(panes, & &1.window_id)

    Enum.map(windows, fn window ->
      pane_list =
        panes_by_window
        |> Map.get(window.id, [])
        |> Enum.sort_by(& &1.index)

      Map.put(window, :pane_list, pane_list)
    end)
  end
end
