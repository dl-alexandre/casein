defmodule Casein.Files.Watcher do
  @moduledoc """
  Per-workspace filesystem watcher that debounces native change events and
  broadcasts a single refresh signal over PubSub.

  Lifecycle is reference-counted: LiveViews call `watch/2` while the Files
  panel is open and `unwatch/1` when it closes. The first watcher starts the
  native `file_system` backend (scoped to the workspace root); the last
  watcher leaving stops the process after a short linger so quick tab reopen
  reuses the same inotify setup. Events under paths ignored by
  `Casein.Files.PathSafety` are dropped before broadcast.

  Native scope subtracts ignored top-level directories (`.git`, `_build`,
  `deps`, `node_modules`, …) from the recursive watch set and pairs that with
  a non-recursive root watch so root-level files and newly created top-level
  directories are still observed. Only newly created (not-yet-watched)
  top-level dirs trigger a backend rescan; existing recursive watches are left
  alone on chmod/utimes/rename noise.

  Debounced meta is either a list of relative paths or the sentinel `:all`.
  `:all` is used when pending paths exceed the overflow cap (500) in one
  debounce window (overflow collapse) or after a rescan restart (resync so
  subscribers recover events lost while backends were stopped). Consumers treat
  `:all` as a full tree refresh.

  When the native backend cannot start (e.g. `inotifywait` missing), the
  process stays up as a no-op so callers never crash — one warning is logged.
  """

  use GenServer
  require Logger

  alias Casein.Files.PathSafety

  @registry Casein.Files.Watcher.Registry
  @supervisor Casein.Files.Watcher.Supervisor
  @pubsub Casein.PubSub
  @topic_prefix "files:watch:"
  @default_debounce_ms 400
  @default_linger_ms 30_000
  # Cap distinct relative paths queued in one debounce window; beyond this
  # pending collapses to `:all` so PubSub messages and LiveView affected sets
  # stay bounded (e.g. branch switches).
  @max_pending_paths 500

  @type meta :: %{paths: [String.t()] | :all}

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
      try do
        GenServer.call(pid, {:watch, self()})
      catch
        :exit, _ ->
          with {:ok, pid2} <- ensure_started(workspace_id, root, opts) do
            try do
              GenServer.call(pid2, {:watch, self()})
            catch
              :exit, _ -> {:error, :watcher_unavailable}
            end
          end
      end
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
    # FileSystem.start_link/1 links backends to this process; trap so a backend
    # exit (including intentional restart) does not take the watcher down.
    Process.flag(:trap_exit, true)

    root = Path.expand(root)
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    linger_ms = Keyword.get(opts, :linger_ms, @default_linger_ms)
    backend = Keyword.get(opts, :backend, :native)

    {fs_pids, backend_status, watched_dirs} = start_backend(backend, root)

    state = %{
      workspace_id: workspace_id,
      root: root,
      debounce_ms: debounce_ms,
      linger_ms: linger_ms,
      backend: backend,
      fs_pids: fs_pids,
      watched_dirs: watched_dirs,
      backend_status: backend_status,
      watchers: %{},
      pending: MapSet.new(),
      timer: nil,
      needs_rescan: false
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
      {:reply, :ok, schedule_maybe_stop(state)}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:file_event, fs_pid, {path, _events}}, state)
      when is_binary(path) and is_pid(fs_pid) do
    if fs_pid in state.fs_pids do
      {:noreply, maybe_queue_path(state, path)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, :test, {path, _events}}, state) when is_binary(path) do
    {:noreply, maybe_queue_path(state, path)}
  end

  def handle_info({:file_event, fs_pid, :stop}, state) when is_pid(fs_pid) do
    if fs_pid in state.fs_pids do
      fs_pids = List.delete(state.fs_pids, fs_pid)

      if fs_pids == [] do
        Logger.warning("files watcher backend stopped for workspace=#{state.workspace_id}")
        {:noreply, %{state | fs_pids: [], backend_status: :stopped}}
      else
        {:noreply, %{state | fs_pids: fs_pids}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    state = flush_pending(state)

    if state.needs_rescan do
      state = restart_backends(%{state | needs_rescan: false})

      # Events between stop_fs_pids and the new watch can be dropped; force a
      # full-refresh so subscribers resync after the restart window.
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.workspace_id),
        {:files_changed, state.workspace_id, %{paths: :all}}
      )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:maybe_stop, state) do
    if map_size(state.watchers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.watchers, pid) do
        ^ref -> drop_watcher(state, pid)
        _ -> state
      end

    if map_size(state.watchers) == 0 do
      {:noreply, schedule_maybe_stop(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    if pid in state.fs_pids do
      fs_pids = List.delete(state.fs_pids, pid)

      if fs_pids == [] do
        Logger.warning("files watcher backend stopped for workspace=#{state.workspace_id}")
        {:noreply, %{state | fs_pids: [], backend_status: :stopped}}
      else
        {:noreply, %{state | fs_pids: fs_pids}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.fs_pids, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    :ok
  end

  ## Internals

  defp start_backend(:native, root) do
    watched_dirs = compute_watched_dirs(root)

    try do
      recursive = watched_dirs.recursive
      non_recursive = watched_dirs.non_recursive

      {pids, errors} = {[], []}

      {pids, errors} =
        if recursive == [] do
          {pids, errors}
        else
          start_one_fs({pids, errors}, dirs: recursive)
        end

      # Root is always non-recursive so top-level files and new dirs are seen.
      {pids, errors} = start_one_fs({pids, errors}, dirs: non_recursive, recursive: false)

      case pids do
        [] ->
          reason = List.first(errors) || :unavailable

          Logger.warning(
            "files watcher disabled (file_system backend unavailable: #{inspect(reason)}); " <>
              "install inotify-tools for auto-refresh"
          )

          {[], {:error, reason}, watched_dirs}

        _ ->
          {Enum.reverse(pids), :ok, watched_dirs}
      end
    rescue
      error ->
        Logger.warning(
          "files watcher disabled (file_system raised: #{Exception.message(error)}); " <>
            "install inotify-tools for auto-refresh"
        )

        {[], {:error, error}, watched_dirs}
    end
  end

  defp start_backend(:test, root) do
    {[], :test, compute_watched_dirs(root)}
  end

  defp start_one_fs({pids, errors}, opts) do
    case FileSystem.start_link(opts) do
      {:ok, pid} ->
        _ = FileSystem.subscribe(pid)
        {[pid | pids], errors}

      {:error, reason} ->
        {pids, [reason | errors]}
    end
  end

  @doc false
  def compute_watched_dirs(root) when is_binary(root) do
    root = Path.expand(root)

    recursive =
      case File.ls(root) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn name ->
            abs = Path.join(root, name)
            File.dir?(abs) and not PathSafety.ignored_dir?(name)
          end)
          |> Enum.map(&Path.join(root, &1))
          |> Enum.sort()

        {:error, _} ->
          []
      end

    %{recursive: recursive, non_recursive: [root]}
  end

  defp restart_backends(state) do
    stop_fs_pids(state.fs_pids)

    {fs_pids, backend_status, watched_dirs} = start_backend(state.backend, state.root)

    %{
      state
      | fs_pids: fs_pids,
        backend_status: backend_status,
        watched_dirs: watched_dirs
    }
  end

  defp stop_fs_pids(pids) do
    refs =
      for pid <- pids, is_pid(pid), Process.alive?(pid) do
        # Unlink before shutdown so the EXIT reason cannot race past trap_exit
        # setup, and so we wait on a clean monitor DOWN.
        Process.unlink(pid)
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)
        ref
      end

    Enum.each(refs, fn ref ->
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        500 -> :ok
      end
    end)
  end

  defp maybe_queue_path(state, abs_path) do
    case relative_under_root(state.root, abs_path) do
      {:ok, rel} ->
        if PathSafety.ignored?(rel) do
          state
        else
          state =
            state
            |> put_pending(rel)
            |> schedule_flush()

          maybe_mark_rescan(state, rel)
        end

      :error ->
        state
    end
  end

  defp put_pending(%{pending: :all} = state, _rel), do: state

  defp put_pending(state, rel) do
    pending = MapSet.put(state.pending, rel)

    if MapSet.size(pending) > @max_pending_paths do
      %{state | pending: :all}
    else
      %{state | pending: pending}
    end
  end

  defp flush_pending(%{pending: :all} = state) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.workspace_id),
      {:files_changed, state.workspace_id, %{paths: :all}}
    )

    %{state | pending: MapSet.new(), timer: nil}
  end

  defp flush_pending(state) do
    paths = MapSet.to_list(state.pending)

    if paths != [] do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(state.workspace_id),
        {:files_changed, state.workspace_id, %{paths: paths}}
      )
    end

    %{state | pending: MapSet.new(), timer: nil}
  end

  defp maybe_mark_rescan(state, rel) do
    # Top-level entry (no slash): only rescan when this non-ignored directory is
    # not already covered by the recursive watch set (new dirs only — not
    # chmod/utimes/rename noise on existing top-level dirs).
    if rel != "" and not String.contains?(rel, "/") do
      abs = Path.join(state.root, rel)

      if File.dir?(abs) and not PathSafety.ignored_dir?(rel) and
           abs not in state.watched_dirs.recursive do
        %{state | needs_rescan: true}
      else
        state
      end
    else
      state
    end
  end

  defp schedule_flush(%{timer: nil, debounce_ms: ms} = state) do
    ref = Process.send_after(self(), :flush, ms)
    %{state | timer: ref}
  end

  defp schedule_flush(state), do: state

  defp schedule_maybe_stop(%{linger_ms: ms} = state) do
    _ = Process.send_after(self(), :maybe_stop, ms)
    state
  end

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
