defmodule CaseinWeb.WorkspaceLive.Show.TerminalState do
  # Terminal/tmux socket-state helpers extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  @moduledoc false

  use CaseinWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Attention.Policy, as: AttentionPolicy
  alias Casein.Codex.SessionTitles
  alias Casein.Terminals
  alias Casein.Terminals.WindowTrash
  alias Casein.Labels
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM
  alias CaseinWeb.WorkspaceLive.Show.Sidebar
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome
  alias CaseinWeb.WorkspaceLive.Show.ViewDeepLink
  alias CaseinWeb.WorkspaceLive.Show.WindowTerminalMode

  def tmux_adapter do
    Terminals.tmux_adapter()
  end

  @doc """
  Re-applies topology after a tmux mutation.

  Connected sockets refresh through the session's shared watcher: the tmux
  read runs in the watcher process (one merged subprocess) and its change
  broadcast updates every other viewer, instead of each event forking a
  private subprocess pair on the LiveView. Disconnected renders keep the
  direct snapshot — no watcher exists for them.
  """
  def refresh_tmux_topology(socket, opts \\ []) do
    session = socket.assigns.tmux_session

    topology =
      if connected?(socket) do
        Terminals.tmux_topology_refresh_now(session, workspace_id: socket.assigns.workspace.id)
      else
        Terminals.tmux_topology_snapshot(session)
      end

    assign_tmux_topology(socket, topology, opts)
  end

  def assign_tmux_topology(socket, topology, opts \\ []) do
    topology = hide_trashed_windows(topology)

    if is_binary(topology.session) do
      pane_ids = Enum.map(topology.panes, &Map.get(&1, :id))
      Labels.prune_session(topology.session, pane_ids)
    end

    prev_window = socket.assigns[:tmux_active_window_id]
    prev_active_pane = socket.assigns[:tmux_active_pane_id]

    # Merged occupancy of preview + file panes: neither may host the Ghostty
    # surface or count as an operator pane for focus purposes.
    feature_panes =
      TerminalChrome.feature_pane_map(
        socket.assigns[:preview_panes] || %{},
        socket.assigns[:feature_panes] || %{}
      )

    # A real window switch (not the first load) — covers every path that
    # changes the active window: the dropdown, cycle/last, URL navigation, and
    # tmux switching it out from under us. The UI-only pane selection
    # (ui_highlight_pane_id / entered_preview_pane_id) is window-scoped, so it
    # must be re-seated on the new window or it strands the prior window's pane
    # id — leaving the new window with nothing highlighted and the preview
    # titlebar still showing the old window's preview.
    window_changed? = not is_nil(prev_window) and prev_window != topology.active_window_id

    active_window_panes = TerminalChrome.active_tmux_window_panes(topology.windows)

    socket
    |> assign(:tmux_windows, topology.windows)
    |> assign(:tmux_panes, topology.panes)
    |> assign_header_session_labels(topology)
    |> assign(:tmux_active_window_id, topology.active_window_id)
    |> assign(:tmux_active_pane_id, topology.active_pane_id)
    |> assign(
      :terminal_surface_pane_id,
      TerminalChrome.terminal_surface_pane_id(
        active_window_panes,
        feature_panes,
        topology.active_pane_id,
        socket.assigns[:terminal_surface_pane_id]
      )
    )
    |> sync_ui_highlight_pane_id(
      topology.active_pane_id,
      prev_active_pane,
      feature_panes,
      window_changed?
    )
    |> reset_entered_preview_on_window_change(window_changed?)
    |> assign(:window_zoomed?, active_pane_zoomed?(topology))
    |> then(fn s ->
      if prev_window != topology.active_window_id do
        s
        |> WindowTerminalMode.on_active_window_changed(
          prev_window,
          topology.active_window_id
        )
      else
        s
      end
    end)
    |> update_active_session_tab_cwd(topology)
    |> assign_page_title()
    |> assign(:tmux_topology_version, topology.version)
    # Structure-only version for DOM consumers (window dropdown data-version):
    # stable across activity-only polls. Falls back to the full version for
    # topology maps that predate the field (hydration payloads, test fixtures).
    |> assign(
      :tmux_topology_structure_version,
      Map.get(topology, :structure_version, topology.version)
    )
    # Layout-only version for optimistic pane mutations. Unlike the full
    # topology version it ignores terminal activity/command churn, but it
    # changes for geometry, selection, pane identity, and zoom changes.
    |> assign(
      :tmux_topology_layout_version,
      Map.get(topology, :layout_version, topology.version)
    )
    # Direct snapshot reads carry no generation; keep the stored one then.
    |> assign(
      :tmux_topology_generation,
      Map.get(topology, :generation, socket.assigns[:tmux_topology_generation])
    )
    |> restore_operator_tmux_focus(feature_panes)
    |> maybe_acknowledge_focused_active_quiet_window()
    |> assign_tmux_window_tabs()
    |> refresh_session_tab_attention()
    |> ViewDeepLink.apply_pending_url_view()
    |> ViewDeepLink.apply_pending_url_recovery()
    |> maybe_patch_idle_view_url(opts)
  end

  # A window closed with the undoable path is still fully alive in tmux during
  # its grace period — it is only withheld from viewers, so it can be brought
  # back intact. Filtering here rather than at each call site means every
  # surface fed by topology (tab strip, window picker, sidebar tree, pane
  # overlay) hides it together, on the synchronous refresh and the watcher
  # broadcast alike.
  defp hide_trashed_windows(%{session: session, windows: windows} = topology)
       when is_binary(session) and is_list(windows) do
    case WindowTrash.reject_pending(session, windows) do
      ^windows ->
        topology

      visible ->
        visible_ids = MapSet.new(visible, & &1.id)

        topology
        |> Map.put(:windows, visible)
        |> Map.put(
          :panes,
          Enum.filter(topology.panes || [], &MapSet.member?(visible_ids, &1.window_id))
        )
        |> reseat_active_window(visible, visible_ids)
    end
  end

  defp hide_trashed_windows(topology), do: topology

  # Defensive only: trashing the active window also moves tmux's own selection
  # (see TerminalEvents), so by the next topology read the active id normally
  # already points somewhere visible. This covers the gap between the two, and
  # any topology snapshot taken mid-flight.
  defp reseat_active_window(topology, visible, visible_ids) do
    if is_nil(topology.active_window_id) or
         MapSet.member?(visible_ids, topology.active_window_id) do
      topology
    else
      fallback = List.first(visible)

      topology
      |> Map.put(:active_window_id, fallback && fallback.id)
      |> Map.put(
        :active_pane_id,
        fallback && fallback_active_pane_id(topology.panes, fallback.id)
      )
    end
  end

  defp fallback_active_pane_id(panes, window_id) do
    panes = panes || []

    pane =
      Enum.find(panes, &(&1.active && &1.window_id == window_id)) ||
        Enum.find(panes, &(&1.window_id == window_id))

    pane && pane.id
  end

  defp maybe_patch_idle_view_url(socket, opts) do
    if Keyword.get(opts, :skip_idle_patch, false) do
      socket
    else
      ViewDeepLink.maybe_patch_idle_view_url(socket)
    end
  end

  defp active_pane_zoomed?(topology) do
    pane_id = topology.active_pane_id

    topology.panes
    |> Enum.find_value(false, fn pane ->
      if pane.id == pane_id, do: Map.get(pane, :zoomed?, false)
    end)
  end

  defp update_active_session_tab_cwd(socket, %{session: tmux_session} = topology) do
    cwd = topology_active_pane_cwd(topology)
    tabs = socket.assigns[:session_tabs] || []
    updated = SessionBarVM.update_tmux_session_cwd(tabs, tmux_session, cwd)

    if updated == tabs do
      socket
    else
      assign(socket, :session_tabs, updated)
    end
  end

  defp topology_active_pane_cwd(%{panes: panes, active_pane_id: active_pane_id})
       when is_list(panes) do
    panes
    |> Enum.find(&(Map.get(&1, :id) == active_pane_id))
    |> case do
      nil ->
        nil

      pane ->
        Map.get(pane, :current_path) || Map.get(pane, "current_path")
    end
  end

  defp topology_active_pane_cwd(_topology), do: nil

  @doc """
  Keeps tmux focused on the sticky operator terminal pane.

  Ghostty reads the tmux-active pane, so feature-pane splits (preview or file
  holders) must not leave a holder pane as the live PTY target. `feature_panes`
  is the merged `TerminalChrome.feature_pane_map/2` (defaults to the socket's).
  """
  def restore_operator_tmux_focus(socket, feature_panes \\ nil) do
    feature_panes =
      feature_panes ||
        TerminalChrome.feature_pane_map(
          socket.assigns[:preview_panes] || %{},
          socket.assigns[:feature_panes] || %{}
        )

    surface = socket.assigns[:terminal_surface_pane_id]
    active = socket.assigns[:tmux_active_pane_id]

    if connected?(socket) and is_binary(surface) and surface != "" and surface != active and
         Map.has_key?(feature_panes, active) do
      case tmux_adapter().select_pane(socket.assigns.tmux_session, surface) do
        :ok -> socket
        {:error, _reason} -> socket
      end
    else
      socket
    end
  end

  def assign_pane_labels(socket) do
    tmux_session = socket.assigns[:tmux_session]

    pane_labels =
      if is_binary(tmux_session), do: Labels.for_session(tmux_session), else: %{}

    assign(socket, :pane_labels, pane_labels)
  end

  def assign_tmux_window_tabs(socket) do
    socket = assign_pane_labels(socket)
    codex_titles = SessionTitles.titles(pane_session_ids(socket.assigns.tmux_windows))

    tabs =
      SessionBarVM.window_tabs(
        socket.assigns.tmux_windows,
        socket.assigns[:ui_highlight_pane_id],
        socket.assigns[:preview_panes] || %{},
        tmux_session: socket.assigns[:tmux_session],
        session_id: socket.assigns[:terminal_sid],
        unseen_quiet_window_ids: socket.assigns[:unseen_quiet_window_ids],
        pane_labels: socket.assigns[:pane_labels] || %{},
        codex_titles: codex_titles
      )

    socket
    |> assign(:tmux_window_tabs, tabs)
    |> Sidebar.assign_windows_sidebar_tree()
  end

  defp pane_session_ids(windows) when is_list(windows) do
    windows
    |> Enum.flat_map(&(Map.get(&1, :pane_list) || []))
    |> Enum.map(&(Map.get(&1, :pane_title) || Map.get(&1, "pane_title")))
  end

  defp sync_ui_highlight_pane_id(
         socket,
         active_pane_id,
         prev_active_pane,
         preview_panes,
         window_changed?
       ) do
    highlight =
      next_ui_highlight_pane_id(
        socket.assigns[:ui_highlight_pane_id],
        active_pane_id,
        prev_active_pane,
        preview_panes,
        window_changed?
      )

    assign(socket, :ui_highlight_pane_id, highlight)
  end

  @doc """
  Picks the preview registration for the window picker chrome.

  The chip/titlebar must reflect a preview pane in the *current* tmux session
  and active window. Pane ids are session-local, so a leftover `%5` highlight
  from another session must not match a different session's `%5`.
  """
  def selected_preview_pane(
        preview_panes,
        selected_id,
        highlight_id,
        tmux_windows,
        active_window_id,
        tmux_session
      )
      when is_map(preview_panes) do
    active_ids =
      tmux_windows
      |> panes_for_window(active_window_id)
      |> MapSet.new(&Map.get(&1, :id))

    cond do
      preview_in_active_window?(preview_panes, selected_id, active_ids, tmux_session) ->
        Map.get(preview_panes, selected_id)

      preview_in_active_window?(preview_panes, highlight_id, active_ids, tmux_session) ->
        Map.get(preview_panes, highlight_id)

      true ->
        nil
    end
  end

  def selected_preview_pane(
        _preview_panes,
        _selected_id,
        _highlight_id,
        _windows,
        _window_id,
        _session
      ),
      do: nil

  defp panes_for_window(windows, window_id) when is_list(windows) and is_binary(window_id) do
    windows
    |> Enum.find(&(&1.id == window_id))
    |> case do
      %{pane_list: panes} when is_list(panes) -> panes
      _ -> []
    end
  end

  defp panes_for_window(_windows, _window_id), do: []

  defp preview_in_active_window?(preview_panes, id, active_ids, tmux_session) do
    case Map.get(preview_panes, id) do
      preview when is_map(preview) and is_binary(id) ->
        preview_matches_session?(preview, tmux_session) and
          MapSet.member?(active_ids, id)

      _ ->
        false
    end
  end

  defp preview_matches_session?(%{tmux_session: session}, tmux_session)
       when is_binary(session) and is_binary(tmux_session),
       do: session == tmux_session

  defp preview_matches_session?(_preview, _tmux_session), do: true

  @doc """
  Picks the UI-highlighted pane id after a topology refresh.

  `current` is the prior highlight (a UI-only selection, e.g. a preview tile
  the user clicked); `active_pane_id`/`prev_active_pane` are the tmux-active
  pane now and before. The highlight is window-scoped, so a window switch
  re-seats it on the new window's active pane — otherwise the prior window's
  pane id strands, leaving the new window with nothing highlighted. Within a
  window it sticks to the user's selection, only following tmux focus when the
  highlight was tracking it.
  """
  def next_ui_highlight_pane_id(
        current,
        active_pane_id,
        prev_active_pane,
        preview_panes,
        window_changed?
      ) do
    cond do
      window_changed? ->
        active_pane_id

      is_nil(current) ->
        active_pane_id

      Map.has_key?(preview_panes, active_pane_id) ->
        active_pane_id

      Map.has_key?(preview_panes, prev_active_pane) and active_pane_id != prev_active_pane ->
        current

      current == prev_active_pane and active_pane_id != prev_active_pane ->
        active_pane_id

      true ->
        current
    end
  end

  # An "entered" preview belongs to the window it was entered in; switching
  # windows leaves it off-screen, so drop it or its titlebar lingers in the
  # window picker on the new window.
  defp reset_entered_preview_on_window_change(socket, true),
    do: assign(socket, :entered_preview_pane_id, nil)

  defp reset_entered_preview_on_window_change(socket, false), do: socket

  defp assign_page_title(socket) do
    ws_name = socket.assigns[:workspace] && socket.assigns.workspace.name

    terminal_sid = socket.assigns[:terminal_sid]

    session_name =
      (socket.assigns[:session_tabs] || [])
      |> Enum.find(&(&1.id == terminal_sid))
      |> case do
        nil -> nil
        tab -> tab.label
      end

    window_name =
      (socket.assigns[:tmux_windows] || [])
      |> Enum.find(&(&1.id == socket.assigns[:tmux_active_window_id]))
      |> case do
        nil -> nil
        w -> w.name
      end

    terminal_part =
      case {session_name, window_name} do
        {nil, nil} -> nil
        {nil, w} -> w
        {s, nil} -> s
        {s, w} -> "#{s} / #{w}"
      end

    title =
      [ws_name, terminal_part]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    assign(socket, :page_title, if(title == "", do: "Casein", else: title))
  end

  @doc """
  Derives the header session-dropdown label/detail and active-window pane
  count as their own assigns.

  The raw `@tmux_panes` list carries activity timestamps and is therefore
  re-assigned (never term-equal) on every watcher broadcast; reading it from
  header attrs re-rendered the header every 300ms while any pane produced
  output. These derived values almost never change, so `assign/3`'s
  equality skip suppresses the no-op diffs.
  """
  def assign_header_session_labels(socket, topology) do
    panes = topology.panes
    default_sid = socket.assigns[:default_terminal_sid]
    active_sid = socket.assigns[:terminal_sid]

    socket
    |> assign(
      :shell_button_label,
      TerminalChrome.shell_button_label(
        default_sid,
        active_sid,
        panes,
        socket.assigns[:host_path]
      )
    )
    |> assign(
      :shell_button_detail,
      TerminalChrome.shell_button_detail(default_sid, active_sid, panes)
    )
    |> assign(
      :active_window_pane_count,
      Enum.count(panes, &(&1.window_id == topology.active_window_id))
    )
  end

  def focus_active_terminal(socket, extra \\ %{}) do
    tmux_pane_id =
      socket.assigns[:terminal_surface_pane_id] || socket.assigns[:tmux_active_pane_id]

    payload =
      %{
        "workspace_id" => socket.assigns[:workspace] && socket.assigns.workspace.id,
        "pane_id" => socket.assigns[:focused_pane_id],
        "tmux_pane_id" => tmux_pane_id,
        "terminal_mode" => terminal_mode_name(socket.assigns[:terminal_mode])
      }
      |> Map.merge(extra)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    push_event(socket, "terminal:focus_active", payload)
  end

  defp terminal_mode_name(nil), do: nil
  defp terminal_mode_name(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp terminal_mode_name(mode), do: to_string(mode)

  def subscribe_tmux_topology(socket) do
    if connected?(socket) do
      {:ok, %{generation: generation} = result} =
        Terminals.switch_tmux_topology_subscription(nil, socket.assigns.tmux_session,
          read: :get,
          workspace_id: socket.assigns.workspace.id
        )

      socket
      |> assign(:tmux_topology_generation, generation)
      |> monitor_tmux_topology_watcher(result[:pid])
      |> sync_window_trash_subscription(nil)
    else
      socket
    end
  end

  @doc """
  Follows the trash topic for the currently assigned session.

  Trashing hides a window from every viewer, not just the one that closed it,
  so the others need a nudge to re-filter — the topology itself has not changed
  and the watcher has nothing to broadcast.
  """
  def sync_window_trash_subscription(socket, old_session) do
    new_session = socket.assigns[:tmux_session]

    if connected?(socket) and old_session != new_session do
      if is_binary(old_session), do: WindowTrash.unsubscribe(old_session)
      if is_binary(new_session), do: WindowTrash.subscribe(new_session)
    end

    socket
  end

  @doc """
  Watches the topology watcher itself so a dead one is noticed.

  The watcher registers subscribers by pid and idle-stops once none are left, so
  a crash costs this LiveView its registration: the restarted watcher sees an
  empty watcher set, shuts down 60s later, and the window list silently stops
  updating until something forces a refresh. Monitoring closes that hole — see
  `Show.handle_info/2` for the `:DOWN` clause that resubscribes.
  """
  def monitor_tmux_topology_watcher(socket, pid) do
    if ref = socket.assigns[:tmux_topology_watcher_ref] do
      Process.demonitor(ref, [:flush])
    end

    assign(socket, :tmux_topology_watcher_ref, if(is_pid(pid), do: Process.monitor(pid)))
  end

  @doc """
  Rebuilds the topology subscription after the watcher went down.

  Resubscribing restarts the watcher (`ensure_started`), re-registers this
  LiveView with it, and pulls a fresh topology in one step, so the recovery also
  repairs whatever drifted while nothing was watching.
  """
  def resubscribe_tmux_topology(socket) do
    socket = assign(socket, :tmux_topology_watcher_ref, nil)

    if connected?(socket) and is_binary(socket.assigns[:tmux_session]) do
      {:ok, %{generation: generation, topology: topology} = result} =
        Terminals.switch_tmux_topology_subscription(nil, socket.assigns.tmux_session,
          workspace_id: socket.assigns.workspace.id
        )

      socket
      |> assign(:tmux_topology_generation, generation)
      |> monitor_tmux_topology_watcher(result[:pid])
      |> assign_tmux_topology(topology)
    else
      socket
    end
  end

  @doc """
  Atomically moves the LiveView's topology subscription to the (already
  assigned) current tmux session and applies a fresh topology, replacing the
  old unsubscribe → subscribe → refresh sequence that could interleave with
  stale broadcasts during rapid session switches.
  """
  def switch_topology_subscription(socket, old_session) do
    if connected?(socket) do
      {:ok, %{generation: generation, topology: topology} = result} =
        Terminals.switch_tmux_topology_subscription(old_session, socket.assigns.tmux_session,
          workspace_id: socket.assigns.workspace.id
        )

      new_session = socket.assigns.tmux_session
      session_changed? = is_binary(old_session) and old_session != new_session

      socket =
        socket
        |> assign(:tmux_topology_generation, generation)
        |> monitor_tmux_topology_watcher(result[:pid])
        |> sync_window_trash_subscription(old_session)
        |> maybe_reset_preview_selection_on_session_change(session_changed?)

      assign_tmux_topology(socket, topology)
    else
      refresh_tmux_topology(socket)
    end
  end

  defp maybe_reset_preview_selection_on_session_change(socket, true) do
    # Pane ids like %5 are only unique within a tmux session. Reusing @0/%5
    # across sessions must not inherit the prior session's entered/highlighted
    # preview or the window picker titlebar can show the wrong preview.
    socket
    |> assign(:entered_preview_pane_id, nil)
    |> assign(:ui_highlight_pane_id, nil)
  end

  defp maybe_reset_preview_selection_on_session_change(socket, false), do: socket

  def switch_active_session(socket, sid, tmux_session_hint \\ nil) do
    case resolve_active_session(socket, sid, tmux_session_hint) do
      {:ok, info, tmux_session} ->
        old_session = socket.assigns.tmux_session
        mode = session_switch_terminal_mode(socket, info)

        socket =
          socket
          |> reset_panes_for_session_switch(info, sid, tmux_session)
          |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], mode)
          |> assign_active_terminal_session(info, sid, tmux_session, mode)
          |> assign(:tmux_rename_window_id, nil)
          |> switch_topology_subscription(old_session)

        maybe_start_switched_raw_session(socket, mode)

      {:error, :session_ended} ->
        socket
        |> mark_focused_raw_pane_session_ended()
        |> put_flash(:error, "Terminal session ended. Refreshed sessions.")
        |> refresh_session_tabs()

      :error ->
        put_flash(socket, :error, "Could not switch terminal session.")
    end
  end

  def assign_active_terminal_session(socket, info, sid, tmux_session, mode) when is_map(info) do
    socket
    |> assign(:terminal_sid, sid)
    |> assign(:terminal_context, terminal_context(socket, info))
    |> assign(:terminal_workspace_capability, Show.terminal_workspace_capability(socket, sid))
    |> assign(:terminal_mode, mode)
    |> assign(:tmux_session, tmux_session)
    |> assign(:active_session_kind, Map.get(info, :kind))
    |> assign(:tmux_mutations_enabled?, tmux_mutations_enabled?(Map.get(info, :kind)))
  end

  @doc false
  def terminal_context(socket, info) when is_map(info) do
    metadata = Map.get(info, :metadata) || %{}

    case session_worktree_cwd(info) do
      path when is_binary(path) and path != "" ->
        %{
          kind: :git_worktree,
          root_path: path,
          runtime_id: metadata_value(metadata, :runtime_id),
          branch: metadata_value(metadata, :git_branch),
          source: metadata_value(metadata, :source),
          agent: metadata_value(metadata, :agent),
          tmux_session: Map.get(info, :tmux_session)
        }
        |> reject_blank_context_values()

      _ ->
        default_terminal_context(socket)
    end
  end

  @doc false
  def default_terminal_context(socket) do
    %{
      kind: :home,
      root_path: Show.default_workspace_cwd(socket),
      workspace_id: socket.assigns.workspace.id,
      branch: Map.get(Map.get(socket.assigns.workspace, :metadata, %{}) || %{}, "branch"),
      source: "home"
    }
    |> reject_blank_context_values()
  end

  defp mark_focused_raw_pane_session_ended(socket) do
    if socket.assigns[:terminal_mode] in [:raw, :raw_ghostty] do
      pane_id = socket.assigns[:focused_pane_id]

      if is_binary(pane_id) and Show.get_pane_data(socket, pane_id) do
        Show.update_pane(socket, pane_id, fn pane ->
          %{
            pane
            | ghostty_term: nil,
              ghostty_pty: nil,
              worker: nil,
              backend: nil,
              error: :session_ended
          }
        end)
      else
        socket
      end
    else
      socket
    end
  end

  def session_switch_terminal_mode(socket, info) when is_map(info) do
    Terminals.session_switch_terminal_mode(
      info,
      socket.assigns[:workspace_mode],
      socket.assigns[:host_id]
    )
  end

  def reset_panes_for_session_switch(socket, %{kind: :shell}, sid, tmux_session) do
    socket
    |> Show.cleanup_ghostty_resources_if_leaving()
    |> assign(:pane_data, primary_pane_data(sid, tmux_session))
    |> assign(:focused_pane_id, "pane-1")
  end

  def reset_panes_for_session_switch(socket, _info, _sid, _tmux_session) do
    Show.cleanup_ghostty_resources_if_leaving(socket)
  end

  def maybe_start_switched_raw_session(socket, mode) when mode in [:raw, :raw_ghostty] do
    Show.start_ghostty_terminal(socket)
  end

  def maybe_start_switched_raw_session(socket, _mode), do: socket

  def primary_pane_data(sid, tmux_session) do
    %{
      "pane-1" => %{
        ghostty_term: nil,
        ghostty_pty: nil,
        worker: nil,
        backend: nil,
        session_sid: sid,
        tmux_session: tmux_session,
        cols: 120,
        rows: 40,
        error: nil,
        auto_retry_count: 0
      }
    }
  end

  def resolve_active_session(socket, sid, tmux_session_hint) do
    ws = socket.assigns.workspace
    workspace_name = ws.name || ws.id

    case resolve_session_info(ws, sid) do
      {:ok, info} when is_map(info) ->
        tmux_session =
          case tmux_session_for_info(info, workspace_name) do
            nil when is_binary(tmux_session_hint) and tmux_session_hint != "" -> tmux_session_hint
            session when is_binary(session) -> session
            _ -> nil
          end

        cond do
          not is_binary(tmux_session) ->
            :error

          not Terminals.tmux_session_in_workspace?(tmux_session, ws) ->
            :error

          active_session_available?(socket, info, sid, tmux_session) ->
            {:ok, info, tmux_session}

          true ->
            {:error, :session_ended}
        end

      :error ->
        :error
    end
  end

  defp resolve_session_info(ws, sid) do
    case Terminals.resolve(sid) do
      {:ok, %{kind: :shell} = info} ->
        case Terminals.fetch_session_tab(ws.id, sid, workspace_names: [ws.name, ws.id]) do
          {:ok, scanned} when is_map(scanned) -> {:ok, scanned}
          :error -> {:ok, Map.put(info, :workspace_id, ws.id)}
        end

      {:ok, info} = ok when is_map(info) ->
        ok

      :error ->
        Terminals.fetch_session_tab(ws.id, sid, workspace_names: [ws.name, ws.id])
    end
  end

  def tmux_session_for_info(%{kind: :shell, tmux_session: tmux}, _workspace_name)
      when is_binary(tmux) and tmux != "",
      do: tmux

  def tmux_session_for_info(%{kind: :shell, sid: sid}, workspace_name)
      when is_binary(sid),
      do: Terminals.tmux_session_name(workspace_name, sid)

  def tmux_session_for_info(%{tmux_session: tmux}, _workspace_name)
      when is_binary(tmux) and tmux != "",
      do: tmux

  def tmux_session_for_info(_info, _workspace_name), do: nil

  def active_session_available?(socket, %{kind: :shell} = info, sid, tmux_session) do
    sid == socket.assigns[:default_terminal_sid] or tmux_session_alive?(tmux_session) or
      worktree_session_available?(info)
  end

  def active_session_available?(_socket, _info, _sid, tmux_session) do
    tmux_session_alive?(tmux_session)
  end

  def tmux_session_alive?(session) when is_binary(session) do
    adapter = tmux_adapter()

    if function_exported?(adapter, :session_alive?, 1) do
      adapter.session_alive?(session)
    else
      true
    end
  rescue
    _ -> false
  end

  def tmux_session_alive?(_session), do: false

  defp worktree_session_available?(info) when is_map(info) do
    case session_worktree_cwd(info) do
      path when is_binary(path) and path != "" -> File.dir?(path)
      _ -> false
    end
  end

  defp session_worktree_cwd(%{metadata: metadata}) when is_map(metadata) do
    worktree_path =
      Map.get(metadata, :worktree_path) || Map.get(metadata, "worktree_path") ||
        Map.get(metadata, :git_toplevel) || Map.get(metadata, "git_toplevel")

    git_worktree? = Map.get(metadata, :git_worktree?) || Map.get(metadata, "git_worktree?")

    cond do
      is_binary(worktree_path) and worktree_path != "" and truthy?(git_worktree?) ->
        worktree_path

      is_binary(Map.get(metadata, :worktree_path)) ->
        Map.get(metadata, :worktree_path)

      is_binary(Map.get(metadata, "worktree_path")) ->
        Map.get(metadata, "worktree_path")

      true ->
        nil
    end
  end

  defp session_worktree_cwd(_info), do: nil

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
  end

  defp reject_blank_context_values(context) do
    context
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defdelegate tmux_mutations_enabled?(kind), to: Terminals

  def tmux_mutations_allowed?(socket), do: socket.assigns[:tmux_mutations_enabled?] == true

  def deny_tmux_mutation(socket) do
    {:noreply, put_flash(socket, :error, "Tmux layout changes are not allowed for this session.")}
  end

  def ensure_primary_tmux_session(socket) do
    case tmux_adapter().ensure_session(socket.assigns.tmux_session, Show.workspace_cwd(socket)) do
      :ok -> socket
      {:error, _reason} -> socket
    end
  end

  @doc """
  Assigns the directory's cached tab list (cheap — no tmux/git subprocesses).

  Session-switch events go through here: the directory's 2s poll plus its
  `sessions_updated` broadcast keep the list fresh, so forcing a recompute on
  every click only blocked the LiveView behind a subprocess fan-out. Use
  `refresh_session_tabs/1` when the caller just changed what tmux knows
  (created a session, explicit refresh button).
  """
  def assign_session_tabs(socket) do
    ws = socket.assigns.workspace

    tabs =
      if connected?(socket) do
        Terminals.session_tabs(ws.id, workspace_name: ws.name || ws.id)
      else
        Terminals.read_session_tabs(ws.id, workspace_name: ws.name || ws.id)
      end

    assign_session_tabs(socket, tabs)
  end

  @doc "Forces a directory recompute (subprocess fan-out) and assigns the result."
  def refresh_session_tabs(socket) do
    ws = socket.assigns.workspace

    tabs =
      if connected?(socket) do
        Terminals.refresh_session_tabs_now(ws.id, workspace_name: ws.name || ws.id)
      else
        Terminals.read_session_tabs(ws.id, workspace_name: ws.name || ws.id)
      end

    assign_session_tabs(socket, tabs)
  end

  @doc "Applies the viewer filter + view-model mapping to a canonical tab list."
  def assign_session_tabs(socket, tabs) when is_list(tabs) do
    # The default/landing session is no longer special-cased out of the list —
    # it renders as a normal row marked as "home" (see SessionBar.session_dropdown),
    # and is synthesized when the scan hasn't discovered it yet so the picker
    # always offers a way home.
    socket
    |> assign(:session_tab_infos, tabs)
    |> notify_newly_quiet_windows(tabs)
    |> assign_session_tab_view_model(tabs)
    |> assign_page_title()
  end

  defp assign_session_tab_view_model(socket, tabs) when is_list(tabs) do
    ws = socket.assigns.workspace

    vm =
      tabs
      |> Terminals.with_default_shell(
        socket.assigns[:default_terminal_sid],
        ws.id,
        ws.name || ws.id
      )
      |> SessionBarVM.session_tabs(
        unseen_quiet_window_ids: socket.assigns[:unseen_quiet_window_ids]
      )

    assign(socket, :session_tabs, vm)
  end

  defp refresh_session_tab_attention(socket) do
    case socket.assigns[:session_tab_infos] do
      tabs when is_list(tabs) -> assign_session_tab_view_model(socket, tabs)
      _ -> socket
    end
  end

  # Attention path for quiet-agent windows: diff the quiet set against the
  # previous assign and run newly quiet windows through the attention policy.
  # Focused workspaces keep inline chrome only; unfocused/hidden surfaces get a
  # browser notification event. Diffing raw tabs (not the vm) on purpose — the
  # viewer filter hides this tab's own attached session, which is exactly where
  # the viewer's agents run. The first assign only records a baseline, so
  # reconnects/mounts never replay "went quiet 20 minutes ago" notifications.
  defp notify_newly_quiet_windows(socket, tabs) do
    quiet = quiet_window_entries(tabs)
    quiet_ids = MapSet.new(Map.keys(quiet))

    observed_working_ids =
      socket.assigns[:agent_working_window_ids]
      |> normalize_window_id_set()
      |> MapSet.union(working_window_ids(tabs))

    previous_ids = socket.assigns[:quiet_window_ids]
    previous_entries = socket.assigns[:quiet_window_entries] || %{}
    unseen_ids = normalize_window_id_set(socket.assigns[:unseen_quiet_window_ids])

    socket =
      socket
      |> assign(:quiet_window_ids, quiet_ids)
      |> assign(:quiet_window_entries, quiet)
      |> assign(:unseen_quiet_window_ids, MapSet.intersection(unseen_ids, quiet_ids))
      |> assign(:agent_working_window_ids, observed_working_ids)

    if is_nil(previous_ids) or not connected?(socket) do
      socket
    else
      workspace = socket.assigns[:workspace]
      workspace_name = (workspace && (workspace.name || workspace.id)) || ""
      workspace_id = workspace && workspace.id

      socket =
        quiet
        |> Enum.reject(fn {key, _entry} -> MapSet.member?(previous_ids, key) end)
        |> Enum.reduce(socket, fn {_key, entry}, acc ->
          decision =
            AttentionPolicy.quiet_agent_decision(%{
              surface_state: socket.assigns[:attention_surface_state],
              target_state: quiet_target_state(socket, entry),
              observed_working?: MapSet.member?(observed_working_ids, quiet_entry_key(entry))
            })

          acc =
            acc
            |> emit_quiet_agent_transition(entry, workspace_id, workspace_name, decision)
            |> maybe_track_unseen_quiet(entry, decision)
            |> maybe_push_quiet_agent_event(entry, workspace_name, decision.reaction)

          maybe_mark_quiet_label(acc, workspace_id, entry)
        end)

      newly_active_ids = MapSet.difference(previous_ids, MapSet.new(Map.keys(quiet)))
      socket = clear_unseen_quiet_windows(socket, newly_active_ids)

      Enum.reduce(newly_active_ids, socket, fn key, acc ->
        case Map.get(previous_entries, key) do
          entry when is_map(entry) -> maybe_clear_quiet_label(acc, workspace_id, entry)
          _ -> acc
        end
      end)
    end
  end

  defp normalize_window_id_set(%MapSet{} = set), do: set
  defp normalize_window_id_set(_value), do: MapSet.new()

  def acknowledge_active_quiet_window(socket) do
    acknowledge_quiet_window(
      socket,
      socket.assigns[:terminal_sid],
      socket.assigns[:tmux_active_window_id]
    )
  end

  def acknowledge_quiet_window(socket, session_id, window_id)
      when is_binary(session_id) and is_binary(window_id) do
    socket
    |> clear_unseen_quiet_window({session_id, window_id})
    |> refresh_session_tab_attention()
    |> maybe_assign_tmux_window_tabs()
  end

  def acknowledge_quiet_window(socket, _session_id, _window_id), do: socket

  defp maybe_acknowledge_focused_active_quiet_window(socket) do
    if current_workspace_focused?(socket) do
      socket
      |> clear_unseen_quiet_window({
        socket.assigns[:terminal_sid],
        socket.assigns[:tmux_active_window_id]
      })
      |> refresh_session_tab_attention()
    else
      socket
    end
  end

  defp maybe_assign_tmux_window_tabs(socket) do
    if is_list(socket.assigns[:tmux_windows]) do
      assign_tmux_window_tabs(socket)
    else
      socket
    end
  end

  defp maybe_track_unseen_quiet(socket, _entry, %{reaction: :nothing}), do: socket

  defp maybe_track_unseen_quiet(socket, entry, _decision) do
    key = quiet_entry_key(entry)

    socket
    |> assign(
      :unseen_quiet_window_ids,
      socket.assigns[:unseen_quiet_window_ids]
      |> normalize_window_id_set()
      |> MapSet.put(key)
    )
  end

  defp clear_unseen_quiet_windows(socket, ids) do
    unseen = normalize_window_id_set(socket.assigns[:unseen_quiet_window_ids])
    assign(socket, :unseen_quiet_window_ids, MapSet.difference(unseen, ids))
  end

  defp clear_unseen_quiet_window(socket, {session_id, window_id})
       when is_binary(session_id) and is_binary(window_id) do
    unseen = normalize_window_id_set(socket.assigns[:unseen_quiet_window_ids])
    assign(socket, :unseen_quiet_window_ids, MapSet.delete(unseen, {session_id, window_id}))
  end

  defp clear_unseen_quiet_window(socket, _key), do: socket

  defp emit_quiet_agent_transition(socket, entry, workspace_id, workspace_name, decision) do
    :telemetry.execute(
      [:casein, :attention, :quiet_agent, :transition],
      %{count: 1},
      %{
        reaction: decision.reaction,
        reason: decision.reason,
        surface_state: decision.surface_state,
        target_state: decision.target_state,
        observed_working?: decision.observed_working?,
        workspace_id: workspace_id,
        workspace: workspace_name,
        session_id: entry.session_id,
        tmux_session: entry.tmux_session,
        window_id: entry.window_id
      }
    )

    socket
  end

  defp maybe_mark_quiet_label(socket, workspace_id, %{
         tmux_session: tmux_session,
         window_id: window_id
       }) do
    if socket.assigns[:tmux_session] == tmux_session do
      case quiet_window_pane_id(socket, window_id) do
        pane_id when is_binary(pane_id) ->
          Labels.mark_quiet(workspace_id, tmux_session, pane_id)
          assign_pane_labels(socket)

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp maybe_clear_quiet_label(socket, workspace_id, %{
         tmux_session: tmux_session,
         window_id: window_id
       }) do
    if socket.assigns[:tmux_session] == tmux_session do
      case quiet_window_pane_id(socket, window_id) do
        pane_id when is_binary(pane_id) ->
          Labels.clear_quiet(workspace_id, tmux_session, pane_id)
          assign_pane_labels(socket)

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp quiet_window_pane_id(socket, window_id) do
    Enum.find_value(socket.assigns[:tmux_windows] || [], fn window ->
      if Map.get(window, :id) == window_id do
        window
        |> Map.get(:pane_list, [])
        |> Enum.find(& &1.active)
        |> case do
          %{id: id} -> id
          _ -> nil
        end
      end
    end)
  end

  defp quiet_window_entries(tabs) do
    for %{metadata: metadata, tmux_session: tmux_session} = info <- tabs,
        is_map(metadata),
        window <- Map.get(metadata, :windows) || Map.get(metadata, "windows") || [],
        (Map.get(window, :quiet) || Map.get(window, "quiet")) == true,
        into: %{} do
      window_id = Map.get(window, :id) || Map.get(window, "id")

      session_id = Map.get(info, :sid)

      {{session_id, window_id},
       %{
         session_id: session_id,
         tmux_session: tmux_session,
         window_id: window_id,
         window: Map.get(window, :name) || Map.get(window, "name") || "window"
       }}
    end
  end

  defp working_window_ids(tabs) do
    tabs
    |> Enum.flat_map(&working_window_ids_for_session/1)
    |> MapSet.new()
  end

  defp working_window_ids_for_session(%{metadata: metadata} = info) when is_map(metadata) do
    for window <- Map.get(metadata, :windows) || Map.get(metadata, "windows") || [],
        session_id = Map.get(info, :sid),
        window_id = Map.get(window, :id) || Map.get(window, "id"),
        is_binary(session_id),
        is_binary(window_id),
        window_pane_state(window) == :working,
        do: {session_id, window_id}
  end

  defp working_window_ids_for_session(_info), do: []

  defp window_pane_state(window) when is_map(window) do
    case Map.get(window, :pane_state) || Map.get(window, "pane_state") do
      :working -> :working
      "working" -> :working
      _ -> :unknown
    end
  end

  defp quiet_entry_key(%{session_id: session_id, window_id: window_id}) do
    {session_id, window_id}
  end

  defp quiet_target_state(socket, %{
         session_id: session_id,
         tmux_session: tmux_session,
         window_id: window_id
       }) do
    cond do
      current_quiet_window?(socket, session_id, tmux_session, window_id) -> :focused
      current_workspace_focused?(socket) -> :visible
      true -> :hidden
    end
  end

  defp current_quiet_window?(socket, session_id, tmux_session, window_id) do
    socket.assigns[:terminal_sid] == session_id and
      socket.assigns[:tmux_session] == tmux_session and
      socket.assigns[:tmux_active_window_id] == window_id
  end

  defp current_workspace_focused?(socket) do
    AttentionPolicy.surface_state(socket.assigns[:attention_surface_state]) == :focused
  end

  defp maybe_push_quiet_agent_event(socket, entry, workspace_name, :notify) do
    payload =
      entry
      |> Map.put(:workspace, workspace_name)
      |> Map.put(:reaction, AttentionPolicy.reaction_label(:notify))

    push_event(socket, "casein:agent_quiet", payload)
  end

  defp maybe_push_quiet_agent_event(socket, _entry, _workspace_name, _reaction), do: socket

  def rename_tmux_window(socket, window_id, name) do
    name = String.trim(to_string(name || ""))

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Window name cannot be blank.")}

      true ->
        case tmux_adapter().rename_window(socket.assigns.tmux_session, window_id, name) do
          :ok ->
            {:noreply,
             socket
             |> assign(:tmux_rename_window_id, nil)
             |> refresh_tmux_topology()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not rename tmux window: #{inspect(reason)}")}
        end
    end
  end

  @doc """
  Set a session's display alias (stored as the `@casein_session_alias` tmux user
  option). Blank names are rejected. On success, clears rename mode and re-scans
  so the new alias is read back as the session label.
  """
  def rename_tmux_session(socket, _session_id, tmux_session, name) do
    name = String.trim(to_string(name || ""))

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Session name cannot be blank.")}

      not (is_binary(tmux_session) and tmux_session != "") ->
        {:noreply, put_flash(socket, :error, "Could not rename tmux session: unknown session.")}

      true ->
        case tmux_adapter().set_session_alias(tmux_session, name) do
          :ok ->
            {:noreply,
             socket
             |> assign(:tmux_rename_session_id, nil)
             |> refresh_session_tabs()
             # Sessions rail is the only surface for session labels after the
             # header title was removed — rebuild it so the alias shows immediately.
             |> Sidebar.assign_sessions_sidebar_tree()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not rename tmux session: #{inspect(reason)}")}
        end
    end
  end

  def parse_resize_amount(nil), do: {:ok, Terminals.tmux_resize_amount_default()}

  def parse_resize_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> validate_resize_amount(integer)
      _ -> {:error, :invalid_amount}
    end
  end

  def parse_resize_amount(value) when is_integer(value) and value > 0 do
    validate_resize_amount(value)
  end

  def parse_resize_amount(_), do: {:error, :invalid_amount}

  defp validate_resize_amount(value) do
    if value <= Terminals.tmux_resize_amount_max() do
      {:ok, value}
    else
      {:error, :invalid_amount}
    end
  end

  def workspace_window_path(socket, window_id) do
    ViewDeepLink.workspace_view_path(socket, window_id)
  end

  def patch_current_session(socket, opts \\ []) do
    force? = Keyword.get(opts, :force, true)

    socket =
      if force? do
        ViewDeepLink.touch_terminal_interaction(socket)
      else
        socket
      end

    if force? or ViewDeepLink.terminal_idle?(socket) do
      ViewDeepLink.patch_current_view(socket)
    else
      socket
    end
  end

  @doc """
  Viewer-filtered session tabs for the workspace, read directly from the
  domain (no directory process). Used for the disconnected first render;
  connected sockets go through `assign_session_tabs/1`.
  """
  def terminal_session_tabs(workspace, default_sid) do
    workspace.id
    |> Terminals.read_session_tabs(workspace_name: workspace.name || workspace.id)
    |> Terminals.visible_tabs(default_sid)
  end

  def subscribe_session_tabs(socket) do
    if connected?(socket) do
      ws = socket.assigns.workspace
      _ = Terminals.subscribe_session_tabs(ws.id, workspace_name: ws.name || ws.id)
    end

    socket
  end

  @doc """
  Focus the operator UI on an MCP or preview activity target.
  """
  def focus_activity_target(socket, tmux_session, pane_id) do
    socket =
      case find_session_tab_by_tmux(socket, tmux_session) do
        %{id: sid, tmux_session: session} ->
          socket
          |> switch_active_session(sid, session)
          |> assign_session_tabs()
          |> patch_current_session_if_active(sid)

        _ ->
          socket
      end

    {socket, focused_preview?} =
      if is_binary(pane_id) and pane_id != "" do
        preview_panes = socket.assigns[:preview_panes] || %{}

        if Map.has_key?(preview_panes, pane_id) do
          {
            socket
            |> assign(:entered_preview_pane_id, pane_id)
            |> assign(:ui_highlight_pane_id, pane_id),
            true
          }
        else
          case tmux_adapter().select_pane(socket.assigns.tmux_session, pane_id) do
            :ok ->
              {
                socket
                |> assign(:ui_highlight_pane_id, pane_id)
                |> assign(:entered_preview_pane_id, nil)
                |> refresh_tmux_topology(skip_idle_patch: true),
                false
              }

            {:error, reason} ->
              {put_flash(socket, :error, "Could not focus pane #{pane_id}: #{inspect(reason)}"),
               false}
          end
        end
      else
        {socket, false}
      end

    if focused_preview? do
      # Focusing a preview pane is a UI highlight, not a content change. Pushing a
      # reload here blanks-and-reloads the live iframe on every agent focus event,
      # which is the "preview flashes" bug. Leave the already-loaded frame alone;
      # the assigns above (entered/highlight) are enough to surface it.
      socket
    else
      focus_active_terminal(socket, %{"reason" => "agent_activity:focus"})
    end
  end

  defp find_session_tab_by_tmux(socket, tmux_session) when is_binary(tmux_session) do
    Enum.find(socket.assigns[:session_tabs] || [], &(&1.tmux_session == tmux_session))
  end

  defp find_session_tab_by_tmux(_socket, _), do: nil

  defp patch_current_session_if_active(socket, sid) do
    if socket.assigns.terminal_sid == sid do
      patch_current_session(socket)
    else
      socket
    end
  end
end
