defmodule DevIDE.Terminals.SessionDirectory do
  @moduledoc """
  Per-workspace source of truth for the terminal session tab list.

  Owns the canonical, viewer-independent list of attachable sessions for a
  workspace (live shells, agent worktree sessions, scanned tmux sessions —
  merged and deduplicated by `SessionDirectory.Compose`) and broadcasts changes:

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

  alias DevIDE.Agents.Transcripts
  alias DevIDE.Terminals.Activity
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.PaneState
  alias DevIDE.Terminals.SessionDirectory.Compose
  alias DevIDE.Terminals.SessionRegistry
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Git.Inspector, as: GitInspector
  alias DevIDE.Runtimes.WorktreeReconciler
  alias DevIDE.Terminals.Session.Info, as: SessionInfo

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
    tmux_sessions = Keyword.get_lazy(opts, :tmux_sessions, &list_tmux_sessions/0)

    scanned = Compose.scan_tmux_sessions(tmux_sessions, workspace_id, workspace_names)

    scanned
    |> Compose.compose(
      SessionRegistry.list_attachable(workspace_id) ++ agent_worktree_tabs(workspace_id)
    )
    |> enrich_tabs(opts)
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

  @doc """
  Forces a fresh recompute (broadcasting on change) and returns the tabs.

  The slow tmux read runs in the **caller** process, not inside the directory
  GenServer, so cheap `tabs/2` reads from other viewers of the same workspace
  are never queued behind it. The fresh list is then handed to the GenServer via
  a fast cast that updates the cache and broadcasts on change.
  """
  @spec refresh_now(String.t(), keyword()) :: [DevIDE.Terminals.Session.Info.t()]
  def refresh_now(workspace_id, opts \\ []) do
    case ensure_started(workspace_id, opts) do
      {:ok, pid} ->
        tabs = read(workspace_id, opts)
        # Fast synchronous store: updates the cache and broadcasts on change
        # before returning, so watchers are notified deterministically. The slow
        # work already happened above (in this process), so this call does not
        # block the GenServer's `:tabs` readers.
        :ok = GenServer.call(pid, {:store, tabs})
        tabs

      {:error, _reason} ->
        read(workspace_id, opts)
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

  @doc "Force worktree reconciliation, then refresh the canonical tab list."
  @spec refresh_worktrees(String.t()) :: :ok
  def refresh_worktrees(workspace_id) when is_binary(workspace_id) do
    _ = WorktreeReconciler.reconcile(workspace_id, force: true)
    refresh(workspace_id)
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
    # Defer the initial tmux read (a blocking subprocess) to handle_continue so
    # init returns immediately and DynamicSupervisor.start_child isn't
    # serialized on it. handle_continue runs before any queued call/cast, so a
    # caller's `:tabs` request still sees the populated cache.
    {:ok,
     %{
       workspace_id: workspace_id,
       workspace_names: workspace_names(workspace_id, opts),
       tabs: [],
       hash: Compose.stable_hash([]),
       watchers: %{},
       timer_ref: nil,
       computing?: false
     }, {:continue, :load_tabs}}
  end

  @impl true
  def handle_continue(:load_tabs, state) do
    tabs = read(state.workspace_id, workspace_names: state.workspace_names)
    {:noreply, %{state | tabs: tabs, hash: Compose.stable_hash(tabs)}}
  end

  @impl true
  def handle_call(:tabs, _from, state), do: {:reply, state.tabs, state}

  # Fast path: a caller (refresh_now/2) already did the slow tmux read; just
  # update the cache and broadcast on change. No subprocess work here, so this
  # never blocks `:tabs` readers — and it replies so the broadcast is delivered
  # before refresh_now/2 returns.
  def handle_call({:store, tabs}, _from, state), do: {:reply, :ok, apply_tabs(state, tabs)}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_async_recompute(state)}

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
    state = start_async_recompute(%{state | timer_ref: nil})

    if map_size(state.watchers) > 0 do
      {:noreply, schedule_poll(state)}
    else
      {:noreply, state}
    end
  end

  # Result of an async recompute (poll). `nil` means the read failed; keep the
  # last-known tabs and just clear the in-flight flag.
  def handle_info({:recomputed, nil}, state), do: {:noreply, %{state | computing?: false}}

  def handle_info({:recomputed, tabs}, state),
    do: {:noreply, %{apply_tabs(state, tabs) | computing?: false}}

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

  # Runs the slow tmux read in a throwaway process so the GenServer stays
  # responsive to `:tabs` reads while tmux is being enumerated. At most one
  # recompute is in flight at a time (`computing?`); overlapping polls are
  # dropped rather than stacked. The task always reports back (even on failure)
  # so the flag can never get stuck.
  defp start_async_recompute(%{computing?: true} = state), do: state

  defp start_async_recompute(state) do
    parent = self()
    workspace_id = state.workspace_id
    workspace_names = state.workspace_names

    spawn(fn ->
      tabs =
        try do
          read(workspace_id, workspace_names: workspace_names)
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      send(parent, {:recomputed, tabs})
    end)

    %{state | computing?: true}
  end

  # Fast: stores the freshly-read tabs and broadcasts only when the stable hash
  # changes. No tmux/subprocess work happens here, so it never blocks readers.
  defp apply_tabs(state, tabs) do
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

  defp agent_worktree_tabs(workspace_id) do
    workspace_id
    |> WorktreeReconciler.list_agent_worktrees()
    |> Enum.map(&agent_worktree_tab/1)
  end

  defp agent_worktree_tab(%{runtime_id: runtime_id} = worktree) do
    path = Map.get(worktree, :path)

    SessionInfo.new_shell(Map.get(worktree, :workspace_id), runtime_id,
      metadata: %{
        cwd: path,
        git_toplevel: Map.get(worktree, :git_toplevel) || path,
        git_common_dir: Map.get(worktree, :git_common_dir),
        git_branch: Map.get(worktree, :branch),
        git_head_sha: Map.get(worktree, :git_head_sha),
        git_worktree?: true,
        git_detached?: Map.get(worktree, :git_detached?),
        agent: Map.get(worktree, :agent),
        source: Map.get(worktree, :source),
        worktree_path: path,
        runtime_id: runtime_id,
        session_alias: Map.get(worktree, :path_label)
      }
    )
    |> Map.put(:tmux_session, Map.get(worktree, :tmux_session_id))
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
  defp enrich_tabs(tabs, opts) do
    case directory_inventory(opts) do
      {:ok, %{windows: windows_by_session, panes: panes_by_session}} ->
        Enum.map(tabs, fn tab ->
          {windows, panes} =
            scope_to_worktree(
              tab,
              session_entries(windows_by_session, tab),
              session_entries(panes_by_session, tab)
            )

          tab
          |> put_session_cwd(panes)
          |> put_session_windows(windows, panes)
          |> put_session_window_panes(panes)
        end)

      :error ->
        Enum.map(tabs, fn tab ->
          {windows, panes} = scope_to_worktree(tab, fallback_windows(tab), fallback_panes(tab))

          tab
          |> put_session_cwd(panes)
          |> put_session_windows(windows, panes)
          |> put_session_window_panes(panes)
        end)
    end
  end

  defp session_entries(by_session, %{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "" do
    Map.get(by_session, tmux_session, [])
  end

  defp session_entries(_by_session, _tab), do: []

  # A multi-agent run multiplexes many worktrees as sibling *windows* of one
  # operator tmux session, and every agent's `report_worktree` records that
  # shared session as its own `tmux_session_id`. Left unfiltered, each worktree
  # tab would inherit the whole session's window list (the "N windows on every
  # row" fan-out). When a worktree tab's session is demonstrably shared — some
  # of its panes are rooted OUTSIDE this worktree — narrow it to just the
  # window(s) actually rooted in this worktree. Tabs with no `worktree_path`
  # (scanned shells, including the operator/multiplexer row itself) and
  # sessions dedicated to a single worktree are left whole.
  defp scope_to_worktree(%{metadata: %{worktree_path: wt}}, windows, panes)
       when is_binary(wt) and wt != "" do
    case Enum.split_with(panes, &pane_under_path?(&1, wt)) do
      {_mine, []} ->
        {windows, panes}

      {mine, _foreign} ->
        own_window_ids =
          mine
          |> Enum.map(&pane_window_id/1)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {Enum.filter(windows, &MapSet.member?(own_window_ids, window_id(&1))),
         Enum.filter(panes, &MapSet.member?(own_window_ids, pane_window_id(&1)))}
    end
  end

  defp scope_to_worktree(_tab, windows, panes), do: {windows, panes}

  defp pane_under_path?(pane, root) do
    case pane_current_path(pane) do
      path when is_binary(path) and path != "" ->
        path == root or String.starts_with?(path, root <> "/")

      _ ->
        false
    end
  end

  defp window_id(window), do: Map.get(window, :id) || Map.get(window, "id")
  defp pane_window_id(pane), do: Map.get(pane, :window_id) || Map.get(pane, "window_id")

  defp fallback_panes(%{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "",
       do: list_session_panes(tmux_session)

  defp fallback_panes(_tab), do: []

  defp fallback_windows(%{tmux_session: tmux_session})
       when is_binary(tmux_session) and tmux_session != "",
       do: list_session_windows(tmux_session)

  defp fallback_windows(_tab), do: []

  @doc false
  def directory_inventory(opts \\ []) do
    case Keyword.fetch(opts, :directory_inventory) do
      {:ok, inventory} ->
        inventory

      :error ->
        fetch_directory_inventory()
    end
  end

  defp fetch_directory_inventory do
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
         [_ | _] = windows,
         panes
       )
       when is_binary(tmux_session) and tmux_session != "" do
    panes_by_window = panes_by_window_id(panes)

    activity =
      Map.new(windows, fn window ->
        {Map.get(window, :id) || Map.get(window, "id"),
         Map.get(window, :activity) || Map.get(window, "activity")}
      end)

    reports = AgentState.for_session(tmux_session)
    now = DateTime.utc_now()

    {windows, agent_state_messages} =
      Enum.map_reduce(windows, %{}, fn window, messages ->
        id = Map.get(window, :id) || Map.get(window, "id")
        window = Map.put(window, :pane_list, Map.get(panes_by_window, id, []))
        pane_state = PaneState.window_state(window)
        task_summary = PaneState.window_task_summary(window)

        {agent_state, agent_message} =
          resolve_window_agent_state(window, pane_state, reports, now)

        window_map =
          %{
            id: id,
            index: Map.get(window, :index) || Map.get(window, "index"),
            name: Map.get(window, :name) || Map.get(window, "name"),
            active: truthy?(Map.get(window, :active) || Map.get(window, "active")),
            quiet: Activity.agent_window_quiet?(window)
          }
          |> put_known_pane_state(pane_state)
          |> put_known_agent_state(agent_state)
          |> put_present(:task_summary, task_summary)
          |> put_manual_name(window)

        {window_map, put_present_message(messages, id, agent_message)}
      end)

    metadata =
      (metadata || %{})
      |> Map.put(:windows, windows)
      |> Map.put(:window_activity, activity)
      |> Map.put(:agent_state_messages, agent_state_messages)

    %{tab | metadata: metadata}
  end

  defp put_session_windows(tab, _windows, _panes), do: tab

  defp resolve_window_agent_state(window, pane_state, reports, now) do
    entry =
      case PaneState.agent_or_active_pane(window) do
        nil -> nil
        pane -> Map.get(reports, PaneState.map_get(pane, :id))
      end

    {state, message} = AgentState.resolve_for_display(entry, pane_state, now)
    {state, message || transcript_activity_message(entry, state)}
  end

  defp transcript_activity_message(%{transcript_path: path, state: :working}, :working)
       when is_binary(path) and path != "" do
    Transcripts.activity_hint(path)
  end

  defp transcript_activity_message(%{transcript_path: path}, :working)
       when is_binary(path) and path != "" do
    Transcripts.activity_hint(path)
  end

  defp transcript_activity_message(_entry, _state), do: nil

  # Pane→window membership and pane summaries live OUTSIDE `metadata.windows`
  # (the `Compose.stable_hash/1` allowlist) so pane churn never re-broadcasts
  # the tab list. The session picker joins these ids against the live preview
  # registry at render time to flag windows hosting a running preview, the same
  # sky badge the window picker shows. Pane summaries are safe, path-free
  # fields used by agent layout readiness checks.
  defp put_session_window_panes(%{metadata: metadata} = tab, panes) when is_list(panes) do
    grouped =
      panes
      |> Enum.reduce(%{}, fn pane, acc ->
        window_id = Map.get(pane, :window_id) || Map.get(pane, "window_id")
        pane_id = Map.get(pane, :id) || Map.get(pane, "id")

        if is_binary(window_id) and window_id != "" and is_binary(pane_id) and pane_id != "" do
          Map.update(acc, window_id, [pane_id], &[pane_id | &1])
        else
          acc
        end
      end)
      |> Map.new(fn {window_id, pane_ids} -> {window_id, Enum.reverse(pane_ids)} end)

    metadata =
      (metadata || %{})
      |> Map.put(:window_panes, grouped)
      |> Map.put(:pane_summaries, Enum.map(panes, &safe_pane_summary/1))

    %{tab | metadata: metadata}
  end

  defp put_session_window_panes(tab, _panes), do: tab

  defp safe_pane_summary(pane) when is_map(pane) do
    pane = PaneState.enrich_pane(pane)

    %{
      id: Map.get(pane, :id) || Map.get(pane, "id"),
      window_id: Map.get(pane, :window_id) || Map.get(pane, "window_id"),
      index: Map.get(pane, :index) || Map.get(pane, "index"),
      active: truthy?(Map.get(pane, :active) || Map.get(pane, "active")),
      current_command: Map.get(pane, :current_command) || Map.get(pane, "current_command"),
      role: Map.get(pane, :role) || Map.get(pane, "role"),
      pane_title: Map.get(pane, :pane_title) || Map.get(pane, "pane_title"),
      pane_state: Map.get(pane, :pane_state) || Map.get(pane, "pane_state"),
      task_summary: Map.get(pane, :task_summary) || Map.get(pane, "task_summary")
    }
    |> Enum.reject(fn
      {_key, value} when value in [nil, "", :unknown, "unknown"] -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp safe_pane_summary(_pane), do: %{}

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

  defp panes_by_window_id(panes) when is_list(panes) do
    panes
    |> Enum.group_by(&(Map.get(&1, :window_id) || Map.get(&1, "window_id")))
    |> Map.delete(nil)
  end

  defp panes_by_window_id(_panes), do: %{}

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

  defp put_known_pane_state(map, state) when state in [:working, :ready] do
    Map.put(map, :pane_state, state)
  end

  defp put_known_pane_state(map, _state), do: map

  # `agent_state` is a low-cardinality atom that flips once per semantic
  # transition, so it belongs in the stable window map (broadcasts on transition,
  # not every poll). `:unknown` is omitted to keep hashes compact.
  defp put_known_agent_state(map, state) when state in [:working, :blocked, :done, :idle] do
    Map.put(map, :agent_state, state)
  end

  defp put_known_agent_state(map, _state), do: map

  # Messages are volatile free text; they live outside the stable-hash allowlist
  # so they refresh silently without re-broadcasting the tab list.
  defp put_present_message(messages, id, message)
       when is_binary(id) and is_binary(message) and message != "",
       do: Map.put(messages, id, message)

  defp put_present_message(messages, _id, _message), do: messages

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Deliberately named windows (tmux automatic-rename off) keep their name as
  # the picker label, so the flag travels with the stable window map. Only the
  # `true` case is stored to avoid re-hashing every auto-named window.
  defp put_manual_name(map, window) do
    if truthy?(Map.get(window, :manual_name) || Map.get(window, "manual_name")) do
      Map.put(map, :manual_name, true)
    else
      map
    end
  end

  defp truthy?(value), do: value in [true, 1, "1", "true", "yes", "on"]

  defp tmux_adapter, do: Application.get_env(:dev_ide, :tmux_adapter, Tmux)
end
