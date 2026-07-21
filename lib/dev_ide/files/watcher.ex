defmodule DevIDE.Files.Watcher do
  @moduledoc """
  Per-workspace filesystem watcher that debounces native change events and
  broadcasts a single refresh signal over PubSub.

  Lifecycle is reference-counted: LiveViews call `watch/2` while the Files
  panel is open and `unwatch/1` when it closes. The first watcher starts the
  native `file_system` backend (scoped to the workspace root); the last
  watcher leaving stops the process. Events under paths ignored by
  `DevIDE.Files.PathSafety` are dropped before broadcast.

  When the native backend cannot start (e.g. `inotifywait` missing), the
  process stays up as a no-op so callers never crash — one warning is logged.
  """

  use GenServer
  require Logger

  alias DevIDE.Files.PathSafety

  @registry DevIDE.Files.Watcher.Registry
  @supervisor DevIDE.Files.Watcher.Supervisor
  @pubsub DevIDE.PubSub
  @topic_prefix "files:watch:"
  @default_debounce_ms 400

  @type meta :: %{paths: [String.t()]}

  ## Public API

  def child_spec({workspace_id, root, opts}) do
    %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [{workspace_id, root, opts}]},
      restart: :temporary
    }
  end

  def start_link({workspace_id, root, opts})
      when is_binary(workspace_id) and is_binary(root) and is_list(opts) do
    GenServer.start_link(__MODULE__, {workspace_id, root, opts}, name: via(workspace_id))
  end

  def via(workspace_id) when is_binary(workspace_id),
    do: {:via, Registry, {@registry, workspace_id}}

  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "PubSub topic for debounced workspace file changes."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc "Subscribe the caller to debounced `{:files_changed, workspace_id, meta}` messages."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
  end

  @doc "Unsubscribe the caller from workspace file changes."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(workspace_id))
  end

  @doc """
  Ensure a watcher is running for `workspace_id` rooted at `root` and register
  the calling process as a live consumer. Monitors the caller so crashes drop
  the refcount automatically.
  """
  @spec watch(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def watch(workspace_id, root, opts \\ [])
      when is_binary(workspace_id) and is_binary(root) do
    with {:ok, pid} <- ensure_started(workspace_id, root, opts) do
      GenServer.call(pid, {:watch, self()})
    end
  end

  @doc "Deregister the calling process as a consumer; stops when the last leaves."
  @spec unwatch(String.t()) :: :ok
  def unwatch(workspace_id) when is_binary(workspace_id) do
    case whereis(workspace_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:unwatch, self()})
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end
  end

  @doc false
  @spec ensure_started(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(workspace_id, root, opts \\ [])
      when is_binary(workspace_id) and is_binary(root) do
    case whereis(workspace_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case DynamicSupervisor.start_child(
               @supervisor,
               {__MODULE__, {workspace_id, Path.expand(root), opts}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  # Test/helper: inject a native-style path event into a running watcher.
  @spec notify(String.t(), String.t()) :: :ok | {:error, :not_running}
  def notify(workspace_id, abs_path)
      when is_binary(workspace_id) and is_binary(abs_path) do
    case whereis(workspace_id) do
      {:ok, pid} ->
        send(pid, {:file_event, :test, {abs_path, [:modified]}})
        :ok

      :error ->
        {:error, :not_running}
    end
  end

  ## Callbacks

  @impl true
  def init({workspace_id, root, opts}) do
    root = Path.expand(root)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    backend = Keyword.get(opts, :backend, :native)

    {fs_pid, backend_status} = start_backend(backend, root)

    state = %{
      workspace_id: workspace_id,
      root: root,
      debounce_ms: debounce_ms,
      fs_pid: fs_pid,
      backend_status: backend_status,
      watchers: %{},
      pending: MapSet.new(),
      timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:watch, pid}, _from, state) when is_pid(pid) do
    state =
      case Map.get(state.watchers, pid) do
        nil ->
          ref = Process.monitor(pid)
          put_in(state.watchers[pid], ref)

        _ref ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:unwatch, pid}, _from, state) when is_pid(pid) do
    state = drop_watcher(state, pid)

    if map_size(state.watchers) == 0 do
      {:stop, :normal, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:file_event, fs_pid, {path, _events}}, %{fs_pid: fs_pid} = state)
      when is_binary(path) do
    {:noreply, maybe_queue_path(state, path)}
  end

  def handle_info({:file_event, :test, {path, _events}}, state) when is_binary(path) do
    {:noreply, maybe_queue_path(state, path)}
  end

  def handle_info({:file_event, fs_pid, :stop}, %{fs_pid: fs_pid} = state) do
    Logger.warning("files watcher backend stopped for workspace=#{state.workspace_id}")
    {:noreply, %{state | fs_pid: nil, backend_status: :stopped}}
  end

  def handle_info(:flush, state) do
    paths = MapSet.to_list(state.pending)

    if paths != [] do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.workspace_id),
        {:files_changed, state.workspace_id, %{paths: paths}}
      )
    end

    {:noreply, %{state | pending: MapSet.new(), timer: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.watchers, pid) do
        ^ref -> drop_watcher(state, pid)
        _ -> state
      end

    if map_size(state.watchers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.fs_pid) and Process.alive?(state.fs_pid) do
      Process.exit(state.fs_pid, :shutdown)
    end

    :ok
  end

  ## Internals

  defp start_backend(:native, root) do
    case FileSystem.start_link(dirs: [root]) do
      {:ok, pid} ->
        _ = FileSystem.subscribe(pid)
        {pid, :ok}

      {:error, reason} ->
        Logger.warning(
          "files watcher disabled (file_system backend unavailable: #{inspect(reason)}); " <>
            "install inotify-tools for auto-refresh"
        )

        {nil, {:error, reason}}
    end
  rescue
    error ->
      Logger.warning(
        "files watcher disabled (file_system raised: #{Exception.message(error)}); " <>
          "install inotify-tools for auto-refresh"
      )

      {nil, {:error, error}}
  end

  defp start_backend(:test, _root), do: {nil, :test}

  defp maybe_queue_path(state, abs_path) do
    case relative_under_root(state.root, abs_path) do
      {:ok, rel} ->
        if PathSafety.ignored?(rel) do
          state
        else
          schedule_flush(%{state | pending: MapSet.put(state.pending, rel)})
        end

      :error ->
        state
    end
  end

  defp schedule_flush(%{timer: nil, debounce_ms: ms} = state) do
    ref = Process.send_after(self(), :flush, ms)
    %{state | timer: ref}
  end

  defp schedule_flush(state), do: state

  defp drop_watcher(state, pid) do
    case Map.pop(state.watchers, pid) do
      {nil, _} ->
        state

      {ref, watchers} ->
        Process.demonitor(ref, [:flush])
        %{state | watchers: watchers}
    end
  end

  defp relative_under_root(root, abs_path) do
    root = Path.expand(root)
    abs = Path.expand(abs_path)

    cond do
      abs == root ->
        {:ok, ""}

      true ->
        rel = Path.relative_to(abs, root)

        if rel == abs or String.starts_with?(rel, ".." <> "/") or rel == ".." do
          :error
        else
          {:ok, rel}
        end
    end
  end
end
