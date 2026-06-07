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
  @default_refresh_ms 1_500

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
          session: String.t(),
          windows: [window()],
          panes: [pane()],
          active_window_id: String.t() | nil,
          active_pane_id: String.t() | nil,
          version: non_neg_integer()
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
    panes = list_session_panes(adapter, session)
    windows = attach_panes(adapter.list_session_windows(session), panes)
    active = Enum.find(windows, & &1.active)
    active_pane = Enum.find(panes, & &1.active)

    %{
      session: session,
      windows: windows,
      panes: panes,
      active_window_id: active && active.id,
      active_pane_id: active_pane && active_pane.id,
      version: :erlang.phash2({windows, panes})
    }
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
    adapter = Keyword.get(opts, :tmux, tmux_adapter())
    refresh_ms = normalize_refresh_ms(Keyword.get(opts, :refresh_ms, refresh_ms()))
    polling_enabled? = Keyword.get(opts, :enabled, true)
    workspace_id = Keyword.get(opts, :workspace_id)
    topology = snapshot(session, tmux: adapter)

    state = %{
      session: session,
      workspace_id: workspace_id,
      tmux: adapter,
      refresh_ms: refresh_ms,
      polling_enabled?: polling_enabled?,
      topology: topology,
      timer_ref: nil
    }

    {:ok, schedule_refresh(state)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.topology, state}

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

  defp refresh_state(state) do
    if session_alive?(state.tmux, state.session) do
      topology = snapshot(state.session, tmux: state.tmux)

      if topology.version != state.topology.version do
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(state.session),
          {__MODULE__, {:updated, topology}}
        )
      end

      {:ok, %{state | topology: topology}}
    else
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.session),
        {__MODULE__, {:session_terminated, %{session: state.session, reason: :session_not_alive}}}
      )

      emit_session_terminated_audit(state, :session_not_alive)

      {:terminated, cancel_refresh_timer(state)}
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

  defp session_alive?(adapter, session) do
    cond do
      Code.ensure_loaded?(adapter) and function_exported?(adapter, :session_alive?, 1) ->
        adapter.session_alive?(session)

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :session_exists?, 1) ->
        adapter.session_exists?(session)

      true ->
        true
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
