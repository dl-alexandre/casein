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

  require Logger

  alias DevIDE.Terminals.Activity
  alias DevIDE.Terminals.SessionDirectory.Compose
  alias DevIDE.Terminals.SessionRegistry
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Git.Inspector, as: GitInspector

  @registry DevIDE.Terminals.Registry
  @supervisor DevIDE.Terminals.Supervisor
  @pubsub DevIde.PubSub
  @topic_prefix "terminal_tabs:"
  @poll_ms 2_000

  @doc "PubSub topic carrying `{:sessions_updated, workspace_id, tabs}`."
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @doc """
  Direct, processless read of the canonical tab list. Options:
  `:workspace_name` or `:workspace_names` — used for tmux session-name
  prefixes. The workspace id is always included as a stable fallback.
  """
  @spec read(String.t(), keyword()) :: [DevIDE.Terminals.Session.Info.t()]
  def read(workspace_id, opts \\ []) when is_binary(workspace_id) do
    workspace_names = workspace_names(workspace_id, opts)

    scanned = Compose.scan_tmux_sessions(list_tmux_sessions(), workspace_id, workspace_names)

    scanned
    |> Compose.compose(SessionRegistry.list_attachable(workspace_id))
    |> enrich_tabs()
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
    workspace_names = workspace_names(workspace_id, opts)
    tabs = read(workspace_id, workspace_names: workspace_names)

    {:ok,
     %{
       workspace_id: workspace_id,
       workspace_names: workspace_names,
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
    tabs = read(state.workspace_id, workspace_names: state.workspace_names)
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

  defp workspace_names(workspace_id, opts) do
    explicit = Keyword.get(opts, :workspace_names)

    names =
      if is_list(explicit) do
        explicit
      else
        [Keyword.get(opts, :workspace_name)]
      end

    names
    |> Kernel.++([workspace_id])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp key(workspace_id), do: {:session_directory, workspace_id}

  defp poll_ms do
    Application.get_env(:dev_ide, :session_directory_poll_ms, @poll_ms)
  end

  @doc false
  def list_tmux_sessions do
    adapter = tmux_adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :list_sessions, 0) do
      adapter.list_sessions()
    else
      []
    end
  end

  # Enrichment costs subprocesses: one batched tmux read covers every
  # session's windows and pane paths, instead of a `list-windows` +
  # `list-panes` subprocess pair per session on each 2s poll. Adapters
  # without the batch function fall back to the original per-session reads.
  defp enrich_tabs(tabs) do
    case directory_inventory() do
      {:ok, %{windows: windows_by_session, panes: panes_by_session}} ->
        Enum.map(tabs, fn tab ->
          tab
          |> put_session_cwd(session_entries(panes_by_session, tab))
          |> put_session_windows(session_entries(windows_by_session, tab))
        end)

      :error ->
        Enum.map(tabs, fn tab ->
          tab
          |> put_session_cwd(fallback_panes(tab))
          |> put_session_windows(fallback_windows(tab))
        end)
    end
  end

  defp session_entries(by_session, %{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "" do
    Map.get(by_session, tmux_session, [])
  end

  defp session_entries(_by_session, _tab), do: []

  defp fallback_panes(%{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "",
       do: list_session_panes(tmux_session)

  defp fallback_panes(_tab), do: []

  defp fallback_windows(%{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "",
       do: list_session_windows(tmux_session)

  defp fallback_windows(_tab), do: []

  defp directory_inventory do
    adapter = tmux_adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :directory_inventory, 0) do
      adapter.directory_inventory()
    else
      :error
    end
  rescue
    error ->
      Logger.warning("tmux directory inventory failed: #{Exception.message(error)}")
      :error
  end

  # Only identity-stable fields are kept in `metadata.windows` (no activity
  # timestamps or current command): it participates in `Compose.stable_hash/1`,
  # so volatile fields there would re-broadcast the tab list on every poll.
  # Activity timestamps go in `metadata.window_activity` instead — it is NOT
  # in the stable-hash allowlist, so it refreshes silently with each recompute
  # (the session picker forces one on open) without waking subscribers.
  #
  # `quiet` is the deliberate exception: `Activity.agent_window_quiet?/1`
  # quantizes the timestamp into a boolean that flips once per silence event,
  # so keeping it in the stable map broadcasts exactly when an agent goes
  # quiet (or resumes) and never in between.
  defp put_session_windows(
         %{tmux_session: tmux_session, metadata: metadata} = tab,
         [_ | _] = windows
       )
       when is_binary(tmux_session) and tmux_session != "" do
    activity =
      Map.new(windows, fn window ->
        {Map.get(window, :id) || Map.get(window, "id"),
         Map.get(window, :activity) || Map.get(window, "activity")}
      end)

    windows =
      Enum.map(windows, fn window ->
        %{
          id: Map.get(window, :id) || Map.get(window, "id"),
          index: Map.get(window, :index) || Map.get(window, "index"),
          name: Map.get(window, :name) || Map.get(window, "name"),
          active: truthy?(Map.get(window, :active) || Map.get(window, "active")),
          quiet: Activity.agent_window_quiet?(window)
        }
      end)

    metadata =
      (metadata || %{})
      |> Map.put(:windows, windows)
      |> Map.put(:window_activity, activity)

    %{tab | metadata: metadata}
  end

  defp put_session_windows(tab, _windows), do: tab

  defp list_session_windows(tmux_session) do
    adapter = tmux_adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :list_session_windows, 1) do
      adapter.list_session_windows(tmux_session)
    else
      []
    end
  rescue
    # Enrichment must never take down the directory (it polls every 2s and
    # tmux can vanish mid-call), but a swallowed error is invisible — log it.
    error ->
      Logger.warning(
        "session window enrichment failed for #{tmux_session}: #{Exception.message(error)}"
      )

      []
  end

  defp put_session_cwd(tab, panes) do
    case panes |> active_or_first_pane() |> pane_current_path() |> blank_to_nil() do
      cwd when is_binary(cwd) and cwd != "" ->
        metadata = tab.metadata || %{}
        %{tab | metadata: Map.merge(Map.put(metadata, :cwd, cwd), git_metadata(cwd))}

      _ ->
        tab
    end
  end

  defp list_session_panes(tmux_session) do
    adapter = tmux_adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :list_session_panes, 1) do
      adapter.list_session_panes(tmux_session)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "session cwd enrichment failed for #{tmux_session}: #{Exception.message(error)}"
      )

      []
  end

  defp active_or_first_pane(panes) when is_list(panes) do
    Enum.find(panes, &truthy?(Map.get(&1, :active) || Map.get(&1, "active"))) ||
      Enum.find(panes, fn pane ->
        not is_nil(
          pane
          |> pane_current_path()
          |> blank_to_nil()
        )
      end)
  end

  defp active_or_first_pane(_), do: nil

  defp pane_current_path(nil), do: nil

  defp pane_current_path(pane) when is_map(pane) do
    Map.get(pane, :current_path) || Map.get(pane, "current_path")
  end

  defp pane_current_path(_), do: nil

  defp git_metadata(cwd) do
    case GitInspector.inspect_cwd(cwd) do
      {:ok, info} ->
        %{
          git_toplevel: info.toplevel,
          git_dir: info.git_dir,
          git_common_dir: info.git_common_dir,
          git_branch: info.branch,
          git_head_sha: info.head_sha,
          git_worktree?: info.worktree?,
          git_detached?: info.detached?,
          agent: info.agent
        }

      :error ->
        %{}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp truthy?(value), do: value in [true, 1, "1", "true", "yes", "on"]

  defp tmux_adapter, do: Application.get_env(:dev_ide, :tmux_adapter, Tmux)
end
