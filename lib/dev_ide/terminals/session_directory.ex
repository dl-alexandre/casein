defmodule DevIDE.Terminals.SessionDirectory do
  @moduledoc """
  Per-workspace source of truth for the terminal session tab list.

  Owns the canonical, viewer-independent list of attachable sessions for a
  workspace (live shells, fleet executions, scanned tmux sessions — merged
  and deduplicated by `SessionDirectory.Compose`) and broadcasts changes:

      {DevIDE.Terminals.SessionDirectory, {:sessions_updated, workspace_id, tabs}}

  on `"terminal_tabs:<workspace_id>"`. Consumers apply
  `Compose.visible_for/2` with their own default sid.

  Lifecycle: started on demand, registered in `DevIDE.Terminals.Registry`
  under `{:session_directory, workspace_id}`. While subscribers exist it
  polls tmux every #{2_000}ms as a safety net (sessions can appear or die
  outside this node's control); when the last subscriber goes away it stops.
  `read/2` is the processless direct read used for static renders and as a
  fallback.
  """

  use GenServer

  alias DevIDE.Terminals.SessionDirectory.Compose
  alias DevIDE.Terminals.SessionRegistry
  alias DevIDE.Terminals.Tmux

  @registry DevIDE.Terminals.Registry
  @supervisor DevIDE.Terminals.Supervisor
  @pubsub DevIde.PubSub
  @topic_prefix "terminal_tabs:"
  @poll_ms 2_000

  @doc "PubSub topic carrying `{:sessions_updated, workspace_id, tabs}`."
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc """
  Direct, processless read of the canonical tab list. Options:
  `:workspace_name` — used for the tmux session-name prefix (defaults to the
  workspace id, matching `Tmux.session_name/2` usage for unnamed workspaces).
  """
  @spec read(String.t(), keyword()) :: [DevIDE.Terminals.Session.Info.t()]
  def read(workspace_id, opts \\ []) when is_binary(workspace_id) do
    workspace_name = Keyword.get(opts, :workspace_name) || workspace_id

    scanned = Compose.scan_tmux_sessions(list_tmux_sessions(), workspace_id, workspace_name)
    Compose.compose(scanned, SessionRegistry.list_attachable(workspace_id))
  end

  @doc "Cached canonical tabs; starts the directory on demand."
  @spec tabs(String.t(), keyword()) :: [DevIDE.Terminals.Session.Info.t()]
  def tabs(workspace_id, opts \\ []) do
    case ensure_started(workspace_id, opts) do
      {:ok, pid} -> GenServer.call(pid, :tabs)
      {:error, _reason} -> read(workspace_id, opts)
    end
  catch
    :exit, _ -> read(workspace_id, opts)
  end

  @doc "Forces a fresh recompute (broadcasting on change) and returns the tabs."
  @spec refresh_now(String.t(), keyword()) :: [DevIDE.Terminals.Session.Info.t()]
  def refresh_now(workspace_id, opts \\ []) do
    case ensure_started(workspace_id, opts) do
      {:ok, pid} -> GenServer.call(pid, :refresh)
      {:error, _reason} -> read(workspace_id, opts)
    end
  catch
    :exit, _ -> read(workspace_id, opts)
  end

  @doc "Async recompute poke; a no-op when no directory is running."
  @spec refresh(String.t()) :: :ok
  def refresh(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, key(workspace_id)) do
      [{pid, _}] -> GenServer.cast(pid, :refresh)
      [] -> :ok
    end

    :ok
  end

  @doc "Finds a canonical tab by its attach id."
  @spec fetch(String.t(), String.t(), keyword()) ::
          {:ok, DevIDE.Terminals.Session.Info.t()} | :error
  def fetch(workspace_id, attach_id, opts \\ []) do
    case Enum.find(tabs(workspace_id, opts), &(Compose.attach_id(&1) == attach_id)) do
      nil -> :error
      info -> {:ok, info}
    end
  end

  @doc """
  Subscribes the caller to tab updates and registers it with the directory
  so polling runs only while someone is watching. Safe to call repeatedly
  (the PubSub subscription is reset, not duplicated).
  """
  @spec subscribe(String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(workspace_id, opts \\ []) do
    with {:ok, pid} <- ensure_started(workspace_id, opts) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic(workspace_id))
      :ok = Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
      GenServer.cast(pid, {:watch, self()})
      :ok
    end
  end

  @doc false
  def ensure_started(workspace_id, opts \\ []) when is_binary(workspace_id) do
    case Registry.lookup(@registry, key(workspace_id)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {workspace_id, opts}}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  def child_spec({workspace_id, opts}) do
    %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [{workspace_id, opts}]},
      restart: :transient
    }
  end

  def start_link({workspace_id, opts}) do
    GenServer.start_link(__MODULE__, {workspace_id, opts},
      name: {:via, Registry, {@registry, key(workspace_id)}}
    )
  end

  @impl true
  def init({workspace_id, opts}) do
    workspace_name = Keyword.get(opts, :workspace_name) || workspace_id
    tabs = read(workspace_id, workspace_name: workspace_name)

    {:ok,
     %{
       workspace_id: workspace_id,
       workspace_name: workspace_name,
       tabs: tabs,
       hash: Compose.stable_hash(tabs),
       watchers: %{},
       timer_ref: nil
     }}
  end

  @impl true
  def handle_call(:tabs, _from, state), do: {:reply, state.tabs, state}

  def handle_call(:refresh, _from, state) do
    state = recompute(state)
    {:reply, state.tabs, state}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, recompute(state)}

  def handle_cast({:watch, pid}, state) do
    if Enum.any?(state.watchers, fn {_ref, watcher} -> watcher == pid end) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      state = %{state | watchers: Map.put(state.watchers, ref, pid)}
      {:noreply, schedule_poll(state)}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{recompute(state) | timer_ref: nil}

    if map_size(state.watchers) > 0 do
      {:noreply, schedule_poll(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    watchers = Map.delete(state.watchers, ref)
    state = %{state | watchers: watchers}

    if map_size(watchers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp recompute(state) do
    tabs = read(state.workspace_id, workspace_name: state.workspace_name)
    hash = Compose.stable_hash(tabs)

    if hash != state.hash do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.workspace_id),
        {__MODULE__, {:sessions_updated, state.workspace_id, tabs}}
      )
    end

    %{state | tabs: tabs, hash: hash}
  end

  defp schedule_poll(%{timer_ref: nil} = state) do
    %{state | timer_ref: Process.send_after(self(), :poll, poll_ms())}
  end

  defp schedule_poll(state), do: state

  defp key(workspace_id), do: {:session_directory, workspace_id}

  defp poll_ms do
    Application.get_env(:dev_ide, :session_directory_poll_ms, @poll_ms)
  end

  defp list_tmux_sessions do
    adapter = Application.get_env(:dev_ide, :tmux_adapter, Tmux)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :list_sessions, 0) do
      adapter.list_sessions()
    else
      []
    end
  end
end
