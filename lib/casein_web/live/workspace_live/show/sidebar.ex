defmodule CaseinWeb.WorkspaceLive.Show.Sidebar do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [connected?: 1, push_event: 3, push_navigate: 2, put_flash: 3, start_async: 3]

  alias Casein.Terminals
  alias Casein.Terminals.SessionDirectory
  alias Casein.Workspaces
  alias Casein.Workspaces.SessionSummary
  alias CaseinWeb.WorkspaceLive.Show.Browse
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM
  alias CaseinWeb.WorkspaceRoutes

  @type sidebar_mode :: :closed | :windows_only | :both

  @spec initial_assigns() :: keyword()
  def initial_assigns do
    [
      sidebar_mode: :closed,
      window_sidebar_open?: false,
      sessions_sidebar_open?: false,
      sidebar_expanded_workspaces: MapSet.new(),
      sidebar_expanded_windows: MapSet.new(),
      sidebar_expanded_dirs: MapSet.new(),
      sidebar_ws_sessions: %{},
      sidebar_ws_warm_pending: MapSet.new(),
      sidebar_browse_cache: nil,
      sidebar_ws_subscriptions: MapSet.new(),
      sessions_sidebar_tree: [],
      sessions_sidebar_needs_you: [],
      windows_sidebar_tree: [],
      sessions_sidebar_sort: :recency,
      windows_sidebar_sort: :recency
    ]
  end

  @spec open(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  @spec open(Phoenix.LiveView.Socket.t(), String.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def open(socket, mode, opts \\ []) when mode in ["windows", "both"] do
    sidebar_mode =
      case mode do
        "both" -> :both
        _ -> :windows_only
      end

    current_id = socket.assigns.workspace.id

    expanded =
      socket.assigns.sidebar_expanded_workspaces
      |> then(fn set ->
        if sidebar_mode == :both, do: MapSet.put(set, current_id), else: set
      end)

    expanded_windows = expanded_windows_on_open(socket)

    focus =
      case Keyword.get(opts, :focus) do
        :sessions -> :sessions
        :windows -> :windows
        "sessions" -> :sessions
        "windows" -> :windows
        _ -> if(sidebar_mode == :both, do: :sessions, else: nil)
      end

    socket =
      socket
      |> assign_sidebar_mode(sidebar_mode)
      |> assign(:sidebar_expanded_workspaces, expanded)
      |> assign(:sidebar_expanded_windows, expanded_windows)
      |> assign_sessions_sidebar_tree()
      |> assign_windows_sidebar_tree()

    socket =
      if sidebar_mode == :both,
        do: warm_sidebar_ws_sessions(socket),
        else: socket

    case focus do
      :sessions -> push_event(socket, "sidebar:focus_sessions", %{})
      :windows -> push_event(socket, "sidebar:focus_windows", %{})
      _ -> socket
    end
  end

  @doc """
  Hide the rails without discarding what they know.

  Closing used to reset every sidebar assign, so the next `C-b s` repainted from
  an empty tree and waited on a fresh `SessionSummary.build_many/1` (a `git
  branch` + `git status` per workspace) before showing a single row — and it
  also threw away everything `warm_sessions/1` had just prefetched. The rail is
  the primary session-switching surface, so the tree, the per-workspace session
  cache, and the expansion state now survive a close and act as warm paint.
  Live subscriptions stay up too, which keeps that cache honest while the rail
  is hidden; reopening still refreshes, but it corrects an already-rendered list
  instead of filling a blank one.

  Still dropped on close: the windows tree (rebuilt from `tmux_window_tabs` on
  open, so holding it would pin stale topology) and the Browse memo (a
  filesystem scan that should not outlive the rail session).
  """
  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> assign_sidebar_mode(:closed)
    |> assign(:sidebar_expanded_windows, MapSet.new())
    # Bound the Browse memo to one rail session: hot for the expand/collapse/sort
    # churn that motivated it, re-scanned the next time the rail is summoned.
    |> invalidate_browse_cache()
    |> assign(:windows_sidebar_tree, [])

    # NB: the sort modes intentionally survive a close — reopening the rail keeps
    # the user's chosen order (persisted across page loads via the client, see
    # set_sessions_sort/3 + restore_sort/3).
  end

  # Miller-style Left out of the WINDOWS rail when the SESSIONS rail is not in
  # the DOM yet (window_picker_sidebar.js `_focusSessionsRail`). This is the
  # common way the rail is first summoned, and it used to skip the warm-up that
  # open/3 does — so every foreign workspace stayed cold and each expansion paid
  # a fresh SessionDirectory round-trip. Warm here too.
  @spec reveal_sessions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reveal_sessions(socket) do
    current_id = socket.assigns.workspace.id

    socket
    |> assign_sidebar_mode(:both)
    |> assign(
      :sidebar_expanded_workspaces,
      MapSet.put(socket.assigns.sidebar_expanded_workspaces, current_id)
    )
    |> assign_sessions_sidebar_tree()
    |> warm_sidebar_ws_sessions()
    |> push_event("sidebar:focus_sessions", %{})
  end

  @spec toggle_window(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_window(socket, window_id) when is_binary(window_id) do
    expanded = socket.assigns.sidebar_expanded_windows

    expanded =
      if MapSet.member?(expanded, window_id) do
        MapSet.delete(expanded, window_id)
      else
        MapSet.put(expanded, window_id)
      end

    socket
    |> assign(:sidebar_expanded_windows, expanded)
    |> assign_windows_sidebar_tree()
  end

  @spec assign_windows_sidebar_tree(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_windows_sidebar_tree(socket) do
    tree =
      if Map.get(socket.assigns, :window_sidebar_open?, false) do
        socket.assigns.tmux_window_tabs
        |> SessionBarVM.window_tree(expanded_windows: socket.assigns.sidebar_expanded_windows)
        |> SessionBarVM.sort_window_tree(socket.assigns.windows_sidebar_sort)
      else
        []
      end

    assign(socket, :windows_sidebar_tree, tree)
  end

  @sort_modes [:recency, :name, :liveness]

  @spec cycle_sessions_sort(Phoenix.LiveView.Socket.t(), :forward | :backward) ::
          Phoenix.LiveView.Socket.t()
  def cycle_sessions_sort(socket, direction \\ :forward),
    do:
      set_sessions_sort(
        socket,
        SessionBarVM.cycle_sort_mode(socket.assigns.sessions_sidebar_sort, direction)
      )

  @spec cycle_windows_sort(Phoenix.LiveView.Socket.t(), :forward | :backward) ::
          Phoenix.LiveView.Socket.t()
  def cycle_windows_sort(socket, direction \\ :forward),
    do:
      set_windows_sort(
        socket,
        SessionBarVM.cycle_sort_mode(socket.assigns.windows_sidebar_sort, direction)
      )

  @doc "Set the SESSIONS sort mode, rebuild the tree, and (by default) persist it client-side."
  @spec set_sessions_sort(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def set_sessions_sort(socket, mode, opts \\ [])

  def set_sessions_sort(socket, mode, opts) when mode in @sort_modes do
    socket
    |> assign(:sessions_sidebar_sort, mode)
    |> assign_sessions_sidebar_tree()
    |> maybe_persist_sort("sessions", mode, opts)
  end

  def set_sessions_sort(socket, _mode, _opts), do: socket

  @doc "Set the WINDOWS sort mode, rebuild the tree, and (by default) persist it client-side."
  @spec set_windows_sort(Phoenix.LiveView.Socket.t(), atom(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def set_windows_sort(socket, mode, opts \\ [])

  def set_windows_sort(socket, mode, opts) when mode in @sort_modes do
    socket
    |> assign(:windows_sidebar_sort, mode)
    |> assign_windows_sidebar_tree()
    |> maybe_persist_sort("windows", mode, opts)
  end

  def set_windows_sort(socket, _mode, _opts), do: socket

  @doc "Apply a client-restored sort mode without echoing it back to the client."
  @spec restore_sort(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def restore_sort(socket, "sessions", mode),
    do: set_sessions_sort(socket, parse_sort_mode(mode), persist: false)

  def restore_sort(socket, "windows", mode),
    do: set_windows_sort(socket, parse_sort_mode(mode), persist: false)

  def restore_sort(socket, _col, _mode), do: socket

  defp maybe_persist_sort(socket, col, mode, opts) do
    if Keyword.get(opts, :persist, true) do
      push_event(socket, "sidebar:persist_sort", %{col: col, mode: Atom.to_string(mode)})
    else
      socket
    end
  end

  defp parse_sort_mode("name"), do: :name
  defp parse_sort_mode("liveness"), do: :liveness
  defp parse_sort_mode(_), do: :recency

  @spec toggle_workspace(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_workspace(socket, workspace_id) when is_binary(workspace_id) do
    expanded = socket.assigns.sidebar_expanded_workspaces

    if MapSet.member?(expanded, workspace_id) do
      collapse_workspace(socket, workspace_id)
    else
      expand_workspace(socket, workspace_id)
    end
  end

  @spec assign_sessions_sidebar_tree(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_sessions_sidebar_tree(socket) do
    socket = ensure_current_workspace_summary(socket)
    viewer = socket.assigns[:current_user]

    summaries =
      SessionBarVM.sort_workspace_summaries_for_sidebar(
        socket.assigns.workspace_summaries,
        socket.assigns.sessions_sidebar_sort,
        socket.assigns.workspace.id,
        viewer
      )

    session_tree =
      summaries
      |> SessionBarVM.workspace_session_tree(
        socket.assigns.workspace.id,
        expanded_workspaces: socket.assigns.sidebar_expanded_workspaces,
        current_session_tabs: socket.assigns.session_tabs,
        sidebar_ws_sessions: socket.assigns.sidebar_ws_sessions,
        viewer: viewer
      )
      |> SessionBarVM.sort_sessions_in_tree(socket.assigns.sessions_sidebar_sort)

    {socket, browse_tree} = browse_tier(socket, summaries, viewer)

    needs_you =
      SessionBarVM.needs_you_strip(
        socket.assigns.session_tabs,
        socket.assigns.workspace.id,
        sidebar_ws_sessions: socket.assigns.sidebar_ws_sessions,
        summaries: summaries
      )

    socket
    |> assign(:sessions_sidebar_tree, session_tree ++ browse_tree)
    |> assign(:sessions_sidebar_needs_you, needs_you)
  end

  # `Browse.browse_tier/1` walks the filesystem (File.ls + a File.dir? per
  # entry) and this function runs on EVERY rebuild — each expand, collapse,
  # sort cycle and async merge — so plain arrow-key navigation was paying for a
  # directory scan it could not have changed. Memoize on the inputs that can
  # actually change the tier; a hit skips the I/O entirely.
  defp browse_tier(socket, summaries, viewer) do
    root = Browse.root()
    expanded_dirs = socket.assigns.sidebar_expanded_dirs
    key = {root, expanded_dirs, viewer, Enum.map(summaries, &summary_path/1)}

    case socket.assigns[:sidebar_browse_cache] do
      {^key, tree} ->
        {socket, tree}

      _ ->
        tree =
          Browse.browse_tier(
            root: root,
            expanded_dirs: expanded_dirs,
            viewer: viewer,
            workspaces: summaries
          )

        {assign(socket, :sidebar_browse_cache, {key, tree}), tree}
    end
  end

  @doc "Force the next tree rebuild to re-scan the Browse tier from disk."
  @spec invalidate_browse_cache(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def invalidate_browse_cache(socket), do: assign(socket, :sidebar_browse_cache, nil)

  defp summary_path(summary) when is_map(summary) do
    Map.get(summary, :path) || Map.get(summary, "path") || Map.get(summary, :host_path) ||
      Map.get(summary, "host_path")
  end

  defp summary_path(_), do: nil

  @doc "Toggle expansion of a Browse-tier directory (empty string = browse root)."
  @spec toggle_browse_dir(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_browse_dir(socket, rel) when is_binary(rel) do
    expanded = socket.assigns.sidebar_expanded_dirs

    expanded =
      if MapSet.member?(expanded, rel) do
        MapSet.delete(expanded, rel)
      else
        MapSet.put(expanded, rel)
      end

    socket
    |> assign(:sidebar_expanded_dirs, expanded)
    |> assign_sessions_sidebar_tree()
  end

  @doc """
  Open a terminal on an arbitrary local folder via folder-attach.

  Same gesture as the dashboard `folder:open` path — attaches and navigates
  to the synthetic `folder:` workspace.
  """
  @spec open_folder(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open_folder(socket, path) when is_binary(path) do
    case Workspaces.attach_folder(path) do
      {:ok, ws} ->
        push_navigate(socket, to: WorkspaceRoutes.workspace_path(ws, "local"))

      {:error, reason} ->
        put_flash(socket, :error, "Could not open terminal: #{inspect(reason)}")
    end
  end

  @spec assign_sidebar_ws_sessions(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          [map()]
        ) :: Phoenix.LiveView.Socket.t()
  def assign_sidebar_ws_sessions(socket, workspace_id, infos) when is_list(infos) do
    assign(
      socket,
      :sidebar_ws_sessions,
      Map.put(
        socket.assigns.sidebar_ws_sessions,
        workspace_id,
        ws_session_tabs(socket, workspace_id, infos)
      )
    )
  end

  defp ws_session_tabs(socket, workspace_id, infos) do
    summary = find_summary(socket, workspace_id)
    workspace_name = summary_workspace_name(summary, workspace_id)
    default_sid = SessionSummary.newest_shell_sid(workspace_id, workspace_name)

    infos
    |> Terminals.visible_tabs(default_sid)
    |> SessionBarVM.session_tabs()
  end

  # Opening the sessions rail lazily loaded each workspace's session list only
  # on expand — an async round-trip per row, felt as "expanding is slow" while
  # picking. Warm the cache as the rail opens so expansion renders instantly
  # from `sidebar_ws_sessions`. Results merge under already-loaded entries (an
  # expand in flight wins), and the whole cache is dropped on close/1.
  #
  # The warm used to be ONE task doing all 24 reads sequentially, merging only
  # once every read finished — so the whole rail stayed cold until the slowest
  # foreign workspace answered, and the 24 were taken in raw `workspace_summaries`
  # order (not the rail's order), so which ones warmed at all was arbitrary.
  # It now runs in small batches, ordered the way the rail is ordered — the
  # viewer's own workspaces first — and each batch merges the moment it lands,
  # so your own sessions become navigable while everyone else's are still loading.
  @sidebar_warm_limit 24
  @sidebar_warm_batch 4

  @doc """
  Warm session lists for the rail's other workspaces, viewer's own first.

  Safe to call repeatedly: workspaces already loaded or already in flight are
  skipped, so a late `workspace_summaries` refresh only warms what it added.
  """
  @spec warm_sessions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def warm_sessions(socket) do
    if socket.assigns[:sessions_sidebar_open?], do: warm_sidebar_ws_sessions(socket), else: socket
  end

  defp warm_sidebar_ws_sessions(socket) do
    current_id = socket.assigns.workspace.id
    loaded = socket.assigns.sidebar_ws_sessions
    in_flight = socket.assigns[:sidebar_ws_warm_pending] || MapSet.new()
    viewer = socket.assigns[:current_user]

    {mine, others} =
      SessionBarVM.partition_viewer_workspaces(socket.assigns.workspace_summaries, viewer)

    candidates =
      (mine ++ others)
      |> Enum.filter(fn summary ->
        id = summary_id(summary)

        is_binary(id) and id != current_id and not Map.has_key?(loaded, id) and
          not MapSet.member?(in_flight, id) and
          (Map.get(summary, :live?, false) == true or
             (Map.get(summary, :session_count) || 0) > 0)
      end)
      |> Enum.take(@sidebar_warm_limit)
      |> Enum.map(fn summary ->
        id = summary_id(summary)
        {id, summary_workspace_name(summary, id)}
      end)

    candidates
    |> Enum.chunk_every(@sidebar_warm_batch)
    |> Enum.reduce(socket, fn batch, acc ->
      ids = Enum.map(batch, &elem(&1, 0))

      acc
      |> assign(
        :sidebar_ws_warm_pending,
        MapSet.union(acc.assigns[:sidebar_ws_warm_pending] || MapSet.new(), MapSet.new(ids))
      )
      |> start_async({:sidebar_ws_warm, ids}, fn ->
        Map.new(batch, fn {id, name} ->
          {id, SessionDirectory.read(id, workspace_name: name)}
        end)
      end)
    end)
  end

  @doc "Merge one completed rail warm batch (`{:sidebar_ws_warm, ids}`) into the cache."
  @spec handle_async_warm(Phoenix.LiveView.Socket.t(), [String.t()], {:ok, map()} | term()) ::
          Phoenix.LiveView.Socket.t()
  def handle_async_warm(socket, ids, {:ok, infos_by_ws}) when is_map(infos_by_ws) do
    loaded = socket.assigns.sidebar_ws_sessions

    merged =
      Enum.reduce(infos_by_ws, loaded, fn {workspace_id, infos}, acc ->
        if Map.has_key?(acc, workspace_id) or not is_list(infos) do
          acc
        else
          Map.put(acc, workspace_id, ws_session_tabs(socket, workspace_id, infos))
        end
      end)

    socket
    |> clear_warm_pending(ids)
    |> assign(:sidebar_ws_sessions, merged)
    |> assign_sessions_sidebar_tree()
  end

  def handle_async_warm(socket, ids, _result), do: clear_warm_pending(socket, ids)

  defp clear_warm_pending(socket, ids) when is_list(ids) do
    pending = socket.assigns[:sidebar_ws_warm_pending] || MapSet.new()
    assign(socket, :sidebar_ws_warm_pending, MapSet.difference(pending, MapSet.new(ids)))
  end

  defp clear_warm_pending(socket, _ids), do: socket

  @spec handle_async_sessions(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          {:ok, [map()]} | {:error, term()}
        ) :: Phoenix.LiveView.Socket.t()
  def handle_async_sessions(socket, workspace_id, {:ok, infos}) when is_list(infos) do
    socket
    |> assign_sidebar_ws_sessions(workspace_id, infos)
    |> assign_sessions_sidebar_tree()
  end

  # A failed read must resolve to a definite *error* state — never to an empty
  # list that renders as "No live sessions". Empty means the load succeeded and
  # there are none; error means we could not observe. Set the map directly (not
  # via assign_sidebar_ws_sessions, which would trigger a second SessionDirectory
  # read that could fail the same way).
  def handle_async_sessions(socket, workspace_id, {:error, reason})
      when is_binary(workspace_id) do
    socket
    |> assign(
      :sidebar_ws_sessions,
      Map.put(socket.assigns.sidebar_ws_sessions, workspace_id, {:error, reason})
    )
    |> assign_sessions_sidebar_tree()
  end

  def handle_async_sessions(socket, workspace_id, _error) when is_binary(workspace_id) do
    handle_async_sessions(socket, workspace_id, {:error, :failed})
  end

  def handle_async_sessions(socket, _workspace_id, _error) do
    assign_sessions_sidebar_tree(socket)
  end

  @spec sessions_updated(Phoenix.LiveView.Socket.t(), String.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def sessions_updated(socket, workspace_id, tabs) when is_list(tabs) do
    if MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
      |> assign_sidebar_ws_sessions(workspace_id, tabs)
      |> assign_sessions_sidebar_tree()
    else
      socket
    end
  end

  @spec maybe_focus_windows_after_attach(Phoenix.LiveView.Socket.t(), boolean()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_focus_windows_after_attach(socket, _attach?) do
    if socket.assigns.window_sidebar_open? do
      push_event(socket, "sidebar:focus_windows", %{})
    else
      socket
    end
  end

  defp assign_sidebar_mode(socket, mode) when mode in [:closed, :windows_only, :both] do
    socket
    |> assign(:sidebar_mode, mode)
    |> assign(:window_sidebar_open?, mode in [:windows_only, :both])
    |> assign(:sessions_sidebar_open?, mode == :both)
  end

  defp expand_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    socket =
      socket
      |> assign(
        :sidebar_expanded_workspaces,
        MapSet.put(socket.assigns.sidebar_expanded_workspaces, workspace_id)
      )
      |> assign_sessions_sidebar_tree()

    if workspace_id == current_id do
      socket
    else
      summary = find_summary(socket, workspace_id)
      workspace_name = summary_workspace_name(summary, workspace_id)

      socket
      |> subscribe_sidebar_workspace(workspace_id)
      |> start_async({:sidebar_ws_sessions, workspace_id}, fn ->
        SessionDirectory.read(workspace_id, workspace_name: workspace_name)
      end)
    end
  end

  defp collapse_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    socket =
      socket
      |> assign(
        :sidebar_expanded_workspaces,
        MapSet.delete(socket.assigns.sidebar_expanded_workspaces, workspace_id)
      )
      |> then(fn sock ->
        if workspace_id == current_id do
          sock
        else
          sock
          |> unsubscribe_sidebar_workspace(workspace_id)
          |> assign(
            :sidebar_ws_sessions,
            Map.delete(sock.assigns.sidebar_ws_sessions, workspace_id)
          )
        end
      end)
      |> assign_sessions_sidebar_tree()

    socket
  end

  defp subscribe_sidebar_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    if workspace_id == current_id or
         MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
    else
      summary = find_summary(socket, workspace_id)
      workspace_name = summary_workspace_name(summary, workspace_id)

      if connected?(socket) do
        _ =
          Terminals.subscribe_session_tabs(workspace_id,
            workspace_name: workspace_name
          )
      end

      assign(
        socket,
        :sidebar_ws_subscriptions,
        MapSet.put(socket.assigns.sidebar_ws_subscriptions, workspace_id)
      )
    end
  end

  defp unsubscribe_sidebar_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    if workspace_id == current_id or
         not MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
    else
      if connected?(socket) do
        :ok = Terminals.unsubscribe_session_tabs(workspace_id)
      end

      assign(
        socket,
        :sidebar_ws_subscriptions,
        MapSet.delete(socket.assigns.sidebar_ws_subscriptions, workspace_id)
      )
    end
  end

  defp ensure_current_workspace_summary(socket) do
    ws = socket.assigns.workspace
    current_id = ws.id

    if Enum.any?(socket.assigns.workspace_summaries, &(summary_id(&1) == current_id)) do
      socket
    else
      assign(socket, :workspace_summaries, [
        %{
          id: current_id,
          name: ws.name || current_id,
          session_count: length(socket.assigns.session_tabs),
          live?: true,
          sessions: []
        }
      ])
    end
  end

  defp find_summary(socket, workspace_id) do
    Enum.find(socket.assigns.workspace_summaries, &(summary_id(&1) == workspace_id))
  end

  defp summary_id(summary),
    do: Map.get(summary, :id) || Map.get(summary, "id")

  defp summary_workspace_name(summary, workspace_id) do
    name = Map.get(summary, :name) || Map.get(summary, "name")
    if is_binary(name) and name != "", do: name, else: workspace_id
  end

  defp expanded_windows_on_open(socket) do
    case Enum.find(socket.assigns.tmux_window_tabs || [], & &1.active?) do
      %{id: window_id, pane_count: count} when count > 1 ->
        MapSet.put(socket.assigns.sidebar_expanded_windows, window_id)

      _ ->
        socket.assigns.sidebar_expanded_windows
    end
  end
end
