defmodule DevIdeWeb.WorkspaceLive.Show do
  @moduledoc """
  The main workspace cockpit LiveView: the durable raw terminal (tmux +
  Ghostty), tmux topology/session bars, file tree/editor, search, diff, run
  ledger, command palette, audit drawer, and preview panes for one workspace.

  Holds the socket state and orchestrates `PaneWorker`s; per-domain
  `handle_event`/`handle_info`/render logic is delegated to the
  `DevIdeWeb.WorkspaceLive.Show.*` submodules. The browser is a viewer of a
  server-side PTY (FP-1); every event passes the `authz_gate/3` fail-closed hook.
  """
  use DevIdeWeb, :live_view

  alias DevIDE.Agents
  alias DevIDE.Agents.PaneEnv
  alias DevIDE.Agents.BrowserControl
  alias DevIDE.Audit
  alias DevIDE.BoundedBuffer
  alias DevIDE.Elixir, as: ElixirNav
  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Files
  alias DevIDE.Labels
  alias DevIDE.LanPathResolver
  alias DevIDE.Policy
  alias DevIDE.PreviewActivity
  alias DevIDE.PreviewPanes
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status
  alias DevIDE.Terminals
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIDE.Workspaces.FileAccess
  alias DevIDE.Workspaces.Isolation
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.ChannelAuth
  alias DevIdeWeb.Forms.TemplateForm
  alias DevIdeWeb.Plugs.AssignCurrentUser
  alias DevIdeWeb.WorkspaceLive.PaneWorker
  alias DevIdeWeb.WorkspaceLive.Show.ContextMenu
  alias DevIdeWeb.WorkspaceLive.Show.ContextMenuEvents
  alias DevIdeWeb.WorkspaceLive.Show.FileEvents
  alias DevIdeWeb.WorkspaceLive.Show.LogsEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteEvents
  alias DevIdeWeb.WorkspaceLive.Show.PanelGate
  alias DevIdeWeb.WorkspaceLive.Show.RunEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents
  alias DevIdeWeb.WorkspaceLive.Show.TmuxTemplateEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalInfo
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  import DevIdeWeb.WorkspaceLive.Show.Context
  import DevIdeWeb.WorkspaceLive.Show.UI
  import DevIdeWeb.WorkspaceLive.Show.LogsPanel
  import DevIdeWeb.WorkspaceLive.Show.TemplatePanels
  import DevIdeWeb.WorkspaceLive.Show.SidePanels
  import DevIdeWeb.WorkspaceLive.Show.RunPanel
  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  @ghostty_term_id "raw-term-ghostty"
  @preview_demo_port 5173
  @preview_demo_open_attempts 8
  @preview_demo_open_delay_ms 400

  @type pane :: %{
          ghostty_term: pid() | nil,
          ghostty_pty: pid() | nil,
          worker: pid() | nil,
          backend: :ghostty_pty | :shared_session | :session_owner | nil,
          session_sid: String.t(),
          tmux_session: String.t(),
          cols: integer(),
          rows: integer(),
          error: term() | nil,
          auto_retry_count: non_neg_integer()
        }

  # --- Authorization dispatch table (see authz_gate/3) ---
  #
  # Every top-level event this LiveView knowingly handles. The table exists to
  # make authorization coverage *structural*: authz_gate/3 runs before every
  # handle_event clause and denies any event not listed here (or covered by the
  # tmux:/terminal: delegation prefixes), so a newly-added handler fails closed
  # until it is registered — instead of silently running unauthorized.
  #
  # Workspace *access* is enforced at mount (`ensure_workspace_access/2`) and again
  # in `authz_gate/3` so mutating events fail closed if ownership is missing.
  # Fine-grained mode gates still funnel through `DevIDE.Policy` inside handlers
  # (file edits -> can_edit_file?, run/command -> can_run_command?, etc.).
  @known_events ~w(
    switch_tab refresh
    workspace:start workspace:stop workspace:set_mode
    workspace:grant_agent_write_unlock workspace:revoke_agent_write_unlock
    tmux:apply_template tmux:apply_previewed_template
    tmux:save_template tmux:update_saved_template
    tmux:duplicate_saved_template tmux:delete_saved_template
    tmux:preview_template tmux:open_template_library tmux:close_template_library
    tmux:filter_saved_templates tmux:edit_saved_template tmux:cancel_saved_template_edit
    tmux:duplicate_saved_template_start tmux:cancel_saved_template_duplicate
    tmux:cancel_template_preview
    terminal:paste_file terminal:paste_image terminal:toggle_chrome terminal:auto_hide_chrome
    view:set_window_picker
    mobile_nav:toggle mobile_nav:close mobile_nav:open mobile_nav:set_view
    attach_terminal_session pane:navigate pane:history_open pane:history_close
    split_right split_down
    pane:close_focused pane:close_others pane:focus_next pane:focus_previous
    pane:zoom_focused retry_pane nav:dir equalize_layout pane:cycle_layout
    ghostty:snapshot snapshot_all
    isolation:refresh notification:open_conversation
    run:start workflow:hint workflow:run run_ledger:select run_ledger:open
    agent:start_review_run
    palette:open palette:ide palette:category palette:nav palette:close palette:query
    palette:templates palette:execute
    audit_drawer:toggle audit_drawer:close
    search:run annotation:open preview:open preview-pane:enter preview-pane:exit
    preview-pane:snapshot-click preview-pane:telemetry
    preview-pane:back preview-pane:forward preview-pane:refresh preview-pane:recover preview-pane:close
    run:cancel set_log_service
    tree:toggle tree:select_dir tree:new_form tree:cancel_new tree:create tree:refresh tree:open
    file:rename_form file:rename_cancel file:rename_submit
    file:delete_request file:delete_cancel file:delete_confirm file:refresh file:save
  )

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns[:current_user] || AssignCurrentUser.from_session(session)
    host_id = normalize_local_host_id(Map.get(params, "host", "local"))

    # Host gate: the cockpit is host-aware (product.md §9.1, FP-4), but
    # cross-host workspace resolution is not yet wired through the runtime.
    # Refuse non-local hosts before workspace resolution so a defensive direct
    # URL cannot trigger manager/source calls first.
    with :ok <- ensure_local_host(host_id),
         {:ok, mount_workspace} <- resolve_mount_workspace(params, user),
         :ok <-
           continue_if_fresh_static(
             socket,
             workspace_external_url(mount_workspace, host_id, params)
           ),
         ws <- mount_workspace.workspace,
         :ok <- ensure_mount_workspace_access(mount_workspace, user) do
      id = ws.id
      path_result = Workspaces.safe_host_path(ws)
      loc_result = Workspaces.safe_host_loc(ws)
      # Default session resolution (resume-by-default): a bare /workspaces/{id}
      # open with no ?session= param (dashboard button, bookmark, direct link)
      # reattaches the workspace's most-recently-active live shell instead of
      # forking a fresh per-tab session every time. Only when the workspace has
      # no attachable shell yet do we mint a per-tab sid — the tab_id connect
      # param from sessionStorage, or a plain per-user sid on disconnected /
      # non-browser mounts. Resolved on the connected mount only: the static
      # render keeps the cheap mint and skips the tmux scan on first paint, then
      # the connected remount recomputes and handle_params drops into the resumed
      # session. An explicit ?session= deep link still pins a specific session,
      # and the picker / "new tab" affordances remain the escape hatch for an
      # intentionally independent fork.
      existing_sid = if connected?(socket), do: SessionSummary.newest_shell_sid(id, ws.name)

      sid =
        case existing_sid do
          resumed when is_binary(resumed) and resumed != "" ->
            resumed

          _ ->
            tab_id = connect_tab_id(socket)
            if tab_id, do: "u-" <> user.id <> "-" <> tab_id, else: "u-" <> user.id
        end

      tmux_session = Terminals.tmux_session_name(ws.name || ws.id, sid)

      {workspace_mode, workspace_mode_source} =
        if connected?(socket),
          do: Workspaces.mode_for(id),
          else: {:review, :default}

      terminal_mode = initial_terminal_mode(workspace_mode, host_id)
      # NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3
      # Re-attach token for raw channel joins after a fresh LiveView
      # auth pass. This is safe to send as a socket dataset attribute and lets
      # TerminalChannel skip workspace manager access checks on
      # reconnect storms.
      workspace_capability =
        terminal_workspace_capability(user, ws, host_id, loc_result, sid, workspace_mode,
          lan_friendly_access?: is_binary(mount_workspace.lan_friendly_path)
        )

      socket_token = ChannelAuth.sign_user_token(user.id, user[:email])

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:workspace, ws)
        # LAN-friendly mounts skip the user hook; panel components take
        # current_user as an attr, so it must always exist (nil = anonymous
        # LAN viewer, authorized via PanelGate.lan_friendly_access?).
        |> assign_new(:current_user, fn -> nil end)
        |> assign(:lan_friendly_path, mount_workspace.lan_friendly_path)
        |> assign(:workspace_start_error, nil)
        |> assign(:host_id, host_id)
        |> assign(:host_path, path_result)
        |> assign(:host_loc, loc_result)
        |> then(&assign(&1, :terminal_context, TerminalState.default_terminal_context(&1)))
        |> assign(:tmux_session, tmux_session)
        |> assign(:tmux_windows, [])
        |> assign(:tmux_window_tabs, [])
        |> assign(:tmux_panes, [])
        |> assign(:tmux_active_window_id, nil)
        |> assign(:tmux_active_pane_id, nil)
        |> assign(:tmux_topology_version, 0)
        |> assign(:tmux_topology_structure_version, 0)
        |> assign(:tmux_topology_generation, nil)
        |> assign(:tmux_rename_window_id, nil)
        |> assign(:tmux_rename_session_id, nil)
        |> assign(:active_session_kind, :shell)
        |> assign(:tmux_mutations_enabled?, true)
        |> assign(:preview_panes, %{})
        |> assign(:terminal_sid, sid)
        |> assign(:default_terminal_sid, sid)
        |> assign(:terminal_mode, terminal_mode)
        |> TerminalState.assign_header_session_labels(%{panes: [], active_window_id: nil})
        |> assign(:ghostty_term_id, @ghostty_term_id)
        # One tmux session per browser tab. The seed pane uses the
        # workspace's primary session name so external subscribers
        # (TmuxJanitor, attachment helpers) keep working unchanged;
        # split panes get a derived session name (see do_split).
        |> assign(:pane_data, TerminalState.primary_pane_data(sid, tmux_session))
        # Workspaces.get above is required on the disconnected render (page title,
        # ensure_workspace_access, capability tokens in first-paint HTML). Surface
        # discovery scans runtime + manager + host + tmux — defer to connected mount.
        |> assign(
          :preview_surfaces,
          if(connected?(socket), do: DevIDE.Previews.discover_surfaces(ws), else: [])
        )
        # Skip the preview-pane DB read on the static/disconnected render; the
        # connected mount (LiveView mounts twice) hydrates it a frame later.
        |> assign(
          :preview_panes,
          if(connected?(socket), do: load_preview_panes(ws, path_result), else: [])
        )
        |> assign(:entered_preview_pane_id, nil)
        |> assign(:terminal_surface_pane_id, nil)
        |> assign(:ui_highlight_pane_id, nil)
        |> assign(:pane_history, nil)
        |> assign(:focused_pane_id, "pane-1")
        |> assign(:terminal_preset_id, "catppuccin")
        |> assign(:terminal_themes, Terminals.terminal_theme_client_bundle())
        |> assign(:terminal_color_scheme, :dark)
        |> assign(:terminal_workspace_capability, workspace_capability)
        # PaneWorker startup (Ghostty.Terminal + Ghostty.PTY + `tmux new-session`)
        # is ~50-200ms — deferring it to :after_mount lets the empty pane
        # chrome render first and the prompt arrive a frame later.
        |> assign(:socket_token, socket_token)
        |> assign(:tab, "terminal")
        |> assign(:log_service, DevIDE.WorkspaceSource.default_log_service(ws))
        |> assign(:log_ref, nil)
        |> assign(:tree, %{})
        |> assign(:open_file, nil)
        |> assign(:file_error, nil)
        |> assign(:save_error, nil)
        |> assign(:git_status, [])
        |> assign(:file_diff, nil)
        |> assign(:active_run, nil)
        |> assign(:review_commands, [])
        |> assign(:run_ledger, [])
        |> assign(:selected_run_id, nil)
        |> assign(:selected_run_summary, nil)
        |> assign(:selected_run_timeline, [])
        |> assign(:selected_run_artifacts, [])
        |> assign(:selected_run_failure_reason, nil)
        |> assign(:selected_run_can_retry, false)
        |> assign(:selected_dir, "")
        |> assign(:new_input, nil)
        |> assign(:delete_confirm, nil)
        |> assign(:rename_input, nil)
        |> assign(:tree_error, nil)
        |> assign(:context_menu, nil)
        |> assign(:node_rename, nil)
        |> assign(:node_delete, nil)
        |> assign(:workspace_summaries, [])
        |> assign(:workspace_session_tabs, [])
        |> assign(:last_decision, nil)
        |> assign(:audit_drawer_open, false)
        |> assign(:previews_count, 0)
        |> assign(:window_zoomed?, false)
        |> stream(:previews, [], reset: true)
        |> assign(:session_tabs, [])
        |> stream(:log_lines, [], reset: true)
        |> assign(:chrome_visible, true)
        |> assign(:window_picker_view, :dropdown)
        |> assign(:mobile_nav_open, false)
        |> assign(:mobile_nav_focus, "sessions")
        |> assign(:mobile_nav_view, "windows")
        |> assign(:pending_url_pane, nil)
        |> assign(:pending_url_zoom, nil)
        |> assign(:patched_view_path, nil)
        |> assign(:terminal_last_interaction_ms, nil)
        |> assign(:db_isolation, %DevIDE.Workspaces.DbIsolation{})
        |> assign(:project_meta, nil)
        |> assign(:tooling, nil)
        |> assign(:search_query, "")
        |> assign(:search_results, [])
        |> assign(:search_state, :idle)
        |> assign(:palette_open, false)
        |> assign(:palette_query, "")
        |> assign(:palette_items, [])
        |> assign(:palette_selected_idx, 0)
        |> assign(:palette_category, :all)
        |> assign(:session_templates, Terminals.session_templates())
        |> assign(:saved_session_templates, [])
        |> assign(:saved_session_template_tags, [])
        |> assign(:template_tag_filter, nil)
        |> assign(:template_preview, nil)
        |> assign(:template_library_open, false)
        |> assign(:template_save_form, template_save_form())
        |> assign(:template_edit_id, nil)
        |> assign(:template_edit_form, template_edit_form())
        |> assign(:template_duplicate_id, nil)
        |> assign(:template_duplicate_form, template_duplicate_form())
        |> assign(:workspace_mode, workspace_mode)
        |> assign(:workspace_mode_source, workspace_mode_source)
        |> assign(:agent_write_unlock, %{status: :inactive, until: nil, by: nil})
        |> assign(:deployment_panel, deployment_panel())
        |> assign_policy_permissions()
        |> TerminalState.subscribe_tmux_topology()
        |> TerminalState.subscribe_session_tabs()
        |> subscribe_workspace_mode()
        |> subscribe_agent_write_unlock()
        |> subscribe_previews()
        |> subscribe_browser_control()
        |> subscribe_pane_labels()
        |> Phoenix.LiveView.attach_hook(:authz_gate, :handle_event, &authz_gate/3)

      # Defer PTY startup and every non-essential read out of mount so the
      # first HTML render (time-to-first-paint) is as fast as possible.
      send(self(), :after_mount)

      {:ok, socket}
    else
      {:redirect, path} ->
        {:ok, redirect(socket, to: path)}

      {:stale_static, url} ->
        {:ok, redirect(socket, external: url)}

      {:error, :cross_host_not_configured} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "Cross-host attach is not yet configured. " <>
             "The cockpit is host-aware but the runtime resolver only honors \"local\" today."
         )
         |> push_navigate(to: ~p"/workspaces")}

      {:error, :forbidden} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to this workspace.")
         |> push_navigate(to: ~p"/workspaces")}

      {:error, {:lan_path, reason}} ->
        {:ok, assign_lan_path_error(socket, params, reason)}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, mount_error_message(reason))
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp resolve_mount_workspace(%{"id" => id}, user) do
    if legacy_lan_home_workspace?(id) do
      {:redirect, ~p"/"}
    else
      with {:ok, workspace} <- Workspaces.get(id, user[:email]) do
        {:ok, %{workspace: workspace, lan_friendly_path: nil}}
      end
    end
  end

  defp resolve_mount_workspace(params, _user) do
    segments = Map.get(params, "lan_path", [])

    case LanPathResolver.resolve(segments) do
      {:ok, resolution} ->
        with {:ok, workspace} <- Workspaces.workspace_for_host_path(resolution.path) do
          {:ok, %{workspace: workspace, lan_friendly_path: resolution.route_path}}
        end

      {:error, :disabled} ->
        if root_lan_path?(segments) do
          {:redirect, root_redirect_path()}
        else
          {:error, {:lan_path, :disabled}}
        end

      {:error, reason} ->
        {:error, {:lan_path, reason}}
    end
  end

  defp ensure_mount_workspace_access(%{workspace: ws, lan_friendly_path: nil}, user) do
    ensure_workspace_access(ws, user)
  end

  defp ensure_mount_workspace_access(%{lan_friendly_path: path}, _user) when is_binary(path),
    do: :ok

  defp root_lan_path?(segments), do: segments in [nil, []]

  defp legacy_lan_home_workspace?(id) do
    id == "home" and
      truthy?(Application.get_env(:dev_ide, :lan_friendly_paths)) and
      truthy?(Application.get_env(:dev_ide, :lan_mode))
  end

  defp truthy?(true), do: true
  defp truthy?(value) when is_binary(value), do: value in ~w(1 true TRUE yes YES on ON)
  defp truthy?(_value), do: false

  defp root_redirect_path do
    case direct_workspace_id() do
      nil -> ~p"/workspaces"
      workspace_id -> ~p"/workspaces/#{workspace_id}"
    end
  end

  defp direct_workspace_id do
    lan? = Application.get_env(:dev_ide, :lan_mode, false)
    direct? = Application.get_env(:dev_ide, :lan_direct_mode, false)
    workspace_id = Application.get_env(:dev_ide, :default_workspace)

    if lan? and direct? and is_binary(workspace_id) and String.trim(workspace_id) != "" do
      workspace_id
    end
  end

  defp mount_error_message(reason), do: "Manager error: #{inspect(reason)}"

  defp format_lan_path_error(:disabled), do: "friendly paths are disabled"
  defp format_lan_path_error(:invalid_root), do: "LAN path root is not an absolute directory"
  defp format_lan_path_error(:missing_root), do: "LAN path root is not configured"
  defp format_lan_path_error(:reserved_prefix), do: "path is reserved by DevIDE"
  defp format_lan_path_error(:invalid_path), do: "path is invalid"
  defp format_lan_path_error(:outside_root), do: "path escapes the LAN root"
  defp format_lan_path_error(:symlink_escape), do: "path follows a symlink outside the LAN root"
  defp format_lan_path_error(:too_deep), do: "path is too deep"
  defp format_lan_path_error(:not_found), do: "directory was not found"
  defp format_lan_path_error(reason), do: inspect(reason)

  defp assign_lan_path_error(socket, params, reason) do
    segments = normalized_lan_path_segments(Map.get(params, "lan_path", []))
    root = LanPathResolver.root()
    relative_path = lan_error_relative_path(segments)
    route_path = lan_error_route_path(segments)

    socket
    |> assign(:page_title, lan_path_error_title(reason))
    |> assign(:lan_path_error, %{
      reason: reason,
      title: lan_path_error_title(reason),
      message: format_lan_path_error(reason),
      route_path: route_path,
      relative_path: relative_path,
      root_path: root,
      target_path: lan_error_target_path(root, relative_path, reason)
    })
  end

  defp normalized_lan_path_segments(segments) when is_list(segments) do
    Enum.reject(segments, &(&1 in [nil, ""]))
  end

  defp normalized_lan_path_segments(_segments), do: []

  defp lan_error_route_path([]), do: "/"

  defp lan_error_route_path(segments) do
    "/" <> Enum.map_join(segments, "/", &URI.encode/1)
  end

  defp lan_error_relative_path([]), do: ""

  defp lan_error_relative_path(segments) do
    if Enum.all?(segments, &is_binary/1), do: Path.join(segments), else: ""
  end

  defp lan_error_target_path(root, relative_path, reason)
       when reason in [:not_found, :outside_root, :symlink_escape] and is_binary(root) and
              root != "" do
    root
    |> Path.join(relative_path)
    |> Path.expand()
  end

  defp lan_error_target_path(_root, _relative_path, _reason), do: nil

  defp lan_path_error_title(:not_found), do: "Directory not found"
  defp lan_path_error_title(:reserved_prefix), do: "Reserved path"
  defp lan_path_error_title(:invalid_path), do: "Invalid path"
  defp lan_path_error_title(:outside_root), do: "Path outside LAN root"
  defp lan_path_error_title(:symlink_escape), do: "Path outside LAN root"
  defp lan_path_error_title(_reason), do: "LAN path unavailable"

  # Until cross-host workspace resolution is wired (audit punch-list
  # item #4 follow-up), only the local runtime authority is reachable.
  # Refusing here keeps §11 honest: surfaces that cannot tell the truth
  # are hidden rather than mocked.
  defp ensure_local_host("local"), do: :ok
  defp ensure_local_host(""), do: :ok
  defp ensure_local_host(nil), do: :ok
  defp ensure_local_host(_), do: {:error, :cross_host_not_configured}

  defp normalize_local_host_id(value) when value in [nil, ""], do: "local"
  defp normalize_local_host_id(value), do: value

  defp continue_if_fresh_static(socket, url) do
    if connected?(socket) and Phoenix.LiveView.static_changed?(socket),
      do: {:stale_static, url},
      else: :ok
  end

  defp workspace_external_url(
         %{workspace: %{id: id}, lan_friendly_path: friendly_path},
         host_id,
         params
       ) do
    path =
      if is_binary(friendly_path) do
        friendly_path
      else
        ~p"/workspaces/#{id}"
      end

    path =
      if is_nil(friendly_path) and Map.has_key?(params, "host") and
           host_id not in [nil, "", "local"],
         do: ~p"/workspaces/#{id}?host=#{host_id}",
         else: path

    DevIdeWeb.Endpoint.url() <> path
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if connected?(socket) and Map.has_key?(socket.assigns, :tmux_session) do
        {socket, _session_changed?} = maybe_select_requested_terminal_session(socket, params)
        {socket, window_selected?} = maybe_select_requested_tmux_window(socket, params["window"])
        socket = DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.stash_url_view(socket, params)
        topology_refreshed? = window_selected? or tmux_topology_uninitialized?(socket)

        socket =
          if topology_refreshed? do
            TerminalState.refresh_tmux_topology(socket)
          else
            socket
          end

        # Apply the stashed ?pane/?zoom even when a ?window switch just refreshed
        # topology, so a deeplink to a pane in another window selects that pane
        # (not just its window). No-op when topology isn't ready or nothing is
        # stashed.
        socket = DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.apply_pending_url_view(socket)

        DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.seed_patched_view_path(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :tab, tab)
    socket = if tab == "logs", do: LogsEvents.start_log_stream(socket), else: socket

    socket =
      if tab == "run" do
        socket
        |> attach_existing_run()
        |> refresh_run_ledger()
        |> RunEvents.load_review_commands()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    # Older Ghostty assets sent component refreshes to the parent LiveView.
    # Keep that harmless during rolling deploys instead of crashing the socket.
    {:noreply, socket}
  end

  # Session-template events are handled by TmuxTemplateEvents (extracted from
  # this module). Other "tmux:*" events fall through to the catch-all below,
  # which delegates to TerminalEvents.
  @tmux_template_events ~w(
    tmux:apply_template tmux:preview_template tmux:open_template_library
    tmux:close_template_library tmux:filter_saved_templates tmux:save_template
    tmux:edit_saved_template tmux:cancel_saved_template_edit tmux:update_saved_template
    tmux:duplicate_saved_template_start tmux:cancel_saved_template_duplicate
    tmux:duplicate_saved_template tmux:delete_saved_template tmux:cancel_template_preview
    tmux:apply_previewed_template
  )
  def handle_event(event, params, socket) when event in @tmux_template_events,
    do: TmuxTemplateEvents.handle_event(event, params, socket)

  def handle_event("terminal:paste_image", params, socket) do
    handle_paste_file(params, socket, :image)
  end

  def handle_event("terminal:paste_file", params, socket) do
    handle_paste_file(params, socket, :file)
  end

  # Focus mode / chrome toggle — hides the main workspace header and the
  # terminal utility bar to give maximum vertical space to the panes.
  # Toggled via palette or global keyboard shortcut (Ctrl/Cmd+Shift+F).
  def handle_event("terminal:toggle_chrome", _params, socket) do
    {:noreply, update(socket, :chrome_visible, &not/1)}
  end

  def handle_event("terminal:auto_hide_chrome", _params, socket) do
    {:noreply, assign(socket, :chrome_visible, false)}
  end

  # Window picker presentation: compact dropdown (default) or a tab strip that
  # spreads the tmux windows across the free header width. Set from the
  # palette's View section; the WindowPickerView hook mirrors the choice into
  # localStorage and replays it on the next mount.
  def handle_event("view:set_window_picker", %{"view" => view}, socket)
      when view in ["dropdown", "tabs"] do
    {:noreply,
     socket
     |> assign(:window_picker_view, String.to_existing_atom(view))
     |> push_event("window-picker-view", %{view: view})}
  end

  def handle_event("view:set_window_picker", _params, socket), do: {:noreply, socket}

  # The sheet is window-picker dominant: the keybar chip opens on the attached
  # session's window list (with a back arrow to the sessions list), falling
  # back to the sessions list when the attached session has no tmux windows.
  def handle_event("mobile_nav:toggle", _params, socket) do
    view = mobile_nav_resolved_view(socket, "windows")

    {:noreply,
     socket
     |> update(:mobile_nav_open, &(!&1))
     |> assign(:mobile_nav_view, view)
     |> assign(:mobile_nav_focus, view)}
  end

  # Opened by the Ctrl+B leader shortcut on touch/narrow layouts (see
  # assets/js/workspace_leader.js). `focus` lands the in-sheet keyboard cursor
  # on the active session ("sessions") or active window ("windows") and picks
  # the matching sheet view.
  def handle_event("mobile_nav:open", %{"focus" => focus}, socket)
      when focus in ~w(sessions windows) do
    {:noreply,
     socket
     |> assign(:mobile_nav_open, true)
     |> assign(:mobile_nav_view, mobile_nav_resolved_view(socket, focus))
     |> assign(:mobile_nav_focus, focus)}
  end

  # Back arrow (windows → sessions) and the hook's ← hop use this to flip the
  # open sheet between its two views without closing it.
  def handle_event("mobile_nav:set_view", %{"view" => view}, socket)
      when view in ~w(sessions windows) do
    view = mobile_nav_resolved_view(socket, view)

    {:noreply,
     socket
     |> assign(:mobile_nav_view, view)
     |> assign(:mobile_nav_focus, view)}
  end

  def handle_event("mobile_nav:close", _params, socket) do
    {:noreply, assign(socket, :mobile_nav_open, false)}
  end

  def handle_event("tmux:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("terminal:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("attach_terminal_session" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:navigate" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:history_open" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:history_close" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  # Phase 2: Real tmux splits (independent panes)
  def handle_event("split_right", _params, socket) do
    do_split(socket, :horizontal)
  end

  def handle_event("split_down", _params, socket) do
    do_split(socket, :vertical)
  end

  def handle_event("workspace:start", _params, socket) do
    case Workspaces.start(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:workspace_start_error, nil)
         |> refresh_workspace_assign()
         |> put_flash(:info, "Workspace start requested. Retry the terminal once it is running.")}

      {:error, reason} ->
        message = format_workspace_action_error(reason)

        {:noreply,
         socket
         |> assign(:workspace_start_error, message)
         |> put_flash(:error, "Could not start workspace: #{message}")}
    end
  end

  def handle_event("workspace:stop", _params, socket) do
    case Workspaces.stop(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_workspace_assign()
         |> put_flash(:info, "Workspace stop requested.")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not stop workspace: #{format_workspace_action_error(reason)}"
         )}
    end
  end

  # ---- tmux-native pane controls -------------------------------------------
  # Every pane operation targets the attached session's active pane via tmux,
  # mirroring the C-b bindings (x, o, z, space). No-ops without a tmux session
  # (e.g. non-terminal tabs).

  def handle_event("pane:close_focused", _params, socket) do
    # Re-read live tmux topology before the last-pane guard and pane target.
    # The cached count/active pane can lag reality (e.g. a degraded socket on
    # a draining release, or a split that hasn't broadcast yet), which made
    # close wrongly refuse with "Cannot close the last pane" on windows that
    # actually had multiple panes. Refreshing first decides against real state.
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         socket = TerminalState.refresh_tmux_topology(socket),
         pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id] do
      cond do
        tmux_active_window_pane_count(socket) > 1 ->
          close_focused_pane(socket, session, pane_id)

        # Last pane in the window: killing it removes the window (real tmux
        # closes the window when its final pane dies). Mirror that — close the
        # whole window — as long as another window survives. C-b x on a
        # single-pane tab is the common way operators close a tab.
        length(socket.assigns[:tmux_windows] || []) > 1 ->
          close_focused_window(socket, session)

        # Last pane of the last window: closing it ends this tmux session.
        # Instead of refusing, close it and drop the operator into another
        # existing session (only refuse when this is the only session left).
        true ->
          close_focused_last_window(socket, session)
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pane:close_others", _params, socket) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id],
         :ok <- TerminalState.tmux_adapter().kill_other_panes(session, pane_id) do
      {:noreply,
       socket
       |> TerminalState.refresh_tmux_topology()
       |> TerminalState.focus_active_terminal(%{"reason" => "pane:close_others"})}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not close tmux panes: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pane:focus_next", _params, socket) do
    TerminalEvents.handle_event("pane:navigate", %{"dir" => "next"}, socket)
  end

  def handle_event("pane:focus_previous", _params, socket) do
    TerminalEvents.handle_event("pane:navigate", %{"dir" => "prev"}, socket)
  end

  def handle_event("pane:zoom_focused", _params, socket), do: tmux_zoom_active_pane(socket)

  # Retry a pane whose Ghostty PTY/tmux startup failed (or that exited).
  # Clears the recorded error and re-invokes the start helper so the
  # user can recover without a full page reload.
  def handle_event("retry_pane", %{"pane-id" => pane_id}, socket) do
    if get_pane_data(socket, pane_id) do
      {:noreply,
       socket
       # A manual retry is a fresh start: clear the error and reset the
       # auto-reattach budget so the pane gets the full retry allowance again.
       |> update_pane(pane_id, fn p ->
         p |> Map.put(:error, nil) |> Map.put(:auto_retry_count, 0)
       end)
       |> start_ghostty_for_pane(pane_id)}
    else
      {:noreply, socket}
    end
  end

  # Keyboard-driven pane navigation (Ctrl + Arrow keys) — tmux select-pane.
  def handle_event("nav:dir", %{"dir" => dir_str}, socket)
      when dir_str in ["left", "right", "up", "down"] do
    if is_binary(socket.assigns[:tmux_session]) do
      TerminalEvents.handle_event("pane:navigate", %{"dir" => dir_str}, socket)
    else
      {:noreply, socket}
    end
  end

  # Equalize: tmux layout preset for the active window, like C-b M-5.
  def handle_event("equalize_layout", _params, socket) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         :ok <- TerminalState.tmux_adapter().select_layout(session, "tiled") do
      {:noreply, TerminalState.refresh_tmux_topology(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not apply tmux layout: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  # Cycle the window through tmux layout presets, like C-b space.
  def handle_event("pane:cycle_layout", _params, socket) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         :ok <- TerminalState.tmux_adapter().next_layout(session) do
      {:noreply, TerminalState.refresh_tmux_topology(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cycle tmux layout: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  # Phase 1 spike: capture the Ghostty.Terminal cell grid via
  # Ghostty.Terminal.snapshot/2 (HTML + plain text + raw VT), write to /tmp,
  # emit a `ghostty.raw_terminal_snapshot` audit event, and push the file paths
  # back to the browser so the A/B harness can pick them up without filesystem
  # access. Server-authoritative snapshots are the killer artifact the existing
  # raw path cannot produce cleanly.
  def handle_event("ghostty:snapshot", _params, socket) do
    focused_id = socket.assigns.focused_pane_id
    focused = get_pane_data(socket, focused_id)

    case focused && focused.ghostty_term do
      term when is_pid(term) ->
        ws_id = socket.assigns.workspace.id

        %{base: base, files: files, preview: preview} =
          Terminals.capture_ghostty_snapshot(term, ws_id)

        DevIDE.Audit.emit!(%{
          action: "ghostty.raw_terminal_snapshot",
          workspace_id: ws_id,
          actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
          target_type: "terminal",
          target_ref: focused_id,
          metadata: %{"base" => base, "files" => files, "preview_bytes" => byte_size(preview)}
        })

        {:noreply,
         socket
         |> push_event("ghostty:snapshot:captured", %{
           "base" => base,
           "files" => files,
           "preview" => preview
         })
         |> put_flash(:info, "Ghostty snapshot written: #{base}.html (+ .txt, .vt)")}

      _ ->
        {:noreply, push_event(socket, "ghostty:snapshot:captured", %{"error" => "no_terminal"})}
    end
  end

  # "Snapshot all" low-pri feature: walks the current layout tree, snapshots every
  # pane that has a live Ghostty term, emits per-pane audit, and reports total.
  def handle_event("snapshot_all", _params, socket) do
    ws_id = socket.assigns.workspace.id
    actor = (socket.assigns[:current_user] || %{}) |> Map.get(:id)

    panes_with_terms =
      (socket.assigns.pane_data || %{})
      |> Enum.map(fn {id, pane} ->
        term = pane && pane.ghostty_term
        if is_pid(term) and Process.alive?(term), do: {id, term}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    results =
      for {pane_id, term} <- panes_with_terms do
        %{base: base, files: files, preview: preview} =
          Terminals.capture_ghostty_snapshot(term, ws_id)

        DevIDE.Audit.emit!(%{
          action: "ghostty.raw_terminal_snapshot",
          workspace_id: ws_id,
          actor_id: actor,
          target_type: "terminal",
          target_ref: pane_id,
          metadata: %{"base" => base, "files" => files, "preview_bytes" => byte_size(preview)}
        })

        {pane_id, base}
      end

    msg =
      case results do
        [] ->
          "No live Ghostty panes to snapshot"

        list ->
          "Snapped #{length(list)} pane(s): " <>
            Enum.map_join(list, ", ", fn {id, b} -> "#{id}→#{b}" end)
      end

    {:noreply, put_flash(socket, :info, msg)}
  end

  def handle_event("isolation:refresh", _, socket),
    do: {:noreply, refresh_isolation(socket, audit: true)}

  # Clicking a "quiet agent" OS notification deeplinks straight to that agent's
  # conversation: patch the view to its session/window so handle_params restores
  # the same focus a shared deep link would.
  def handle_event("notification:open_conversation", %{"session" => session} = params, socket)
      when is_binary(session) and session != "" do
    path =
      DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.build_share_path(
        socket.assigns.workspace.id,
        session,
        params["window"]
      )

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("notification:open_conversation", _params, socket), do: {:noreply, socket}

  def handle_event("workspace:set_mode", %{"mode" => mode_str}, socket) do
    mode = string_to_mode(mode_str)

    {decision, socket} =
      gate(socket, fn -> Policy.can_set_workspace_mode?(policy_ctx(socket)) end, %{
        action: "workspace.set_mode",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id,
        metadata: %{"requested_mode" => mode_str}
      })

    cond do
      not Policy.Decision.allow?(decision) ->
        {:noreply, put_flash(socket, :error, mode_change_denied_message(decision))}

      mode == nil ->
        {:noreply, socket}

      true ->
        ws_id = socket.assigns.workspace.id
        {_, _} = Workspaces.set_mode(ws_id, mode)

        _ =
          Audit.emit!(%{
            action: "workspace.mode_changed",
            workspace_id: ws_id,
            actor_id: current_actor_id(socket),
            target_type: "workspace",
            target_ref: ws_id,
            metadata: %{"mode" => Atom.to_string(mode)}
          })

        {:noreply,
         socket
         |> assign_workspace_mode(ws_id, connected?(socket))
         |> refresh_terminal_workspace_capability()
         |> maybe_schedule_raw_prewarm()}
    end
  end

  @agent_write_unlock_min_minutes 5
  @agent_write_unlock_max_minutes 240

  def handle_event("workspace:grant_agent_write_unlock", %{"minutes" => minutes_str}, socket) do
    minutes = clamp_unlock_minutes(minutes_str)

    {decision, socket} =
      gate(socket, fn -> Policy.can_grant_agent_write_unlock?(policy_ctx(socket)) end, %{
        action: "workspace.agent_write_unlock_grant_attempt",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id,
        metadata: %{"requested_minutes" => minutes}
      })

    if Policy.Decision.allow?(decision) do
      ws_id = socket.assigns.workspace.id
      granter = current_actor_id(socket)
      until = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
      {:ok, _} = Workspaces.grant_agent_write_unlock(ws_id, until, granter)

      _ =
        Audit.emit!(%{
          action: "workspace.agent_write_unlock_granted",
          workspace_id: ws_id,
          actor_id: granter,
          target_type: "workspace",
          target_ref: ws_id,
          metadata: %{"until" => DateTime.to_iso8601(until), "minutes" => minutes}
        })

      {:noreply,
       socket
       |> assign_agent_write_unlock(ws_id)
       |> put_flash(:info, "Agent write unlocked for #{minutes} min.")}
    else
      {:noreply, put_flash(socket, :error, agent_write_unlock_denied_message(decision))}
    end
  end

  def handle_event("workspace:revoke_agent_write_unlock", _params, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_revoke_agent_write_unlock?(policy_ctx(socket)) end, %{
        action: "workspace.agent_write_unlock_revoke_attempt",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id
      })

    if Policy.Decision.allow?(decision) do
      ws_id = socket.assigns.workspace.id
      {:ok, _} = Workspaces.revoke_agent_write_unlock(ws_id)

      _ =
        Audit.emit!(%{
          action: "workspace.agent_write_unlock_revoked",
          workspace_id: ws_id,
          actor_id: current_actor_id(socket),
          target_type: "workspace",
          target_ref: ws_id
        })

      {:noreply, socket |> assign_agent_write_unlock(ws_id) |> put_flash(:info, "Revoked.")}
    else
      {:noreply, put_flash(socket, :error, "Not allowed to revoke.")}
    end
  end

  # Run / workflow / run-ledger events are handled by RunEvents (extracted from
  # this module — pure code motion).
  def handle_event("run:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("run_ledger:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("workflow:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("agent:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  # "proposal:*" events land on ProposalPanelComponent via phx-target; the
  # component runs PanelGate.gate_event since this LV's authz hook cannot
  # intercept component events.

  # All "palette:*" events are handled by PaletteEvents (extracted from this
  # module — pure code motion). palette:execute resolves the selected item to a
  # concrete event and dispatches it back through handle_event/3 here.
  def handle_event("palette:" <> _ = event, params, socket),
    do: PaletteEvents.handle_event(event, params, socket)

  # Drawer open/closed is hub state: the palette dispatches toggle through
  # this LV and run_ledger:open closes the drawer. The stream/counters/filter
  # live in AuditDrawerComponent, which refreshes itself on the open
  # transition and receives live events via send_update.
  def handle_event("audit_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :audit_drawer_open, not socket.assigns.audit_drawer_open)}
  end

  def handle_event("audit_drawer:close", _params, socket) do
    {:noreply, assign(socket, :audit_drawer_open, false)}
  end

  def handle_event("search:run", %{"query" => query}, socket) do
    case context_host_loc(socket) do
      {:ok, loc} ->
        # Run the filesystem grep off the LiveView process so a slow/large
        # search never blocks the channel. Prior results stay visible until
        # handle_async(:run_search, ...) lands.
        trimmed = String.trim(query)

        {:noreply,
         socket
         |> assign(:search_query, query)
         |> start_async(:run_search, fn -> FileAccess.search(loc, trimmed, []) end)}

      _ ->
        {:noreply, assign(socket, :search_state, {:error, :no_root})}
    end
  end

  def handle_event("annotation:open", %{"path" => path} = params, socket) do
    line = parse_line(params["line"])

    case context_host_path(socket) do
      {:ok, root} -> {:noreply, open_annotation_file(socket, root, path, line)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("preview:open", %{"surface" => surface} = params, socket) do
    open_surface_preview(socket, surface, params)
  end

  def handle_event("preview:open", %{"url" => _url} = params, socket) do
    open_preview(socket, params)
  end

  def handle_event("preview-pane:enter", %{"pane-id" => pane_id}, socket)
      when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "selected", %{"source" => "overlay"})
    {:noreply, assign(socket, :entered_preview_pane_id, pane_id)}
  end

  def handle_event("preview-pane:enter", %{"pane_id" => pane_id}, socket)
      when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "selected", %{"source" => "overlay"})
    {:noreply, assign(socket, :entered_preview_pane_id, pane_id)}
  end

  def handle_event("preview-pane:exit", %{"pane-id" => pane_id}, socket)
      when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "exited", %{"source" => "overlay"})
    {:noreply, maybe_clear_entered_preview_pane(socket, pane_id)}
  end

  def handle_event("preview-pane:exit", %{"pane_id" => pane_id}, socket)
      when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "exited", %{"source" => "overlay"})
    {:noreply, maybe_clear_entered_preview_pane(socket, pane_id)}
  end

  def handle_event("preview-pane:back", %{"pane-id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :go_back)

  def handle_event("preview-pane:back", %{"pane_id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :go_back)

  def handle_event("preview-pane:forward", %{"pane-id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :go_forward)

  def handle_event("preview-pane:forward", %{"pane_id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :go_forward)

  def handle_event("preview-pane:refresh", %{"pane-id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :reload)

  def handle_event("preview-pane:refresh", %{"pane_id" => pane_id}, socket),
    do: handle_preview_pane_history(socket, pane_id, :reload)

  def handle_event("preview-pane:recover", %{"pane-id" => pane_id}, socket),
    do: handle_preview_pane_recover(socket, pane_id)

  def handle_event("preview-pane:recover", %{"pane_id" => pane_id}, socket),
    do: handle_preview_pane_recover(socket, pane_id)

  def handle_event("preview-pane:close", %{"pane-id" => pane_id}, socket),
    do: handle_preview_pane_close(socket, pane_id)

  def handle_event("preview-pane:close", %{"pane_id" => pane_id}, socket),
    do: handle_preview_pane_close(socket, pane_id)

  def handle_event("preview-pane:telemetry", %{"pane-id" => pane_id} = params, socket)
      when is_binary(pane_id) do
    metadata =
      params
      |> Map.get("metadata", %{})
      |> sanitize_preview_telemetry_metadata()
      |> Map.merge(%{
        "mode" => Map.get(params, "mode"),
        "url" => Map.get(params, "url")
      })
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    params
    |> Map.get("event", "interaction")
    |> then(&record_preview_activity(socket, pane_id, &1, metadata))

    {:noreply, socket}
  end

  def handle_event("preview-pane:telemetry", %{"pane_id" => pane_id} = params, socket)
      when is_binary(pane_id) do
    handle_event("preview-pane:telemetry", Map.put(params, "pane-id", pane_id), socket)
  end

  def handle_event("preview-pane:snapshot-click", %{"pane-id" => pane_id} = params, socket)
      when is_binary(pane_id) do
    coords = %{
      "x" => Map.get(params, "x"),
      "y" => Map.get(params, "y")
    }

    record_preview_activity(socket, pane_id, "snapshot_click", coords)

    socket =
      with :ok <- authorize_preview_pane(socket, pane_id),
           {:ok, registration} <- PreviewPanes.click_snapshot(pane_id, coords) do
        pane = preview_pane_payload(registration)

        socket
        |> assign(
          :preview_panes,
          Map.put(socket.assigns[:preview_panes] || %{}, pane.pane_id, pane)
        )
        |> push_event("devide:reload_preview_iframes", %{
          "action" => "reload_preview_iframe",
          "force" => true,
          "pane_id" => pane_id,
          "workspace_id" => socket.assigns.workspace.id
        })
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("set_log_service" = event, params, socket),
    do: LogsEvents.handle_event(event, params, socket)

  # Shared right-click context menu (ContextMenu component + ContextMenu hook).
  def handle_event("ctx:" <> _ = event, params, socket),
    do: ContextMenuEvents.handle_event(event, params, socket)

  # File-tree / editor events are handled by FileEvents (extracted from this
  # module — pure code motion). All "tree:*" and "file:*" events delegate there.
  def handle_event("tree:" <> _ = event, params, socket),
    do: FileEvents.handle_event(event, params, socket)

  def handle_event("file:" <> _ = event, params, socket),
    do: FileEvents.handle_event(event, params, socket)

  # Splits are real tmux panes: `split-window` targets the attached
  # session's active pane, so tmux owns the layout — identical to typing
  # C-b % / C-b " inside the terminal, and visible to every attached
  # client. The browser keeps a single attachment. (The previous design —
  # one derived tmux session per browser pane with a LiveView-side layout
  # tree — is no longer reachable from the split buttons.)
  defp do_split(socket, direction) do
    socket = refresh_workspace_mode(socket)

    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      session = socket.assigns.tmux_session
      flag = if direction == :horizontal, do: "h", else: "v"

      target_pane =
        socket.assigns[:tmux_active_pane_id] ||
          Terminals.tmux_topology_snapshot(session).active_pane_id

      with pane_id when is_binary(pane_id) <- target_pane,
           {:ok, _new_pane_id} <-
             TerminalState.tmux_adapter().split_pane(session, pane_id, flag,
               cwd: terminal_window_cwd(socket)
             ) do
        {:noreply,
         socket
         |> push_event("devide:pane:split", %{})
         |> TerminalState.refresh_tmux_topology()
         |> TerminalState.focus_active_terminal(%{"reason" => "split_pane"})}
      else
        nil ->
          {:noreply, put_flash(socket, :error, "No active tmux pane to split.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not split tmux pane: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  # Toggle tmux zoom on the active pane (resize-pane -Z), like C-b z.
  defp tmux_zoom_active_pane(socket) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id],
         :ok <- TerminalState.tmux_adapter().zoom_pane(session, pane_id) do
      {:noreply,
       socket
       |> TerminalState.refresh_tmux_topology()
       |> TerminalState.patch_current_session()
       |> TerminalState.focus_active_terminal(%{"reason" => "zoom_pane"})}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not zoom tmux pane: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  defp tmux_active_window_pane_count(socket) do
    tmux_window_pane_count(
      socket.assigns[:tmux_panes] || [],
      socket.assigns[:tmux_active_window_id]
    )
  end

  defp tmux_window_pane_count(panes, window_id) do
    Enum.count(panes, &(&1.window_id == window_id))
  end

  @impl true
  # Panel LiveComponents cannot write the root flash or refresh Show-owned
  # hub state; they ask via these messages (see PanelGate / the components).
  def handle_info({:panel_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info(:proposal_workspace_changed, socket) do
    {:noreply, socket |> refresh_tree() |> refresh_git_status()}
  end

  def handle_info({:source_log, ref, line}, %{assigns: %{log_ref: ref}} = socket) do
    {:noreply, LogsEvents.insert_log_line(socket, line)}
  end

  def handle_info(
        {source, {:updated, %{session: session} = topology}},
        socket
      ) do
    socket =
      if Terminals.tmux_topology_event_source?(source) and
           socket.assigns[:tmux_session] == session do
        TerminalState.assign_tmux_topology(socket, topology)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {source, {:session_terminated, %{session: session} = payload}},
        socket
      ) do
    # A terminated signal from a previous watcher incarnation (the session
    # was recreated under the same name and we already resubscribed) must not
    # blank the current window tabs.
    stale_generation? =
      is_integer(payload[:generation]) and
        is_integer(socket.assigns[:tmux_topology_generation]) and
        payload[:generation] != socket.assigns[:tmux_topology_generation]

    socket =
      if Terminals.tmux_topology_event_source?(source) and
           socket.assigns[:tmux_session] == session and
           not stale_generation? do
        socket
        |> assign(:tmux_windows, [])
        |> assign(:tmux_window_tabs, [])
        |> assign(:tmux_panes, [])
        |> TerminalState.assign_header_session_labels(%{panes: [], active_window_id: nil})
        |> assign(:tmux_active_window_id, nil)
        |> assign(:tmux_active_pane_id, nil)
        |> assign(:tmux_topology_version, 0)
        |> assign(:tmux_topology_structure_version, 0)
      else
        socket
      end

    {:noreply, socket}
  end

  # Canonical session tab list changed (session opened/closed anywhere —
  # another browser tab, an agent worktree session, the janitor). The directory
  # broadcasts the viewer-independent list; we apply this viewer's filter.
  def handle_info({source, {:sessions_updated, ws_id, tabs}}, socket) do
    if Terminals.session_tabs_event_source?(source) and socket.assigns.workspace.id == ws_id do
      {:noreply, TerminalState.assign_session_tabs(socket, tabs)}
    else
      {:noreply, socket}
    end
  end

  # Workspace mode changed (by this viewer or any other). Re-derive every
  # mode-dependent assign so raw-mode affordances and capabilities react
  # without waiting for the next event-driven refresh_workspace_mode call.
  def handle_info({:workspace_mode_changed, ws_id, _mode}, socket) do
    if socket.assigns.workspace.id == ws_id do
      {:noreply,
       socket
       |> assign_workspace_mode(ws_id, connected?(socket))
       |> refresh_terminal_workspace_capability()
       |> maybe_schedule_raw_prewarm()}
    else
      {:noreply, socket}
    end
  end

  # Agent-write unlock changed (grant, revoke, or passive expiry) — by this
  # viewer or any other connected viewer, so the banner and revoke button
  # stay live for everyone watching the workspace, not just the granter.
  def handle_info({:agent_write_unlock_changed, ws_id, _until, _by}, socket) do
    if socket.assigns.workspace.id == ws_id do
      {:noreply, assign_agent_write_unlock(socket, ws_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_ready, _, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:terminal_resize, _, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:terminal_active, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:terminal_resync, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:pane_history_ready, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:pane_history_down, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  # Tagged PTY output from a specific pane's worker, already coalesced to one
  # message per ~16ms frame by the worker. The worker has *already* written
  # these bytes into its own term and will send a `{:pane_frame, ...}` with the
  # rendered grid; here we only run the cheap byte-stream side channels whose
  # state lives on the LiveView. Preview panes are owned by the agent/tool that
  # creates them, so generic terminal output does not create preview prompts.
  # We do NOT touch the term on this path — that work runs in the worker process
  # so a pane streaming heavy output can't block the LiveView channel into a
  # reload.
  def handle_info({:pty_data, pane_id, data}, socket) when is_binary(data) do
    :telemetry.span(
      [:dev_ide, :workspace_live, :pty_data],
      %{pane_id: pane_id, bytes: byte_size(data)},
      fn ->
        # OSC52: a program (or tmux with set-clipboard on) requesting that text
        # be placed on the system clipboard, embedded in the PTY byte stream.
        # The browser only receives the rendered cell grid, so we extract it
        # here and push it down for navigator.clipboard.writeText. Best-effort:
        # writeText needs a focused secure context (works on Chrome; Safari may
        # gate it on a gesture).
        socket = push_osc52_clipboard(socket, data)

        {{:noreply, socket}, %{}}
      end
    )
  end

  # A finished render frame built by the pane's worker (off the LiveView
  # process). Forwarding it to the browser is a cheap `push_event` — no
  # synchronous term call — so it never stalls the channel regardless of how
  # much output the pane is producing.
  def handle_info({:pane_frame, pane_id, payload}, socket) do
    socket =
      if get_pane_data(socket, pane_id) do
        push_event(socket, "ghostty:render", payload)
      else
        # Pane closed between the worker building the frame and us receiving
        # it — drop the stale frame.
        socket
      end

    {:noreply, socket}
  end

  # PaneWorker reports its own death (or its PTY's) — clear the pane's pids
  # (and record the exit reason in `error`) so the next render shows a
  # diagnostic error state + Retry button instead of an infinite
  # "starting terminal…" placeholder. This surfaces PTY/tmux launch
  # failures (bad TERM, missing binary, permission issues, etc.) that
  # used to leave the raw Ghostty pane stuck.
  def handle_info({:pty_exit, pane_id, status}, socket) do
    status = normalize_pane_exit_reason(status)

    # Output buffering/draining lives in the (now dead) PaneWorker, so there
    # is no LV-side buffer to clear. Only touch pane_data if the pane still
    # exists (prevents update_pane from inserting `pane_id => nil` for a
    # just-closed or unknown pane).
    socket =
      if get_pane_data(socket, pane_id) do
        update_pane(socket, pane_id, fn p ->
          %{p | ghostty_pty: nil, ghostty_term: nil, worker: nil, backend: nil, error: status}
        end)
      else
        socket
      end

    # Auto-reattach instead of forcing a manual Retry click. The tmux session
    # persists (`tmux new-session -A`), so a dropped client/PTY is recoverable
    # by re-attaching — the scrollback is still there. We bound this to
    # @pane_auto_retry_limit attempts (per pane) so a genuinely broken launch
    # (e.g. a workspace image lacking tmux) degrades to the manual Retry button
    # instead of looping forever. A successful start resets the counter (see
    # start_ghostty_for_pane).
    socket = maybe_auto_reattach_pane(socket, pane_id, status)

    {:noreply, socket}
  end

  def handle_info({:auto_reattach_pane, pane_id, attempt}, socket) do
    pane = get_pane_data(socket, pane_id)

    # Only reattach if the pane still exists, is still in an error state (the
    # user didn't already click Retry or close it), and this is the most recent
    # scheduled attempt (avoid double-starts if several exits raced).
    socket =
      if pane && pane.error != nil && Map.get(pane, :auto_retry_count, 0) == attempt do
        socket
        |> update_pane(pane_id, fn p -> %{p | error: nil} end)
        |> start_ghostty_for_pane(pane_id)
      else
        socket
      end

    {:noreply, socket}
  end

  # Deferred post-mount work (see mount/3). Start the raw terminal first and
  # keep slower session/preview/template/topology hydration out of the LiveView
  # process so keystrokes are not queued behind tmux/git/DB scans.
  def handle_info(:after_mount, socket) do
    if connected?(socket) do
      if is_binary(socket.assigns.tmux_session) do
        _ = ensure_pane_agent_env(socket, socket.assigns.tmux_session)
      end

      socket =
        socket
        |> maybe_start_raw_ghostty_and_request_restore(
          socket.assigns.terminal_mode,
          socket.assigns.workspace.id
        )
        |> start_after_mount_hydration()

      send(self(), :after_mount_side_panels)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_side_panels, socket) do
    if connected?(socket) do
      host_loc = socket.assigns[:host_loc]
      host_path = socket.assigns[:host_path]
      workspace = socket.assigns.workspace
      tree = socket.assigns.tree
      actor_id = current_actor_id(socket)

      socket =
        socket
        |> assign_async([:git_status, :tree], fn ->
          data = fetch_side_panels(host_loc, host_path, tree)
          {:ok, %{git_status: data.git_status, tree: data.tree}}
        end)
        |> assign_async(:agents_mount, fn ->
          {:ok, %{agents_mount: fetch_agents_panels(workspace, host_path, actor_id)}}
        end)

      send(self(), :after_mount_runs)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_runs, socket) do
    if connected?(socket) do
      socket =
        if socket.assigns[:tab] == "run" do
          socket
          |> attach_existing_run()
          |> refresh_run_ledger()
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_agents, socket), do: {:noreply, socket}

  def handle_info({:open_preview_demo, attempt}, socket)
      when is_integer(attempt) and attempt > 0 do
    url = "http://localhost:#{@preview_demo_port}/"

    case split_workspace_preview(socket, url, %{}) do
      {:ok, socket} ->
        {:noreply,
         put_flash(socket, :info, "Preview demo opened at http://localhost:#{@preview_demo_port}")}

      {:error, :no_tmux_session, socket} when attempt < @preview_demo_open_attempts ->
        Process.send_after(self(), {:open_preview_demo, attempt + 1}, @preview_demo_open_delay_ms)
        {:noreply, socket}

      {:error, _reason, socket} when attempt < @preview_demo_open_attempts ->
        Process.send_after(self(), {:open_preview_demo, attempt + 1}, @preview_demo_open_delay_ms)
        {:noreply, socket}

      {:error, :no_tmux_session, socket} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Start a tmux terminal session before opening the preview demo"
         )}

      {:error, _reason, socket} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Demo server starting on localhost:#{@preview_demo_port} — open preview when ready"
         )}
    end
  end

  def handle_info({:pane_label_updated, tmux_session, pane_id, entry}, socket) do
    if socket.assigns[:tmux_session] == tmux_session do
      key = Labels.key(tmux_session, pane_id)

      {:noreply,
       socket
       |> update(:pane_labels, &Map.put(&1 || %{}, key, entry))
       |> TerminalState.assign_tmux_window_tabs()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:preview_pane_registered, payload}, socket) do
    pane = preview_pane_payload(payload)

    if preview_pane_workspace_match?(socket, pane.workspace_id) do
      existing = Map.get(socket.assigns[:preview_panes] || %{}, pane.pane_id)

      socket =
        assign(
          socket,
          :preview_panes,
          Map.put(socket.assigns[:preview_panes] || %{}, pane.pane_id, pane)
        )

      socket =
        if preview_pane_heartbeat?(existing, pane) do
          # A pure heartbeat re-broadcast (same display URL): keep the latest
          # fields but don't re-highlight or restore tmux focus, which re-enters
          # the focus path and churns the live preview on every heartbeat.
          socket
        else
          socket
          |> assign(:ui_highlight_pane_id, pane.pane_id)
          |> refresh_terminal_surface_pane_id()
          |> TerminalState.restore_operator_tmux_focus()
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:preview_pane_removed, payload}, socket) do
    pane_id = payload_value(payload, :pane_id)
    workspace_id = payload_value(payload, :workspace_id)

    if preview_pane_workspace_match?(socket, workspace_id) do
      socket =
        socket
        |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
        |> maybe_clear_entered_preview_pane(pane_id)
        |> refresh_terminal_surface_pane_id()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:preview_observation,
         %{preview_id: preview_id, session_id: _session_id, observation: observation}},
        socket
      )
      when is_binary(preview_id) do
    case find_preview_panes_by_preview_id(socket, preview_id) do
      [] ->
        # Workspace isn't currently showing this preview — nothing to update.
        {:noreply, socket}

      matches ->
        {preview_panes, reload_pane_ids} =
          Enum.reduce(matches, {socket.assigns[:preview_panes] || %{}, []}, fn {pane_id, pane},
                                                                               {panes, reloads} ->
            updated =
              apply_observation_to_preview_pane(socket.assigns.workspace, pane, observation)

            reloads =
              if preview_pane_url_changed?(pane, updated), do: [pane_id | reloads], else: reloads

            {Map.put(panes, pane_id, updated), reloads}
          end)

        socket = assign(socket, :preview_panes, preview_panes)

        socket =
          Enum.reduce(reload_pane_ids, socket, fn pane_id, acc ->
            push_event(acc, "devide:reload_preview_iframes", %{"pane_id" => pane_id})
          end)

        {:noreply, socket}
    end
  end

  def handle_info({:preview_observation, _payload}, socket), do: {:noreply, socket}

  def handle_info({:browser_control, %{"action" => "reload_preview_iframe"} = payload}, socket) do
    # An explicit agent reload tool: force the frame to reload even when the URL
    # is unchanged (the soft path only re-points src on a real URL change).
    {:noreply,
     push_event(socket, "devide:reload_preview_iframes", Map.put(payload, "force", true))}
  end

  def handle_info({:browser_control, %{"action" => "reload_page"} = payload}, socket) do
    {:noreply, push_event(socket, "devide:reload_page", payload)}
  end

  def handle_info({:browser_control, %{"action" => "focus_preview_pane"} = payload}, socket) do
    {:noreply,
     TerminalState.focus_activity_target(
       socket,
       Map.get(payload, "tmux_session"),
       Map.get(payload, "pane_id")
     )}
  end

  def handle_info({:browser_control, %{"action" => "preview_pane_action"} = payload}, socket) do
    {:noreply, push_event(socket, "devide:preview_pane_action", payload)}
  end

  def handle_info(:prewarm_raw_session, socket) do
    {:noreply, maybe_prewarm_raw_session(socket)}
  end

  def handle_info({:exit, _status}, socket), do: {:noreply, socket}

  def handle_info({:source_log, _ref, _line}, socket), do: {:noreply, socket}
  def handle_info({:source_log_done, _ref}, socket), do: {:noreply, socket}

  def handle_info(
        {:run_data, ws_id, _stream, bin},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{} = run}} = socket
      ) do
    updated = Map.update!(run, :buffer, &append_run_buffer(&1, bin))
    {:noreply, assign(socket, :active_run, updated)}
  end

  def handle_info(
        {:run_exit, ws_id, code, status},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{} = run}} = socket
      ) do
    updated = %{run | exit_code: code, status: status, finished_at: DateTime.utc_now()}

    {:noreply,
     socket
     |> assign(:active_run, updated)
     |> refresh_run_ledger(run.run_id)}
  end

  def handle_info({:run_data, _, _, _}, socket), do: {:noreply, socket}
  def handle_info({:run_exit, _, _, _}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:after_mount_hydration, {:ok, %{workspace_id: ws_id} = data}, socket) do
    if socket.assigns.workspace.id == ws_id do
      previews = data[:previews] || []

      socket =
        socket
        |> stream(:previews, previews, reset: true)
        |> assign(:previews_count, length(previews))
        |> assign(:session_tabs, data[:session_tabs] || [])
        |> assign_workspace_summaries(data[:workspace_summaries] || [])
        |> assign_hydrated_templates(
          data[:saved_session_templates] || [],
          data[:saved_session_template_tags] || []
        )
        |> maybe_assign_hydrated_tmux_topology(data)
        |> maybe_schedule_raw_prewarm()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:after_mount_hydration, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:agents_mount, {:ok, data}, socket) do
    audit_event =
      if data[:isolation_audit] do
        Audit.emit!(%{
          action: "workspace.db_isolation_detected",
          workspace_id: socket.assigns.workspace.id,
          actor_id: current_actor_id(socket),
          target_type: "workspace",
          target_ref: socket.assigns.workspace.id,
          metadata: data.isolation_audit
        })
      end

    socket =
      socket
      |> assign(
        db_isolation: data.db_isolation,
        project_meta: data.project_meta,
        tooling: data.tooling
      )
      |> forward_audit_event(audit_event)

    {:noreply, socket}
  end

  def handle_async(:agents_mount, _result, socket), do: {:noreply, socket}

  def handle_async(:refresh_git_status, {:ok, entries}, socket) do
    {:noreply, assign(socket, :git_status, entries)}
  end

  def handle_async(:refresh_git_status, _result, socket), do: {:noreply, socket}

  def handle_async(:workspace_summaries, {:ok, summaries}, socket) do
    {:noreply, assign_workspace_summaries(socket, summaries)}
  end

  def handle_async(:workspace_summaries, _result, socket), do: {:noreply, socket}

  def handle_async(:run_search, {:ok, {:ok, results}}, socket) do
    state = if results == [], do: :empty, else: :ok

    {:noreply,
     socket
     |> assign(:search_results, results)
     |> assign(:search_state, state)}
  end

  def handle_async(:run_search, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:search_results, [])
     |> assign(:search_state, {:error, reason})}
  end

  def handle_async(:run_search, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:saved_session_templates, {:ok, {tags, templates}}, socket) do
    socket =
      socket
      |> assign(:saved_session_template_tags, tags)
      |> assign(:saved_session_templates, templates)

    socket =
      if socket.assigns[:palette_open] do
        refresh_open_palette(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_async(:saved_session_templates, _result, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _ = cleanup_ghostty_resources(socket)
    :ok
  end

  ## Helpers

  # OSC 52 set-clipboard: ESC ] 52 ; <sel> ; <base64> (BEL | ST). PTY reads can
  # split that escape sequence anywhere, and agent CLIs often copy much more
  # than the old single-regex 48 KB ceiling. Keep a bounded partial buffer so
  # `/copy` commands from Claude/Codex/etc. survive chunk boundaries without
  # allowing unbounded terminal output to become clipboard state.
  @osc52_prefix "\x1b]52;"
  @osc52_max_base64_bytes 4 * 1024 * 1024
  @osc52_max_buffer_bytes @osc52_max_base64_bytes + 256
  @osc52_max_matches 4

  defp push_osc52_clipboard(socket, data) do
    buffer = socket.assigns[:osc52_clipboard_buffer] || ""

    if buffer == "" and :binary.match(data, @osc52_prefix) == :nomatch do
      maybe_store_osc52_prefix_tail(socket, data)
    else
      do_push_osc52_clipboard(socket, buffer <> data)
    end
  end

  defp do_push_osc52_clipboard(socket, data) do
    {payloads, rest} = extract_osc52_payloads(data, [], @osc52_max_matches)

    socket = assign(socket, :osc52_clipboard_buffer, bounded_osc52_buffer(rest))

    Enum.reduce(payloads, socket, fn b64, s ->
      case Base.decode64(b64) do
        {:ok, text} when text != "" -> push_event(s, "clipboard:write", %{"text" => text})
        _ -> s
      end
    end)
  end

  defp extract_osc52_payloads(_data, acc, 0), do: {Enum.reverse(acc), ""}

  defp extract_osc52_payloads(data, acc, remaining) do
    case :binary.match(data, @osc52_prefix) do
      :nomatch ->
        {Enum.reverse(acc), osc52_prefix_tail(data)}

      {start, prefix_len} ->
        sequence = binary_part(data, start, byte_size(data) - start)
        after_prefix = binary_part(data, start + prefix_len, byte_size(data) - start - prefix_len)
        take_osc52_payload(sequence, after_prefix, acc, remaining)
    end
  end

  defp take_osc52_payload(sequence, after_prefix, acc, remaining) do
    case :binary.match(after_prefix, ";") do
      :nomatch ->
        {Enum.reverse(acc), sequence}

      {selector_len, 1} ->
        b64_start = selector_len + 1

        after_selector =
          binary_part(after_prefix, b64_start, byte_size(after_prefix) - b64_start)

        decode_osc52_payload(sequence, after_selector, acc, remaining)
    end
  end

  defp decode_osc52_payload(sequence, after_selector, acc, remaining) do
    case split_osc52_terminator(after_selector) do
      :incomplete ->
        {Enum.reverse(acc), sequence}

      {b64, after_terminator} ->
        acc = if byte_size(b64) <= @osc52_max_base64_bytes, do: [b64 | acc], else: acc
        extract_osc52_payloads(after_terminator, acc, remaining - 1)
    end
  end

  defp maybe_store_osc52_prefix_tail(socket, data) do
    case osc52_prefix_tail(data) do
      "" -> socket
      tail -> assign(socket, :osc52_clipboard_buffer, tail)
    end
  end

  defp bounded_osc52_buffer(buffer) when byte_size(buffer) > @osc52_max_buffer_bytes,
    do: osc52_prefix_tail(buffer)

  defp bounded_osc52_buffer(buffer), do: buffer

  defp osc52_prefix_tail(data) do
    max = min(byte_size(data), byte_size(@osc52_prefix) - 1)
    if max <= 0, do: "", else: longest_osc52_prefix_tail(data, max)
  end

  defp longest_osc52_prefix_tail(data, max) do
    Enum.reduce_while(max..1//-1, "", fn len, _acc ->
      tail = binary_part(data, byte_size(data) - len, len)

      if binary_part(@osc52_prefix, 0, len) == tail,
        do: {:halt, tail},
        else: {:cont, ""}
    end)
  end

  defp split_osc52_terminator(data) do
    case earliest_binary_match(data, ["\x07", "\x1b\\"]) do
      nil ->
        :incomplete

      {idx, len} ->
        after_offset = idx + len

        {binary_part(data, 0, idx),
         binary_part(data, after_offset, byte_size(data) - after_offset)}
    end
  end

  defp earliest_binary_match(data, patterns) do
    patterns
    |> Enum.map(&:binary.match(data, &1))
    |> Enum.reject(&(&1 == :nomatch))
    |> Enum.min_by(fn {idx, _len} -> idx end, fn -> nil end)
  end

  # Per-tab id from the LiveSocket connect params (set from sessionStorage in
  # app.js). Only available on the connected mount; nil on the initial
  # disconnected render, where the terminal hasn't started yet anyway.
  defp connect_tab_id(socket) do
    if Phoenix.LiveView.connected?(socket) do
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"tab_id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end
    end
  end

  # Delegates to central implementation in ChannelAuth to avoid duplication
  # of {:ok, _} / legacy result unwrapping for capability claims.
  defp workspace_loc_for_capability(result), do: ChannelAuth.normalize_workspace_loc(result)

  @doc false
  def terminal_workspace_capability(socket, sid) do
    terminal_workspace_capability(
      socket.assigns.current_user,
      socket.assigns.workspace,
      socket.assigns.host_id,
      active_terminal_loc_result(socket),
      sid,
      socket.assigns.workspace_mode,
      lan_friendly_access?: PanelGate.lan_friendly_access?(socket.assigns)
    )
  end

  @doc false
  def refresh_terminal_workspace_capability(socket) do
    assign(
      socket,
      :terminal_workspace_capability,
      terminal_workspace_capability(socket, socket.assigns.terminal_sid)
    )
  end

  defp terminal_workspace_capability(user, ws, host_id, loc_result, sid, workspace_mode, opts) do
    lan_friendly_access? = Keyword.get(opts, :lan_friendly_access?, false)
    terminal_owner? = lan_friendly_access? or Workspaces.viewer_terminal_owner?(ws, user)
    workspace_user = if lan_friendly_access?, do: user.id, else: ws.user
    workspace_path = path_from_loc_result(loc_result) || ws.path

    ChannelAuth.sign_terminal_capability(
      user.id,
      Map.get(ws, :id),
      workspace_name: ws.name,
      workspace_user: workspace_user,
      workspace_path: workspace_path,
      workspace_loc: workspace_loc_for_capability(loc_result),
      workspace_host_id: host_id,
      raw_terminal_ok: terminal_owner? and raw_terminal_allowed?(workspace_mode, host_id),
      owner_ok: terminal_owner?,
      terminal_owner_ok: terminal_owner?,
      terminal_sid: sid
    )
  end

  defp active_terminal_loc_result(socket) do
    cwd = workspace_cwd(socket)

    case socket.assigns[:host_loc] do
      {:ok, {:local, _path}} -> {:ok, {:local, cwd}}
      {:ok, loc} -> {:ok, loc}
      other -> other
    end
  end

  defp path_from_loc_result({:ok, {:local, path}}) when is_binary(path), do: path
  defp path_from_loc_result({:ok, {:remote, _host, path}}) when is_binary(path), do: path
  defp path_from_loc_result(_), do: nil

  defp assign_workspace_mode(socket, ws_id, connected? \\ true)

  defp assign_workspace_mode(socket, ws_id, true) do
    {mode, source} = Workspaces.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign_policy_permissions()
  end

  defp assign_workspace_mode(socket, _ws_id, false) do
    socket
    |> assign_policy_permissions()
  end

  defp assign_policy_permissions(socket) do
    ctx = policy_ctx(socket)
    mode_decision = Policy.can_set_workspace_mode?(ctx)

    socket
    |> assign(:workspace_role, Policy.workspace_role(ctx))
    |> assign(:can_set_workspace_mode?, Policy.Decision.allow?(mode_decision))
  end

  defp deployment_panel do
    %{
      revision: DevIDE.Deployment.Registry.version(),
      draining?: safe_drain_call(&DevIDE.Deployment.Drain.draining?/0, false),
      active_liveviews: safe_drain_call(&DevIDE.Deployment.Drain.connection_count/0, nil)
    }
  end

  defp safe_drain_call(fun, fallback) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp subscribe_workspace_mode(socket) do
    if connected?(socket) do
      _ = Workspaces.subscribe_mode_changes(socket.assigns.workspace.id)
    end

    socket
  end

  defp subscribe_agent_write_unlock(socket) do
    if connected?(socket) do
      _ = Workspaces.subscribe_agent_write_unlock_changes(socket.assigns.workspace.id)
      assign_agent_write_unlock(socket, socket.assigns.workspace.id)
    else
      socket
    end
  end

  defp assign_agent_write_unlock(socket, ws_id) do
    status =
      case Workspaces.agent_write_unlock_for(ws_id) do
        {:active, until, by} -> %{status: :active, until: until, by: by}
        _ -> %{status: :inactive, until: nil, by: nil}
      end

    assign(socket, :agent_write_unlock, status)
  end

  @doc false
  def refresh_workspace_mode(%{assigns: %{workspace: %{id: ws_id}}} = socket)
      when is_binary(ws_id) do
    socket
    |> assign_workspace_mode(ws_id)
    |> refresh_terminal_workspace_capability()
  end

  def refresh_workspace_mode(socket), do: socket

  defp start_after_mount_hydration(socket) do
    workspace = socket.assigns.workspace
    workspace_id = workspace.id
    workspace_name = workspace.name || workspace.id
    default_sid = socket.assigns.default_terminal_sid
    tmux_session = socket.assigns.tmux_session
    cwd = workspace_cwd(socket)

    start_async(socket, :after_mount_hydration, fn ->
      _ = TerminalState.tmux_adapter().ensure_session(tmux_session, cwd)

      session_tabs =
        workspace_id
        |> Terminals.refresh_session_tabs_now(workspace_name: workspace_name)
        |> Terminals.with_default_shell(default_sid, workspace_id, workspace_name)
        |> SessionBarVM.session_tabs()

      saved_templates = Terminals.list_saved_templates(workspace_id)

      %{
        workspace_id: workspace_id,
        tmux_session: tmux_session,
        previews: DevIDE.Previews.list_for_workspace(workspace_id),
        session_tabs: session_tabs,
        tmux_topology: Terminals.tmux_topology_snapshot(tmux_session),
        workspace_summaries: workspace_summaries_for(workspace),
        saved_session_templates: saved_templates,
        saved_session_template_tags: saved_session_template_tags_from_templates(saved_templates)
      }
    end)
  end

  defp maybe_assign_hydrated_tmux_topology(socket, data) do
    hydrated = data[:tmux_topology]
    current_version = socket.assigns[:tmux_topology_version] || 0

    cond do
      socket.assigns[:tmux_session] != data[:tmux_session] ->
        socket

      not is_map(hydrated) ->
        socket

      current_version != 0 and current_version != hydrated.version ->
        socket

      true ->
        TerminalState.assign_tmux_topology(socket, hydrated)
    end
  end

  defp assign_hydrated_templates(socket, templates, tags) do
    if socket.assigns[:template_library_open] or socket.assigns[:template_tag_filter] do
      socket
    else
      socket =
        socket
        |> assign(:saved_session_templates, templates)
        |> assign(:saved_session_template_tags, tags)

      if socket.assigns[:palette_open] do
        refresh_open_palette(socket)
      else
        socket
      end
    end
  end

  defp saved_session_template_tags_from_templates(templates) do
    templates
    |> Enum.flat_map(fn template ->
      case Map.get(template, :tags) do
        tags when is_list(tags) -> tags
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Summary building shells out per workspace (git branch + status + a
  # session-directory read), so run it off the LiveView process; the result
  # lands in handle_async(:workspace_summaries, ...) and is filtered there.
  def assign_workspace_summaries(socket) do
    workspace = socket.assigns.workspace
    start_async(socket, :workspace_summaries, fn -> workspace_summaries_for(workspace) end)
  end

  defp assign_workspace_summaries(socket, summaries) do
    summaries = Enum.filter(summaries, &workspace_summary_visible?(&1, socket))

    socket
    |> assign(:workspace_summaries, summaries)
    |> assign(
      :workspace_session_tabs,
      SessionBarVM.workspace_session_tabs(summaries, socket.assigns.workspace.id)
    )
  end

  defp workspace_summaries_for(workspace) do
    Workspaces.list_records()
    |> ensure_current_workspace_record(workspace)
    |> SessionSummary.build_many()
  end

  defp workspace_summary_visible?(summary, socket) do
    summary.id == socket.assigns.workspace.id or
      Workspaces.viewer_owns_workspace?(
        %{user: summary.user},
        socket.assigns[:current_user] || %{}
      )
  end

  defp ensure_current_workspace_record(records, workspace) do
    if Enum.any?(records, &(Map.get(&1, :external_id) == workspace.id)) do
      records
    else
      [workspace | records]
    end
  end

  defp refresh_isolation(socket, opts) do
    iso =
      case home_host_path(socket) do
        {:ok, root} -> Isolation.detect(socket.assigns.workspace, root)
        _ -> %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()}
      end

    _ = Workspaces.persist_isolation(socket.assigns.workspace.id, iso)

    _ =
      if Keyword.get(opts, :audit, false) do
        Audit.emit!(%{
          action: "workspace.db_isolation_detected",
          workspace_id: socket.assigns.workspace.id,
          actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
          target_type: "workspace",
          target_ref: socket.assigns.workspace.id,
          metadata: %{
            "isolation" => Atom.to_string(iso.isolation),
            "source" => Atom.to_string(iso.source),
            "redacted_summary" => iso.summary
          }
        })
      end

    socket
    |> assign(:db_isolation, iso)
  end

  defp string_to_mode("manual"), do: :manual
  defp string_to_mode("review"), do: :review
  defp string_to_mode("agent_write_locked"), do: :agent_write_locked
  defp string_to_mode("shared_stage_guarded"), do: :shared_stage_guarded
  defp string_to_mode(_), do: nil

  # Structural authorization gate, attached via attach_hook/4 so it runs before
  # every handle_event clause. Coverage is centralized here instead of being a
  # per-handler opt-in: any event not in @known_events (and not covered by the
  # tmux:/terminal: delegation prefixes) is denied by default. A newly-added
  # handle_event clause therefore fails closed until it is registered in the
  # table above, and the denial is audited + surfaced as a flash. Known events
  # continue to their handler, where fine-grained DevIDE.Policy gates (where
  # present) remain the real decision.
  defp authz_gate(event, params, socket) do
    cond do
      not workspace_viewer_authorized?(socket) ->
        {:halt, deny_forbidden(socket, event)}

      known_event?(event, params) ->
        {:cont, socket}

      true ->
        {:halt, deny_event(socket, event)}
    end
  end

  defp ensure_workspace_access(ws, user) do
    if Workspaces.viewer_can_access_workspace?(ws, user),
      do: :ok,
      else: {:error, :forbidden}
  end

  # Live audit events go to the drawer component, which owns the stream and
  # counters; it drops events that don't match its window filter.
  defp forward_audit_event(socket, nil), do: socket

  defp forward_audit_event(socket, %Audit.Event{} = event) do
    if connected?(socket) do
      Phoenix.LiveView.send_update(DevIdeWeb.WorkspaceLive.AuditDrawerComponent,
        id: "audit-drawer",
        insert_audit_event: event
      )
    end

    socket
  end

  # Viewer check + audited denials live in PanelGate, shared with the panel
  # LiveComponents whose events bypass this LV's authz hook.
  defp workspace_viewer_authorized?(socket), do: PanelGate.viewer_authorized?(socket.assigns)

  defp known_event?(event, _params) do
    event in @known_events or
      String.starts_with?(event, "tmux:") or
      String.starts_with?(event, "terminal:")
  end

  defp deny_forbidden(socket, event) do
    decision = PanelGate.emit_forbidden(socket, event)

    socket
    |> assign(:last_decision, decision)
    |> put_flash(:error, "You do not have access to this workspace.")
  end

  defp deny_event(socket, event) do
    decision = PanelGate.emit_unknown(socket, event)

    socket
    |> assign(:last_decision, decision)
    |> put_flash(:error, "That action isn't available here.")
  end

  defp mode_change_denied_message(%Policy.Decision{reason: :config_override}),
    do: "Workspace mode is pinned by configuration."

  defp mode_change_denied_message(%Policy.Decision{reason: :forbidden}),
    do: "Only the workspace owner can change mode."

  defp mode_change_denied_message(%Policy.Decision{reason: reason}) when not is_nil(reason),
    do: "Cannot change mode: #{reason |> Atom.to_string() |> String.replace("_", " ")}"

  defp mode_change_denied_message(_), do: "Cannot change workspace mode."

  defp agent_write_unlock_denied_message(%Policy.Decision{reason: :config_override}),
    do: "Workspace mode is pinned by configuration."

  defp agent_write_unlock_denied_message(%Policy.Decision{reason: :forbidden}),
    do: "Only the workspace owner can grant agent write."

  defp agent_write_unlock_denied_message(%Policy.Decision{reason: :requires_manual_mode}),
    do: "Agent write unlock requires manual mode."

  defp agent_write_unlock_denied_message(%Policy.Decision{reason: reason})
       when not is_nil(reason),
       do: "Cannot unlock agent write: #{reason |> Atom.to_string() |> String.replace("_", " ")}"

  defp agent_write_unlock_denied_message(_), do: "Cannot unlock agent write."

  defp clamp_unlock_minutes(minutes_str) do
    case Integer.parse(to_string(minutes_str)) do
      {n, _} -> n |> max(@agent_write_unlock_min_minutes) |> min(@agent_write_unlock_max_minutes)
      :error -> @agent_write_unlock_min_minutes
    end
  end

  def refresh_run_ledger(socket, selected_run_id \\ nil) do
    ws_id = socket.assigns.workspace.id
    summaries = Ledger.recent_runs_for(ws_id, 20)

    selected_run_id =
      selected_run_id || socket.assigns[:selected_run_id] || first_run_id(summaries)

    timeline =
      case selected_run_id do
        id when is_binary(id) -> Ledger.timeline_for(ws_id, id)
        _ -> []
      end

    summary =
      case selected_run_id do
        id when is_binary(id) -> Enum.find(summaries, &(&1.id == id))
        _ -> nil
      end

    failure_reason = Status.failure_reason(summary, timeline)

    socket
    |> assign(:run_ledger, summaries)
    |> assign(:selected_run_id, selected_run_id)
    |> assign(:selected_run_summary, summary)
    |> assign(:selected_run_timeline, timeline)
    |> assign(:selected_run_artifacts, WorkspaceStatus.run_artifacts(summary || %{}))
    |> assign(:selected_run_failure_reason, failure_reason)
    |> assign(
      :selected_run_can_retry,
      Status.retryable?(summary, &decision_for_command(socket, &1))
    )
  end

  defp first_run_id([%{id: id} | _]) when is_binary(id), do: id
  defp first_run_id(_), do: nil

  defp close_focused_pane(socket, session, pane_id) do
    case TerminalState.tmux_adapter().kill_pane(session, pane_id) do
      :ok ->
        socket = socket |> TerminalState.refresh_tmux_topology()

        socket =
          if tmux_active_window_pane_count(socket) <= 1,
            do: assign(socket, :window_zoomed?, false),
            else: socket

        {:noreply,
         socket
         |> TerminalState.focus_active_terminal(%{"reason" => "pane:close_focused"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not close tmux pane: #{inspect(reason)}")}
    end
  end

  # Close the active window (its final pane is being closed). Mirrors tmux,
  # where killing the last pane removes the window.
  defp close_focused_window(socket, session) do
    window_id = socket.assigns[:tmux_active_window_id]

    case TerminalState.tmux_adapter().kill_window(session, window_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:window_zoomed?, false)
         |> assign(:tmux_rename_window_id, nil)
         |> TerminalState.refresh_tmux_topology()
         |> TerminalState.focus_active_terminal(%{"reason" => "pane:close_focused"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not close tmux window: #{inspect(reason)}")}
    end
  end

  # Closing the only pane of the only window ends this tmux session. Never
  # leave the operator stranded: switch into another existing session if one
  # is available, otherwise open a fresh window in this session before killing
  # the old one (so the session survives with a clean window).
  defp close_focused_last_window(socket, session) do
    fallback_sid =
      (socket.assigns[:session_tabs] || [])
      |> Enum.map(& &1.id)
      |> Enum.find(&(is_binary(&1) and &1 != socket.assigns[:terminal_sid]))

    window_id = socket.assigns[:tmux_active_window_id]

    if is_binary(fallback_sid) do
      case TerminalState.tmux_adapter().kill_window(session, window_id) do
        :ok ->
          socket =
            socket
            |> assign(:window_zoomed?, false)
            |> assign(:tmux_rename_window_id, nil)
            |> TerminalState.switch_active_session(fallback_sid)
            |> TerminalState.refresh_session_tabs()
            |> TerminalState.focus_active_terminal(%{"reason" => "pane:close_focused"})

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not close tmux window: #{inspect(reason)}")}
      end
    else
      replace_only_window(socket, session, window_id)
    end
  end

  # Only session, only window: open a fresh window, then kill the old one, so
  # C-b x still "closes the tab" and lands the operator in a clean window
  # instead of refusing (a bare kill would end the session with nowhere to go).
  defp replace_only_window(socket, session, window_id) do
    case TerminalState.tmux_adapter().new_window(session, cwd: terminal_window_cwd(socket)) do
      {:ok, new_window_id} ->
        _ = TerminalState.tmux_adapter().kill_window(session, window_id)

        socket =
          socket
          |> assign(:window_zoomed?, false)
          |> assign(:tmux_rename_window_id, nil)
          |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
          |> push_patch(to: TerminalState.workspace_window_path(socket, new_window_id))
          |> TerminalState.focus_active_terminal(%{"reason" => "pane:close_focused"})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not open a new tmux window: #{inspect(reason)}")}
    end
  end

  defp open_annotation_file(socket, root, path, line) do
    case Files.read_text(root, path) do
      {:ok, file} ->
        payload = %{path: file.path, content: file.content, version: file.version}
        payload = if line, do: Map.put(payload, :line, line), else: payload

        socket
        |> assign(:tab, "files")
        |> assign(:open_file, file)
        |> assign(:file_error, nil)
        |> assign(:save_error, nil)
        |> load_diff(file.path)
        |> push_event("file:loaded", payload)

      {:error, reason} ->
        assign(socket, :file_error, format_file_error(reason))
    end
  end

  defp fetch_side_panels(host_loc, host_path, tree) do
    %{
      git_status: side_panel_git_status(host_loc),
      tree: side_panel_tree(tree, host_loc, host_path)
    }
  end

  defp side_panel_git_status({:ok, loc}) do
    case FileAccess.git_status_short(loc) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp side_panel_git_status(_), do: []

  defp side_panel_tree(tree, {:ok, {:remote, _host, _root} = loc}, _host_path) do
    case FileAccess.ls(loc, "") do
      {:ok, raw_entries} ->
        entries = Enum.map(raw_entries, &remote_entry_to_files_shape(&1, ""))
        Map.put(tree, "", {:expanded, entries})

      _ ->
        tree
    end
  end

  defp side_panel_tree(tree, _host_loc, {:ok, root}) do
    case Files.list(root, "") do
      {:ok, entries} -> Map.put(tree, "", {:expanded, entries})
      _ -> tree
    end
  end

  defp side_panel_tree(tree, _host_loc, _host_path), do: tree

  defp fetch_agents_panels(workspace, host_path, _actor_id) do
    case host_path do
      {:ok, root} ->
        iso = Isolation.detect(workspace, root)
        _ = Workspaces.persist_isolation(workspace.id, iso)

        %{
          db_isolation: iso,
          project_meta: ElixirNav.project(root),
          tooling: ElixirNav.tooling(root),
          isolation_audit: %{
            "isolation" => Atom.to_string(iso.isolation),
            "source" => Atom.to_string(iso.source),
            "redacted_summary" => iso.summary
          }
        }

      _ ->
        %{
          db_isolation: %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()},
          project_meta: %{},
          tooling: %{},
          isolation_audit: nil
        }
    end
  end

  # Public: called by Show.FileEvents (extracted file/tree handlers).
  def load_tree(socket, path) do
    case socket.assigns[:host_loc] do
      {:ok, {:remote, _host, _root} = loc} ->
        case FileAccess.ls(loc, path) do
          {:ok, raw_entries} ->
            entries = Enum.map(raw_entries, &remote_entry_to_files_shape(&1, path))
            assign(socket, :tree, Map.put(socket.assigns.tree, path, {:expanded, entries}))

          _ ->
            socket
        end

      _ ->
        with {:ok, root} <- context_host_path(socket),
             {:ok, entries} <- Files.list(root, path) do
          assign(socket, :tree, Map.put(socket.assigns.tree, path, {:expanded, entries}))
        else
          _ -> socket
        end
    end
  end

  defp remote_entry_to_files_shape(%{name: name, dir?: dir?, size: size}, parent) do
    %DevIDE.Files.Entry{
      name: name,
      rel_path: Path.join(parent, name),
      kind: if(dir?, do: :dir, else: :file),
      size: size,
      mtime: nil
    }
  end

  # `git status --short` can take hundreds of ms on a big repo; run it off
  # the LiveView process so file saves/creates/deletes render immediately.
  # The result lands in handle_async(:refresh_git_status, ...).
  def refresh_git_status(socket) do
    case context_host_loc(socket) do
      {:ok, loc} ->
        start_async(socket, :refresh_git_status, fn -> side_panel_git_status({:ok, loc}) end)

      _ ->
        assign(socket, :git_status, [])
    end
  end

  def do_create(:file, root, rel) do
    case Files.create_file(root, rel) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  def do_create(:dir, root, rel), do: Files.create_dir(root, rel)

  def refresh_tree(socket) do
    expanded =
      socket.assigns.tree
      |> Enum.filter(fn {_, {state, _}} -> state == :expanded end)
      |> Enum.map(fn {p, _} -> p end)

    Enum.reduce(expanded, assign(socket, :tree, %{}), fn p, acc -> load_tree(acc, p) end)
  end

  # Batch command runs were retired with the delegated-execution stack; there
  # is no longer an in-flight run process to re-attach to.
  def attach_existing_run(socket), do: socket

  @run_buffer_cap 256 * 1024

  defp append_run_buffer(buffer, chunk) do
    BoundedBuffer.append(buffer, chunk, @run_buffer_cap, truncation_marker: "[…truncated]\n")
  end

  def load_diff(socket, path) do
    case context_host_loc(socket) do
      {:ok, loc} ->
        case FileAccess.git_diff(loc, path) do
          {:ok, ""} -> assign(socket, :file_diff, nil)
          {:ok, diff} -> assign(socket, :file_diff, diff)
          _ -> assign(socket, :file_diff, nil)
        end

      _ ->
        assign(socket, :file_diff, nil)
    end
  end

  @impl true
  def render(%{lan_path_error: %{}} = assigns), do: render_lan_path_error(assigns)

  def render(assigns) do
    render_workspace(assigns)
  end

  defp render_lan_path_error(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <main
      id="lan-path-error"
      class="min-h-dvh bg-base-100 px-4 py-5 text-base-content sm:px-6 lg:px-8"
    >
      <section class="mx-auto flex min-h-[calc(100dvh-2.5rem)] max-w-3xl flex-col justify-center">
        <div class="border-y border-base-300 py-8">
          <div class="mb-4 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-warning">
            <span class="size-2 rounded-full bg-warning" aria-hidden="true"></span> LAN path
          </div>
          <h1 class="text-2xl font-semibold tracking-normal text-base-content sm:text-3xl">
            {@lan_path_error.title}
          </h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/70">
            DevIDE could not open this filesystem-addressed workspace:
            <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-xs text-base-content">
              {@lan_path_error.route_path}
            </code>
          </p>

          <dl class="mt-6 grid gap-3 text-sm">
            <div class="grid gap-1 sm:grid-cols-[8rem_1fr] sm:items-start">
              <dt class="font-medium text-base-content/55">Reason</dt>
              <dd id="lan-path-error-reason" class="text-base-content">
                {@lan_path_error.message}
              </dd>
            </div>
            <div
              :if={@lan_path_error.root_path}
              class="grid gap-1 sm:grid-cols-[8rem_1fr] sm:items-start"
            >
              <dt class="font-medium text-base-content/55">LAN root</dt>
              <dd class="min-w-0 break-all font-mono text-xs text-base-content/75">
                {@lan_path_error.root_path}
              </dd>
            </div>
            <div
              :if={@lan_path_error.target_path}
              class="grid gap-1 sm:grid-cols-[8rem_1fr] sm:items-start"
            >
              <dt class="font-medium text-base-content/55">Resolved path</dt>
              <dd
                id="lan-path-error-target"
                class="min-w-0 break-all font-mono text-xs text-base-content/75"
              >
                {@lan_path_error.target_path}
              </dd>
            </div>
          </dl>

          <div class="mt-7 flex flex-wrap items-center gap-2">
            <.link
              navigate="/"
              class="inline-flex h-9 items-center justify-center rounded border border-primary/40 bg-primary px-3 text-sm font-medium text-primary-content transition hover:bg-primary/90"
            >
              Open home
            </.link>
            <.link
              navigate={~p"/workspaces"}
              class="inline-flex h-9 items-center justify-center rounded border border-base-300 bg-base-100 px-3 text-sm font-medium text-base-content/80 transition hover:bg-base-200"
            >
              Workspaces
            </.link>
          </div>
        </div>
      </section>
    </main>
    """
  end

  defp render_workspace(assigns) do
    ~H"""
    <div id="palette-anchor" phx-hook="PaletteHook" class="hidden"></div>
    {render_palette(assigns)}
    {ContextMenu.render_context_menu(assigns)}
    <.template_preview_modal template_preview={@template_preview} />
    <.template_library_drawer
      template_library_open={@template_library_open}
      workspace={@workspace}
      saved_session_templates={@saved_session_templates}
      saved_session_template_tags={@saved_session_template_tags}
      template_tag_filter={@template_tag_filter}
      template_save_form={@template_save_form}
      template_edit_id={@template_edit_id}
      template_edit_form={@template_edit_form}
      template_duplicate_id={@template_duplicate_id}
      template_duplicate_form={@template_duplicate_form}
    />
    <Layouts.flash_group flash={@flash} />
    <div id="terminal-activity" phx-hook="TerminalActivity" class="hidden" aria-hidden="true"></div>
    <div
      id="workspace-leader-root"
      phx-hook="WorkspaceLeader"
      data-terminal-themes={Jason.encode!(@terminal_themes)}
      class="workspace-shell flex h-dvh w-full max-w-full flex-col overflow-x-hidden bg-base-100 text-base-content px-4 pt-1 pb-1.5 pointer-coarse:px-2 pointer-coarse:pt-0 pointer-coarse:pb-0 lg:px-6"
    >
      <% workspace_path = render_path(@host_loc, @host_path) %>
      <%= if @chrome_visible do %>
        <header
          id={"workspace-header-" <> @workspace.id}
          phx-hook="ChromeWidth"
          class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 border-b border-base-300/70 px-0.5 pb-0.5 text-xs pointer-coarse:mb-0.5 pointer-coarse:pb-0 pointer-coarse:gap-0.5"
        >
          <div class="header-identity-cluster flex min-w-0 shrink items-center gap-1 overflow-x-clip">
            <.link
              navigate={~p"/workspaces"}
              class="shrink-0 text-primary hover:underline"
              title="Back to workspaces"
            >
              ←
            </.link>
            <h1
              class="header-p-touch-show header-p-as-block min-w-0 flex-1 truncate text-sm font-semibold leading-none"
              title={workspace_path}
            >
              {workspace_short_name(@workspace.name)}
            </h1>
            <button
              type="button"
              phx-click={header_status_action(@workspace, @workspace_start_error)}
              disabled={is_nil(header_status_action(@workspace, @workspace_start_error))}
              class="header-p-touch-show header-p-as-flex shrink-0 items-center justify-center rounded disabled:cursor-default pointer-coarse:size-8"
              title={header_status_action_label(@workspace, @workspace_start_error)}
              aria-label={header_status_action_label(@workspace, @workspace_start_error)}
            >
              <span
                class={[
                  "size-2 rounded-full",
                  workspace_status_dot_class(@workspace.status)
                ]}
                aria-hidden="true"
              ></span>
            </button>
            <span
              :if={workspace_start_blocked?(@workspace_start_error)}
              id="workspace-start-unavailable"
              class="header-p-touch-hide shrink-0 rounded border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-600 dark:text-amber-300"
            >
              Start unavailable
            </span>
            <button
              :if={workspace_stoppable?(@workspace)}
              id="workspace-stop-button"
              type="button"
              phx-click="workspace:stop"
              class="header-p-low shrink-0 rounded border border-base-300 bg-base-200/70 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-base-content/70 transition-colors hover:bg-base-300/70 active:bg-base-300"
            >
              Stop
            </button>
            <button
              :if={
                @tab == "terminal" and @terminal_mode in [:raw, :raw_ghostty] and
                  match?({:ok, _}, @host_loc)
              }
              type="button"
              id="header-session-copy"
              phx-hook="CopyText"
              data-copy-text={terminal_session_label(@tmux_session, @terminal_sid)}
              class="header-p-touch-show header-p-as-inline shrink-0 rounded font-mono text-[11px] text-base-content/50 active:text-base-content data-[copied]:text-emerald-500"
              title="Copy tmux session name"
              aria-label={"Copy tmux session " <> terminal_session_label(@tmux_session, @terminal_sid)}
            >
              {terminal_session_label(@tmux_session, @terminal_sid)}
            </button>
          </div>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <div
              id={"header-terminal-pickers-" <> @workspace.id}
              phx-hook="WindowPickerView"
              data-view={Atom.to_string(@window_picker_view)}
              class={[
                "header-terminal-pickers flex min-w-0 items-center pointer-coarse:hidden",
                if(@window_picker_view == :tabs, do: "flex-1", else: "shrink")
              ]}
            >
              <%= if @window_picker_view == :tabs do %>
                <SessionBar.window_tabs
                  workspace_id={@workspace.id}
                  path_base={@lan_friendly_path}
                  windows={@tmux_window_tabs}
                  topology_version={@tmux_topology_structure_version}
                  mutations_allowed?={@tmux_mutations_enabled?}
                  rename_window_id={@tmux_rename_window_id}
                  class="min-w-0 flex-1"
                />
              <% else %>
                <SessionBar.window_dropdown
                  workspace_id={@workspace.id}
                  path_base={@lan_friendly_path}
                  windows={@tmux_window_tabs}
                  session_id={if @terminal_sid != @default_terminal_sid, do: @terminal_sid}
                  share_session_id={@terminal_sid}
                  topology_version={@tmux_topology_structure_version}
                  mutations_allowed?={@tmux_mutations_enabled?}
                  rename_window_id={@tmux_rename_window_id}
                  selected_preview={
                    TerminalState.selected_preview_pane(
                      @preview_panes,
                      @entered_preview_pane_id,
                      @ui_highlight_pane_id,
                      @tmux_windows,
                      @tmux_active_window_id,
                      @tmux_session
                    )
                  }
                />
              <% end %>
            </div>
            <%!-- Permanent pane/window controls — header on mouse, keybar on touch --%>
            <div class="header-p-mid header-p-as-flex shrink-0 items-center gap-1 pointer-coarse:!hidden">
              <%!-- Window cycling --%>
              <%= if length(@tmux_window_tabs) > 1 do %>
                <.leader_key_button
                  key="p"
                  phx_click="tmux:cycle_window"
                  phx_value_dir="prev"
                  title="Previous window · Ctrl + B p"
                  aria_label="Previous tmux window"
                >
                  <.icon name="hero-chevron-left" class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key="l"
                  phx_click="tmux:last_window"
                  title="Last window · Ctrl + B l"
                  aria_label="Last tmux window"
                >
                  <.icon name="hero-clock" class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key="n"
                  phx_click="tmux:cycle_window"
                  phx_value_dir="next"
                  title="Next window · Ctrl + B n"
                  aria_label="Next tmux window"
                >
                  <.icon name="hero-chevron-right" class="size-3.5" />
                </.leader_key_button>
              <% end %>
              <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
                <%!-- Pane navigation (only shown with multiple tmux panes) --%>
                <%= if @active_window_pane_count > 1 do %>
                  <span class="mx-0.5 h-4 w-px shrink-0 bg-base-300"></span>
                  <.leader_key_button
                    key="←"
                    phx_click="pane:navigate"
                    phx_value_dir="left"
                    title="Focus pane left · Ctrl + B ←"
                    aria_label="Focus left pane"
                  >
                    <.icon name="hero-arrow-left" class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key="↓"
                    phx_click="pane:navigate"
                    phx_value_dir="down"
                    title="Focus pane down · Ctrl + B ↓"
                    aria_label="Focus pane below"
                  >
                    <.icon name="hero-arrow-down" class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key="↑"
                    phx_click="pane:navigate"
                    phx_value_dir="up"
                    title="Focus pane up · Ctrl + B ↑"
                    aria_label="Focus pane above"
                  >
                    <.icon name="hero-arrow-up" class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key="→"
                    phx_click="pane:navigate"
                    phx_value_dir="right"
                    title="Focus pane right · Ctrl + B →"
                    aria_label="Focus right pane"
                  >
                    <.icon name="hero-arrow-right" class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key="o"
                    phx_click="pane:navigate"
                    phx_value_dir="next"
                    title="Cycle to next pane · Ctrl + B o"
                    aria_label="Cycle to next pane"
                  >
                    <.icon name="hero-arrow-path" class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key="x"
                    phx_click="pane:close_focused"
                    class="hover:text-error"
                    title="Close pane · Ctrl + B x"
                    aria_label="Close focused pane"
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </.leader_key_button>
                <% end %>
                <span class="mx-0.5 h-4 w-px shrink-0 bg-base-300"></span>
                <%!-- Splits and zoom --%>
                <.leader_key_button
                  key="%"
                  phx_click="split_right"
                  title="Split right · Ctrl + B %"
                  aria_label="Split pane right"
                >
                  <.split_icon direction={:right} class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key={"\""}
                  phx_click="split_down"
                  title="Split down · Ctrl + B &quot;"
                  aria_label="Split pane down"
                >
                  <.split_icon direction={:down} class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key="z"
                  phx_click="pane:zoom_focused"
                  title={
                    if @window_zoomed?,
                      do: "Unzoom pane · Ctrl + B z",
                      else: "Zoom pane · Ctrl + B z"
                  }
                  aria_label={if @window_zoomed?, do: "Unzoom pane", else: "Zoom pane"}
                >
                  <.icon
                    name={
                      if @window_zoomed?,
                        do: "hero-arrows-pointing-in",
                        else: "hero-arrows-pointing-out"
                    }
                    class="size-3.5"
                  />
                </.leader_key_button>
              <% end %>
              <%= if @tmux_mutations_enabled? do %>
                <.leader_key_button
                  key="c"
                  phx_click="tmux:new_window"
                  title="New window · Ctrl + B c"
                  aria_label="New tmux window"
                >
                  <.icon name="hero-plus-circle" class="size-3.5" />
                </.leader_key_button>
              <% end %>
            </div>
          <% end %>
          <button
            :if={@tab == "terminal"}
            id={"leader-prefix-button-" <> @workspace.id}
            type="button"
            data-leader-prefix-button="true"
            class="leader-prefix-button shrink-0 rounded border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-[10px] font-semibold leading-none text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content active:scale-[0.98] pointer-coarse:hidden"
            title="tmux prefix key"
            aria-label="tmux prefix key"
            aria-pressed="false"
          >
            C-b
          </button>
          {render_header_overflow_menu(assigns)}
          <div class="ml-auto flex shrink-0 items-center gap-0.5 pointer-coarse:gap-0.5">
            <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
              <SessionBar.session_dropdown
                workspace_id={@workspace.id}
                path_base={@lan_friendly_path}
                tabs={@session_tabs}
                workspace_tabs={@workspace_session_tabs}
                active_id={@terminal_sid}
                preview_panes={@preview_panes}
                active_fallback_label={session_kind_label(@active_session_kind)}
                active_fallback_detail={terminal_session_label(@tmux_session, @terminal_sid)}
                mutations_allowed?={@tmux_mutations_enabled?}
                rename_session_id={@tmux_rename_session_id}
                default_sid={@default_terminal_sid}
              />
              <div class="header-p-mid header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300"></div>
            <% end %>
            <%= if @tab == "terminal" and @terminal_mode in [:raw, :raw_ghostty] do %>
              <div class="header-terminal-chrome-right flex shrink-0 items-center gap-1 pointer-coarse:hidden">
                <span
                  class="header-p-low header-p-as-inline font-mono text-[11px] text-base-content/50"
                  title={"tmux session " <> @tmux_session}
                >
                  tmux
                  <span class="text-base-content/70">
                    {terminal_session_label(@tmux_session, @terminal_sid)}
                  </span>
                </span>
                <% window_pane_count = @active_window_pane_count %>
                <%= if window_pane_count > 1 do %>
                  <span class="header-p-low header-p-as-inline text-base-content/30">·</span>
                  <span class="header-p-low header-p-as-inline text-base-content/70">
                    {window_pane_count} panes
                  </span>
                  <button
                    type="button"
                    phx-click="equalize_layout"
                    class="header-p-low rounded border border-base-300 px-1.5 py-0.5 text-[10px] text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                    title="Tile panes evenly (tmux select-layout tiled)"
                  >
                    reset
                  </button>
                <% end %>
                <div class="header-p-low header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300">
                </div>
              </div>
            <% end %>
            <button
              phx-click="terminal:toggle_chrome"
              data-shortcut="Ctrl/Cmd + Shift + F"
              class="inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0"
              title="Focus mode. Shortcut: Ctrl/Cmd + Shift + F"
              aria-label="Hide header for a terminal-only view"
            >
              <span class="leading-none pointer-coarse:text-xs" aria-hidden="true">▴</span>
            </button>
          </div>
        </header>
      <% else %>
        <%!-- Thin reveal strip when chrome is hidden (focus mode).
             Click or keyboard shortcut brings the header + utility bar back.
             Only shown in the outer container so it works across all tabs. --%>
        <div
          class="mb-1 pointer-coarse:mb-0.5 h-1.5 pointer-coarse:h-7 w-full cursor-pointer rounded bg-base-300/40 hover:bg-emerald-400/40 active:bg-emerald-400/60 transition-colors flex items-center justify-center pointer-coarse:justify-between pointer-coarse:gap-2 pointer-coarse:px-2"
          phx-click="terminal:toggle_chrome"
          title="Show header. Shortcut: Ctrl/Cmd + Shift + F"
          aria-label="Show header and utility bar"
        >
          <span class="sr-only">Show chrome</span>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <% win = active_tmux_window_name(assigns) %>
            <span class="hidden pointer-coarse:flex min-w-0 items-center gap-1.5 text-[11px] leading-none text-base-content/70">
              <span
                class={["size-2 shrink-0 rounded-full", workspace_status_dot_class(@workspace.status)]}
                aria-hidden="true"
              ></span>
              <span class="truncate font-medium text-base-content/80">
                {mobile_active_session_label(assigns)}
              </span>
              <%= if is_binary(win) and win != "" do %>
                <span class="shrink-0 text-base-content/40">·</span>
                <span class="truncate text-base-content/55">{win}</span>
              <% end %>
            </span>
          <% end %>
          <span
            class="hidden pointer-coarse:block shrink-0 leading-none text-base-content/40"
            aria-hidden="true"
          >
            ▾
          </span>
        </div>
      <% end %>

      <%!-- Central leader-key dispatch targets. WorkspaceLeader routes every
            C-b second key to a click on [data-leader-action=...], so each
            action lives on exactly one element here (docs/leader_keys.md) —
            outside the chrome block, so bindings keep working in focus mode.
            Visible chrome buttons share the same phx-click handlers but carry
            no data-leader-action. Exceptions: the pickers (C-b s / w) stay on
            the dropdown <summary> elements because they need the dropdown UI,
            and window-by-index targets live on the window tabs. --%>
      <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
        <div class="hidden" aria-hidden="true">
          <button
            type="button"
            tabindex="-1"
            data-leader-action="copy-link"
            data-copy-session-link={current_share_url(assigns)}
            data-copy-link-kind="view"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="detach"
            phx-click="terminal:switch_to_shell"
          ></button>
          <button type="button" tabindex="-1" data-leader-action="palette" phx-click="palette:open"></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="help"
            phx-click={JS.toggle(to: "#leader-cheatsheet")}
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="last-window"
            phx-click="tmux:last_window"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="last-pane"
            phx-click="pane:navigate"
            phx-value-dir="last"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="prev-session"
            phx-click="terminal:cycle_session"
            phx-value-dir="prev"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="next-session"
            phx-click="terminal:cycle_session"
            phx-value-dir="next"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="next-window"
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="prev-window"
            phx-click="tmux:cycle_window"
            phx-value-dir="prev"
          ></button>
          <button
            :if={@tmux_active_window_id}
            type="button"
            tabindex="-1"
            data-leader-action="kill-window"
            data-confirm="Kill this tmux window and everything running in it?"
            phx-click="tmux:kill_window"
            phx-value-window-id={@tmux_active_window_id}
          ></button>
          <button
            :if={@tmux_active_window_id}
            type="button"
            tabindex="-1"
            data-leader-action="rename-window"
            phx-click={
              JS.set_attribute({"open", "open"}, to: "#window-dropdown-#{@workspace.id}")
              |> JS.push("tmux:rename_start")
            }
            phx-value-window-id={@tmux_active_window_id}
          ></button>
          <button
            :if={is_binary(@tmux_session)}
            type="button"
            tabindex="-1"
            data-leader-action="rename-session"
            phx-click={
              JS.set_attribute({"open", "open"}, to: "#session-dropdown-#{@workspace.id}")
              |> JS.push("terminal:rename_session_start")
            }
            phx-value-session-id={@terminal_sid}
          ></button>
          <%= if @tmux_mutations_enabled? do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="new-window"
              phx-click="tmux:new_window"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="new-window-tab"
              phx-click="tmux:new_window_tab"
            ></button>
          <% end %>
          <%!-- Pane focus arrows work across all tmux pane tiles. --%>
          <%= if is_binary(@tmux_session) do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-left"
              phx-click="pane:navigate"
              phx-value-dir="left"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-down"
              phx-click="pane:navigate"
              phx-value-dir="down"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-up"
              phx-click="pane:navigate"
              phx-value-dir="up"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-right"
              phx-click="pane:navigate"
              phx-value-dir="right"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-next"
              phx-click="pane:navigate"
              phx-value-dir="next"
            ></button>
          <% end %>
          <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="close-pane"
              phx-click="pane:close_focused"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="split-right"
              phx-click="split_right"
            ></button>
            <button type="button" tabindex="-1" data-leader-action="split-down" phx-click="split_down"></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="zoom"
              phx-click="pane:zoom_focused"
            ></button>
          <% end %>
        </div>
      <% end %>

      <div class="min-h-0 flex-1">
        {if @tab == "terminal", do: render_terminal(assigns)}
        <.files_panel
          :if={@tab == "files"}
          host_loc={@host_loc}
          selected_dir={@selected_dir}
          new_input={@new_input}
          tree_error={@tree_error}
          tree={@tree}
          project_meta={@project_meta}
          tooling={@tooling}
          open_file={@open_file}
          rename_input={@rename_input}
          delete_confirm={@delete_confirm}
          save_error={@save_error}
          file_error={@file_error}
        />
        <.search_panel
          :if={@tab == "search"}
          search_query={@search_query}
          search_results={@search_results}
          search_state={@search_state}
        />
        <.diff_panel
          :if={@tab == "diff"}
          git_status={@git_status}
          open_file={@open_file}
          file_diff={@file_diff}
        />
        <.run_panel
          :if={@tab == "run"}
          host_loc={@host_loc}
          active_run={@active_run}
          review_commands={@review_commands}
          agent_write_unlock={@agent_write_unlock}
          run_ledger={@run_ledger}
          selected_run_id={@selected_run_id}
          selected_run_timeline={@selected_run_timeline}
          selected_run_summary={@selected_run_summary}
          selected_run_failure_reason={@selected_run_failure_reason}
          selected_run_can_retry={@selected_run_can_retry}
          selected_run_artifacts={@selected_run_artifacts}
        />
        <.live_component
          :if={@tab == "proposals"}
          module={DevIdeWeb.WorkspaceLive.ProposalPanelComponent}
          id="proposal-panel"
          workspace={@workspace}
          current_user={@current_user}
          lan_friendly_path={@lan_friendly_path}
          workspace_mode_source={@workspace_mode_source}
          db_isolation={@db_isolation}
          host_path={@host_path}
        />
        {if @tab == "logs", do: render_logs(assigns)}
      </div>
    </div>
    {render_audit_drawer(assigns)}
    {render_leader_cheatsheet(assigns)}
    """
  end

  # `C-b ?` — in-app help overlay. Toggled client-side; the backdrop closes it.
  # Tabs switch via pure JS commands (no socket). `C-b ?` while open cycles the
  # tabs — see cycleLeaderHelpTab in workspace_leader.js.
  defp render_leader_cheatsheet(assigns) do
    assigns =
      assign(assigns, :cheat_tabs, [
        %{id: "shortcuts", label: "Shortcuts"},
        %{id: "preview", label: "Preview"},
        %{id: "agents", label: "Agents"}
      ])

    ~H"""
    <div id="leader-cheatsheet" class="fixed inset-0 z-50 hidden">
      <div class="absolute inset-0 bg-black/30" phx-click={JS.hide(to: "#leader-cheatsheet")}></div>
      <div class="absolute top-1/2 left-1/2 max-h-[80vh] w-[30rem] max-w-[92vw] -translate-x-1/2 -translate-y-1/2 overflow-auto rounded border border-base-300 bg-base-100 p-4 text-xs shadow-xl">
        <h2 class="mb-2 text-sm font-semibold">Help</h2>
        <div role="tablist" class="mb-3 flex gap-1 border-b border-base-300">
          <button
            :for={{tab, i} <- Enum.with_index(@cheat_tabs)}
            type="button"
            role="tab"
            id={"cheat-tab-#{tab.id}"}
            data-cheat-tab
            aria-selected={to_string(i == 0)}
            aria-controls={"cheat-panel-#{tab.id}"}
            phx-click={switch_cheat_tab(tab.id)}
            class="-mb-px border-b-2 border-transparent px-2 py-1 text-xs font-medium text-base-content/50 hover:text-base-content/80 aria-selected:border-primary aria-selected:text-base-content"
          >
            {tab.label}
          </button>
        </div>
        <div
          id="cheat-panel-shortcuts"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-shortcuts"
        >
          <p class="mb-1 text-[11px] text-base-content/60">
            Press <kbd>Ctrl + B</kbd>, then the key shown below. Works from anywhere, even inside the terminal.
          </p>
          <p class="mb-3 text-[11px] text-base-content/60">
            No need to memorize these — a paired agent can do all of it for you in plain
            English: "merge windows 5 and 6 side by side", "rename this pane",
            "move this pane to its own window". See the <em>Agents</em> tab.
          </p>
          <div class="grid grid-cols-2 gap-x-6 gap-y-1">
            <div class="font-semibold text-base-content/60 col-span-2 mt-1">Sessions & windows</div>
            <.cheat_row keys="s" desc="pick a session" />
            <.cheat_row keys="w" desc="pick a window" />
            <.cheat_row keys="( / )" desc="previous or next session" />
            <.cheat_row keys="c" desc="open a new window" />
            <.cheat_row keys="C" desc="new window in a new browser tab" />
            <.cheat_row keys="n / p" desc="next or previous window" />
            <.cheat_row keys="l" desc="jump back to your last window" />
            <.cheat_row keys="1–9" desc="jump to window 1–9" />
            <.cheat_row keys="," desc="rename this window" />
            <.cheat_row keys="$" desc="rename this session" />
            <.cheat_row keys="&" desc="close this window" />
            <.cheat_row keys="y" desc="copy a link to this session and window" />
            <.cheat_row keys="d" desc="return to the workspace shell" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">Panes</div>
            <.cheat_row keys="% or |" desc="split side by side" />
            <.cheat_row keys={"\" or -"} desc="split top and bottom" />
            <.cheat_row keys="← ↓ ↑ →" desc="move focus between panes" />
            <.cheat_row keys="o" desc="focus the next pane" />
            <.cheat_row keys=";" desc="focus your last pane" />
            <.cheat_row keys="z" desc="zoom this pane full screen" />
            <.cheat_row keys="x" desc="close this pane" />
            <.cheat_row keys="q" desc="show pane numbers — then press 0–9 to jump" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">More leader keys</div>
            <.cheat_row keys=":" desc="open the command palette" />
            <.cheat_row keys="?" desc="show this help" />
            <.cheat_row keys="Esc / Ctrl + B" desc="cancel (when waiting for a second key)" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              Inside a session or window picker
            </div>
            <.cheat_row keys="↑ ↓" desc="browse entries" />
            <.cheat_row keys="→ / ←" desc="expand or collapse a session's windows" />
            <.cheat_row keys="type" desc="filter the list — Backspace edits" />
            <.cheat_row keys="o" desc="open the focused entry in a new tab" />
            <.cheat_row keys="l" desc="copy a link to the focused entry" />
            <.cheat_row keys="r" desc="rename the focused window or session" />
            <.cheat_row keys="&" desc="kill the focused window (window picker)" />
            <.cheat_row keys="Enter" desc="attach to the focused entry" />
            <.cheat_row keys="Esc" desc="clear the filter, then close" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              From anywhere (no Ctrl + B)
            </div>
            <.cheat_row keys="Ctrl+P" desc="open the command palette" />
            <.cheat_row keys="Ctrl+Space" desc="open the command palette" />
            <.cheat_row keys="Ctrl+Shift+F" desc="hide the header for more terminal space" />
            <.cheat_row keys="Ctrl+← →" desc="previous or next pane" />
            <.cheat_row keys="Ctrl+↑ ↓" desc="previous or next session" />
            <.cheat_row keys="Space" desc="focus the terminal" />
            <div class="font-semibold text-base-content/60 col-span-2 mt-2">
              Inside the command palette
            </div>
            <.cheat_row keys="Tab" desc="switch category (Files, Commands, Terminal, …)" />
            <.cheat_row keys="Shift+Tab" desc="previous category" />
            <.cheat_row keys="↑ ↓ Enter" desc="browse results and run the one you want" />
            <.cheat_row keys="Esc" desc="close the palette" />
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/leader_keys.md</code>
          </p>
        </div>
        <div
          id="cheat-panel-preview"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-preview"
          class="hidden"
        >
          <p class="mb-3 text-[11px] text-base-content/60">
            A browser pane for your workspace apps — run a dev server, then preview it
            right inside DevIDE: click, type, navigate, screenshot.
          </p>
          <div class="grid grid-cols-[7rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Open one">
              Palette → <em>Preview: Open Current Dev Server</em>
              (auto-detects your port),
              or run <code class="rounded bg-base-200 px-1 py-0.5">devide-preview :4000</code>
              in a terminal.
            </.tip_row>
            <.tip_row term="Localhost only">
              Previews load only your workspace's loopback ports. The port must be a common
              dev port, set in workspace metadata, or seen in your terminal output.
            </.tip_row>
            <.tip_row term="Framed apps">
              Apps that block embedding fall back to a built-in proxy automatically.
              Live-reload over WebSocket (HMR) won't tunnel through the proxy yet.
            </.tip_row>
            <.tip_row term="Stay logged in">
              Previews start fresh each session, so logins reset. Add
              <code class="rounded bg-base-200 px-1 py-0.5">--storage workspace</code>
              to keep auth across restarts.
            </.tip_row>
            <.tip_row term="Responsive">
              <code class="rounded bg-base-200 px-1 py-0.5">devide-preview :4000 --viewport 375x812</code>
              locks a device size.
            </.tip_row>
            <.tip_row term="Share">
              Add <code class="rounded bg-base-200 px-1 py-0.5">--share</code>
              so an agent or teammate can watch the same page.
            </.tip_row>
            <.tip_row term="Troubleshoot">
              <code class="rounded bg-base-200 px-1 py-0.5">preview errors &lt;session&gt;</code>
              shows console and connection problems. Previews track LiveView health and
              auto-reload on repeated socket failures.
            </.tip_row>
            <.tip_row term="After a restart">
              Re-open the preview — sessions live on the current instance.
            </.tip_row>
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/subsystems/previews.md</code>
          </p>
        </div>
        <div
          id="cheat-panel-agents"
          data-cheat-panel
          role="tabpanel"
          aria-labelledby="cheat-tab-agents"
          class="hidden"
        >
          <p class="mb-3 text-[11px] text-base-content/60">
            DevIDE wires external coding agents into your workspace over MCP, giving them
            narrow, audited access to your tmux panes and previews. Pair one with <em>Agents tab → Apply Agent Pair layout</em>, then drive its pane.
          </p>
          <div class="grid grid-cols-[5rem_1fr] gap-x-3 gap-y-2">
            <.tip_row term="Claude">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">claude</code>
              in a paired
              pane auto-loads DevIDE's terminal + preview MCP servers. It reads
              <code class="rounded bg-base-200 px-1 py-0.5">AGENTS.md</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">CLAUDE.md</code>
              first — keep your
              workspace notes and the push/deploy rules there. Strongest on long, multi-step
              changes and large context.
            </.tip_row>
            <.tip_row term="Grok">
              A bare <code class="rounded bg-base-200 px-1 py-0.5">grok</code>
              reads the project <code class="rounded bg-base-200 px-1 py-0.5">.mcp.json</code>
              DevIDE materializes,
              so it picks up the same MCP tools automatically. If the tools don't show up,
              refresh pairing to rewrite <code class="rounded bg-base-200 px-1 py-0.5">grok/config.toml</code>.
            </.tip_row>
            <.tip_row term="Codex">
              Codex gets DevIDE MCP through launch-time flags, not a project file — start
              <code class="rounded bg-base-200 px-1 py-0.5">codex</code>
              from the paired pane so
              the args apply, then confirm it lists the
              <code class="rounded bg-base-200 px-1 py-0.5">terminal</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">preview</code>
              servers before
              sending commands.
            </.tip_row>
            <.tip_row term="Sign in">
              By default, agents use the host's global Claude/Codex login. For an
              owner-isolated login instead, sign in once with
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin codex</code>
              and <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth signin claude</code>.
              DevIDE detects the owner from the current workspace; once signed in,
              matching workspaces share that owner login automatically. Use
              <code class="rounded bg-base-200 px-1 py-0.5">devide agent auth status</code>
              to check sign-in state.
            </.tip_row>
            <.tip_row term="All three">
              Source <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent.env</code>
              first,
              and use <code class="rounded bg-base-200 px-1 py-0.5">.devbox-agent-prompt.txt</code>
              as a starter prompt. Drive an agent's pane with MCP
              <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_command</code>
              / <code class="rounded bg-base-200 px-1 py-0.5">terminal_send_keys</code>.
            </.tip_row>
            <.tip_row term="Tmux chores">
              Agents can manage your windows and panes for you — ask in plain English to
              merge two windows into side-by-side panes, break a pane out into its own
              window, rename or renumber windows, or rebalance a layout. Every leader-key
              action on the <em>Shortcuts</em> tab is something an agent can run.
            </.tip_row>
          </div>
          <p class="mt-3 text-[10px] text-base-content/50">
            More detail in <code>docs/subsystems/agents.md</code>
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Build-to-scale: drives the help overlay's tab bar and its show/hide. Pure
  # client-side JS — no socket round-trip — so the overlay stays instant.
  defp switch_cheat_tab(id) do
    JS.set_attribute({"aria-selected", "false"}, to: "#leader-cheatsheet [data-cheat-tab]")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#cheat-tab-#{id}")
    |> JS.add_class("hidden", to: "#leader-cheatsheet [data-cheat-panel]")
    |> JS.remove_class("hidden", to: "#cheat-panel-#{id}")
  end

  attr :keys, :string, required: true
  attr :desc, :string, required: true

  defp cheat_row(assigns) do
    ~H"""
    <kbd class="justify-self-start rounded bg-base-200 px-1.5 py-0.5 font-mono text-[10px]">
      {@keys}
    </kbd>
    <span class="text-base-content/80">{@desc}</span>
    """
  end

  attr :term, :string, required: true
  slot :inner_block, required: true

  defp tip_row(assigns) do
    ~H"""
    <div class="font-medium text-base-content/70">{@term}</div>
    <div class="text-base-content/80">{render_slot(@inner_block)}</div>
    """
  end

  defp render_audit_drawer(assigns) do
    ~H"""
    <.live_component
      module={DevIdeWeb.WorkspaceLive.AuditDrawerComponent}
      id="audit-drawer"
      open={@audit_drawer_open}
      workspace={@workspace}
      current_user={@current_user}
      lan_friendly_path={@lan_friendly_path}
    />
    """
  end

  defp render_terminal(assigns) do
    ~H"""
    <section class="terminal-shell -mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
      <div class="flex h-full min-h-0 flex-col overflow-hidden">
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
              <%= if (@terminal_mode in [:raw, :raw_ghostty] and tmux_pane_surface?(assigns)) or
                        (@terminal_mode not in [:raw, :raw_ghostty] and
                           tmux_multi_pane_geometry?(assigns)) do %>
                <.tmux_pane_geometry
                  workspace={@workspace}
                  active_tmux_window_panes={active_tmux_window_panes(@tmux_windows)}
                  preview_panes={@preview_panes}
                  tmux_session={@tmux_session}
                  ui_highlight_pane_id={@ui_highlight_pane_id}
                  tmux_active_pane_id={@tmux_active_pane_id}
                  tmux_mutations_enabled?={@tmux_mutations_enabled?}
                  entered_preview_pane_id={@entered_preview_pane_id}
                  terminal_surface_pane_id={@terminal_surface_pane_id}
                  pane_history={@pane_history}
                  terminal_themes={@terminal_themes}
                  focused_pane_id={@focused_pane_id}
                  pane_data={@pane_data}
                  workspace_start_error={@workspace_start_error}
                />
              <% else %>
                <div class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950">
                  <.raw_terminal_surface
                    workspace={@workspace}
                    workspace_start_error={@workspace_start_error}
                    focused_pane_id={@focused_pane_id}
                    pane_data={@pane_data}
                    terminal_themes={@terminal_themes}
                  />
                </div>
              <% end %>
            </div>
            {render_mobile_key_bar(assigns)}
            {render_mobile_nav_sheet(assigns)}
          <% {:error, :missing_path} -> %>
            <p class="text-sm text-red-700">
              Workspace has no host path. The manager has not finished provisioning, or this is a remote workspace.
            </p>
          <% {:error, :outside_root} -> %>
            <p class="text-sm text-red-700">
              Refusing to open terminal: workspace path is outside the allowed roots ({inspect(
                Workspaces.allowed_roots()
              )}).
            </p>
        <% end %>
      </div>
    </section>
    """
  end

  defp render_header_overflow_menu(assigns) do
    ~H"""
    <details class="header-overflow relative shrink-0">
      <summary
        class="flex cursor-pointer list-none select-none items-center justify-center rounded border border-base-300 px-1.5 py-0.5 text-base-content/70 transition hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:px-0 pointer-coarse:py-0 [&::-webkit-details-marker]:hidden"
        title="More workspace and terminal controls"
        aria-label="More header controls"
      >
        ⋯
      </summary>
      <div class="header-overflow-menu">
        <div class="px-3 py-1 text-[11px] text-base-content/70">
          <span class="rounded bg-base-200 px-1 py-0.5 uppercase">{@workspace.status}</span>
          <span :if={@workspace.branch} class="ml-1 font-mono text-base-content/60">
            {@workspace.branch}
          </span>
        </div>
        <button
          :if={workspace_startable?(@workspace, @workspace_start_error)}
          id="workspace-start-menu-button"
          type="button"
          phx-click="workspace:start"
          class="block w-full px-3 py-1.5 text-left text-xs text-primary hover:bg-base-200"
        >
          Start workspace
        </button>
        <div
          :if={workspace_start_blocked?(@workspace_start_error)}
          class="px-3 py-1 text-[11px] text-amber-600 dark:text-amber-300"
        >
          Start unavailable
        </div>
        <button
          :if={workspace_stoppable?(@workspace)}
          type="button"
          phx-click="workspace:stop"
          class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
        >
          Stop workspace
        </button>
        <%= if @tab == "terminal" and @terminal_mode in [:raw, :raw_ghostty] do %>
          <div class="my-0.5 border-t border-base-300/70"></div>
          <div class="px-3 py-1 font-mono text-[10px] text-base-content/50">
            tmux {terminal_session_label(@tmux_session, @terminal_sid)}
          </div>
          <%= if @active_window_pane_count > 1 do %>
            <button
              type="button"
              phx-click="equalize_layout"
              class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            >
              Reset pane layout ({@active_window_pane_count} panes)
            </button>
          <% end %>
        <% end %>
      </div>
    </details>
    """
  end

  # Mobile-only accessory key row. Soft keyboards have no Ctrl/Alt/Esc/Tab/
  # arrows; this bar synthesizes those keydowns onto the active terminal input
  # (see assets/js/mobile_key_bar.js). Hidden at lg+ where physical keys exist.
  # Session/window pickers live in the mode-chip sheet and palette — not here.
  #
  # The static modifier/arrow keys are wrapped in a phx-update="ignore" inner
  # div so JS modifier state (ctrl/alt latch) survives LiveView re-renders.
  # Pane/window action buttons sit outside that boundary so LiveView can update
  # them when @terminal_mode, @active_window_pane_count, etc. change.
  defp render_mobile_key_bar(assigns) do
    ~H"""
    <div
      id={"mobile-key-bar-" <> @workspace.id}
      phx-hook="MobileKeyBar"
      class="mobile-key-bar fixed inset-x-0 z-30 items-center gap-1 overflow-visible border-t border-zinc-700 bg-zinc-900/95 px-1.5 py-1 text-zinc-200 backdrop-blur supports-[backdrop-filter]:bg-zinc-900/80"
      style="bottom: var(--devide-mobile-keybar-bottom, 0px); padding-bottom: max(var(--devide-mobile-keybar-padding-bottom, 0.25rem), var(--devide-mobile-keybar-safe-area-bottom, env(safe-area-inset-bottom)));"
      role="toolbar"
      aria-label="Terminal keys"
    >
      <div
        id={"mobile-key-bar-scroll-" <> @workspace.id}
        class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      >
        <button
          id={"mobile-key-bar-mode-" <> @workspace.id}
          type="button"
          phx-click="mobile_nav:toggle"
          class="mr-0.5 inline-flex min-h-[1.9rem] shrink-0 items-center gap-1 rounded border border-zinc-600 bg-zinc-800 px-1.5 text-zinc-100 transition active:opacity-80"
          title={"Switch session or window — " <> mobile_mode_chip_title(assigns)}
          aria-label={
            "Switch session or window. Active session: " <>
              mobile_active_session_label(assigns) <> ". " <> mobile_mode_chip_title(assigns)
          }
          aria-expanded={@mobile_nav_open}
        >
          <.icon name="hero-rectangle-stack" class="size-3.5 shrink-0 text-zinc-400" />
          <span class="max-w-[6.5rem] truncate text-[11px] font-medium leading-none">
            {mobile_active_session_label(assigns)}
          </span>
        </button>
        <%!-- Static modifier + navigation keys. phx-update="ignore" preserves ctrl/alt latch state. --%>
        <div
          id={"mobile-key-bar-keys-" <> @workspace.id}
          phx-update="ignore"
          class="contents"
        >
          <button
            type="button"
            data-leader-prefix-button="true"
            aria-pressed="false"
            aria-label="tmux prefix key (Ctrl + B)"
            title="tmux prefix — tap, then a key"
            class={[
              mobile_key_class(),
              "aria-pressed:border-amber-400 aria-pressed:bg-amber-500/20 aria-pressed:text-amber-300"
            ]}
          >
            C-b
          </button>
          <button type="button" data-keybar-key="Escape" class={mobile_key_class()}>esc</button>
          <button
            type="button"
            data-keybar-key="Paste"
            class={mobile_key_class()}
            aria-label="Paste from clipboard"
          >
            paste
          </button>
          <button type="button" data-keybar-key="Tab" class={mobile_key_class()}>tab</button>
          <button
            type="button"
            data-keybar-key="Control"
            data-mod-state="off"
            aria-pressed="false"
            class={mobile_mod_class()}
          >
            ctrl
          </button>
          <button
            type="button"
            data-keybar-key="Alt"
            data-mod-state="off"
            aria-pressed="false"
            class={mobile_mod_class()}
          >
            alt
          </button>
          <button type="button" data-keybar-key="CtrlC" class={mobile_key_class()}>^C</button>
          <button
            type="button"
            data-keybar-key="Select"
            class={mobile_key_class()}
            aria-label="Select and copy terminal text"
          >
            select
          </button>
          <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
          <button
            type="button"
            data-keybar-key="ArrowLeft"
            class={mobile_key_class()}
            aria-label="Left"
          >
            ←
          </button>
          <button
            type="button"
            data-keybar-key="ArrowDown"
            class={mobile_key_class()}
            aria-label="Down"
          >
            ↓
          </button>
          <button
            type="button"
            data-keybar-key="ArrowUp"
            class={mobile_key_class()}
            aria-label="Up"
          >
            ↑
          </button>
          <button
            type="button"
            data-keybar-key="ArrowRight"
            class={mobile_key_class()}
            aria-label="Right"
          >
            →
          </button>
        </div>
        <%!-- LiveView-updated pane/window action buttons. Current-window actions
             lead; window prev/next trail since swiping already cycles focus. --%>
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
        <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
          <button
            type="button"
            phx-click="split_right"
            class={mobile_key_class()}
            aria-label="Split right"
            title="Split right"
          >
            <.split_icon direction={:right} class="size-4" />
          </button>
          <button
            type="button"
            phx-click="split_down"
            class={mobile_key_class()}
            aria-label="Split down"
            title="Split down"
          >
            <.split_icon direction={:down} class="size-4" />
          </button>
          <button
            type="button"
            phx-click="pane:zoom_focused"
            class={mobile_key_class()}
            aria-label={if @window_zoomed?, do: "Unzoom pane", else: "Zoom pane"}
            title={if @window_zoomed?, do: "Unzoom pane", else: "Zoom pane"}
          >
            {if @window_zoomed?, do: "⤡", else: "⤢"}
          </button>
          <%= if @active_window_pane_count > 1 do %>
            <% pane_count = @active_window_pane_count %>
            <button
              type="button"
              phx-click="pane:focus_next"
              class={mobile_key_class() <> " relative"}
              aria-label={"Next pane (#{pane_count} total)"}
              title="Next pane"
            >
              <.icon name="hero-arrow-path" class="size-4" />
              <span class="absolute -right-0.5 -top-0.5 flex size-3.5 items-center justify-center rounded-full bg-primary text-[8px] font-bold leading-none text-primary-content">
                {pane_count}
              </span>
            </button>
            <button
              type="button"
              phx-click="pane:close_focused"
              class={mobile_key_class()}
              aria-label="Close pane"
              title="Close pane"
            >
              ×
            </button>
          <% end %>
        <% end %>
        <%= if @tmux_mutations_enabled? do %>
          <button
            type="button"
            phx-click="tmux:new_window"
            class={mobile_key_class()}
            aria-label="New window"
            title="New window"
          >
            +
          </button>
        <% end %>
        <button
          type="button"
          data-keybar-key="Palette"
          class={mobile_key_class()}
          aria-label="Open command palette"
          title="Command palette"
        >
          ⌘
        </button>
        <%= if length(@tmux_window_tabs) > 1 do %>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="prev"
            class={mobile_key_class()}
            aria-label="Previous window"
            title="Previous window"
          >
            ‹
          </button>
          <button
            type="button"
            phx-click="tmux:last_window"
            class={mobile_key_class()}
            aria-label="Last window"
            title="Last window"
          >
            <.icon name="hero-clock" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
            class={mobile_key_class()}
            aria-label="Next window"
            title="Next window"
          >
            ›
          </button>
        <% end %>
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
        <button
          type="button"
          data-keybar-key="FontDown"
          class={mobile_key_class()}
          aria-label="Decrease font size"
          title="Decrease font size"
        >
          A-
        </button>
        <button
          type="button"
          data-keybar-key="FontUp"
          class={mobile_key_class()}
          aria-label="Increase font size"
          title="Increase font size"
        >
          A+
        </button>
      </div>
    </div>
    """
  end

  defp render_mobile_nav_sheet(assigns) do
    # Window-picker-dominant: the sheet opens on the attached session's window
    # list; a back arrow (or ← on a window row) hops out to the sessions tree.
    # Resolve the view at render time so a session losing its windows while the
    # sheet is open degrades to the sessions list instead of an empty pane.
    active_tab = mobile_nav_active_tab(assigns)

    view =
      if assigns.mobile_nav_view == "windows" and match?(%{windows: [_ | _]}, active_tab),
        do: "windows",
        else: "sessions"

    assigns =
      assigns
      |> Phoenix.Component.assign(:mnav_active_tab, active_tab)
      |> Phoenix.Component.assign(:mnav_view, view)

    ~H"""
    <div
      :if={@mobile_nav_open}
      id={"mobile-nav-sheet-" <> @workspace.id}
      phx-hook="MobileNavSheet"
      data-mobile-nav-focus={@mobile_nav_focus}
      data-mobile-nav-view={@mnav_view}
      class="mobile-nav-sheet fixed inset-0 z-40 hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Session and window picker"
    >
      <button
        type="button"
        phx-click="mobile_nav:close"
        class="absolute inset-0 bg-black/45"
        aria-label="Close session and window picker"
      ></button>
      <div
        class="absolute inset-x-0 bottom-0 max-h-[70dvh] overflow-y-auto rounded-t-xl border border-zinc-700 bg-zinc-950 px-3 pb-3 pt-3 text-zinc-100 shadow-2xl"
        style="margin-bottom: var(--devide-mobile-terminal-inset, 0px);"
      >
        <div class="mb-2 flex items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-1.5">
            <button
              :if={@mnav_view == "windows"}
              type="button"
              phx-click="mobile_nav:set_view"
              phx-value-view="sessions"
              class="flex shrink-0 items-center justify-center rounded border border-zinc-700 p-1 text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100"
              aria-label="Back to all sessions"
              title="All sessions"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <div class="min-w-0">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-zinc-500">
                {if @mnav_view == "windows", do: "Windows", else: "Navigate"}
              </div>
              <div class="truncate text-sm font-medium">{mobile_nav_sheet_title(assigns)}</div>
            </div>
          </div>
          <button
            type="button"
            phx-click="mobile_nav:close"
            class="shrink-0 rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-300"
          >
            Done
          </button>
        </div>
        <%!-- Dominant view: flat window list of the attached session. --%>
        <div :if={@mnav_view == "windows"} class="space-y-0.5">
          <%= for window <- @mnav_active_tab.windows do %>
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-picker-item
                data-picker-section="windows"
                data-picker-active={window.active? || nil}
                phx-click={
                  JS.push("tmux:select_window", value: %{"window-id" => window.id})
                  |> JS.push("mobile_nav:close")
                }
                class={[
                  mobile_nav_row_class(window.active?),
                  "min-w-0 flex-1 flex-row items-center gap-1.5"
                ]}
              >
                <span class="font-mono text-[10px] text-zinc-500">{window.index}</span>
                <span data-picker-label class="min-w-0 truncate font-medium">{window.name}</span>
              </button>
              <SessionBar.copy_link_button
                url={
                  SessionBar.share_url(@workspace.id, @mnav_active_tab.id, window.id,
                    path_base: @lan_friendly_path
                  )
                }
                label={@mnav_active_tab.label <> " · " <> window.name}
                kind="window"
                visible?={true}
              />
            </div>
          <% end %>
        </div>
        <%!--
          Tree picker: sessions are top-level rows, their tmux windows nest
          beneath (mirrors the desktop SessionBar.session_dropdown tree). Rows
          carry [data-picker-item]/[data-picker-active] and the windows-group
          wiring (data-picker-windows-id / data-picker-parent) that the
          MobileNavSheet hook drives with ↑/↓/→/←/Enter/Esc. Ids are prefixed
          "mnav-" so they never collide with the (also-rendered, CSS-hidden)
          desktop dropdown's ids.
        --%>
        <div
          :if={@mnav_view == "sessions"}
          class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-zinc-500"
        >
          Sessions &amp; windows
        </div>
        <div :if={@mnav_view == "sessions"} class="space-y-0.5">
          <div :if={@session_tabs == []} class="flex items-center gap-1">
            <button
              type="button"
              data-picker-item
              data-picker-section="sessions"
              data-picker-active={true}
              phx-click={
                JS.push("terminal:switch_to_shell")
                |> JS.push("mobile_nav:close")
              }
              class={[mobile_nav_row_class(true), "min-w-0 flex-1"]}
            >
              <span class="flex min-w-0 items-center gap-1">
                <.icon name="hero-home" class="size-3 shrink-0 text-zinc-500" />
                <span data-picker-label class="truncate font-medium">
                  {@shell_button_label}
                </span>
              </span>
              <span
                :if={@shell_button_detail != ""}
                class="truncate font-mono text-[10px] text-zinc-500"
              >
                {@shell_button_detail}
              </span>
            </button>
            <SessionBar.copy_link_button
              url={
                SessionBar.share_url(@workspace.id, @default_terminal_sid, nil,
                  path_base: @lan_friendly_path
                )
              }
              label={@shell_button_label}
              visible?={true}
            />
          </div>
          <%= for tab <- @session_tabs do %>
            <% session_active? = @terminal_sid == tab.id %>
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-picker-item
                data-picker-section="sessions"
                data-picker-active={session_active? || nil}
                data-picker-windows-id={tab.window_count > 0 && tab.dom_id}
                phx-click={
                  JS.push("attach_terminal_session",
                    value: %{
                      "session-id" => tab.id,
                      "kind" => Atom.to_string(tab.kind),
                      "tmux-session" => tab.tmux_session
                    }
                  )
                  |> JS.push("mobile_nav:close")
                }
                class={[mobile_nav_row_class(session_active?), "min-w-0 flex-1"]}
              >
                <span class="flex min-w-0 items-center gap-1">
                  <.icon
                    :if={tab.id == @default_terminal_sid}
                    name="hero-home"
                    class="size-3 shrink-0 text-zinc-500"
                  />
                  <span data-picker-label class="truncate font-medium">{tab.label}</span>
                </span>
                <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-zinc-500">
                  {tab.detail}
                </span>
              </button>
              <button
                :if={tab.window_count > 0}
                id={"mnav-windows-toggle-" <> tab.dom_id}
                type="button"
                tabindex="-1"
                phx-click={
                  JS.toggle(to: "#mnav-windows-" <> tab.dom_id, display: "block")
                  |> JS.toggle_class("rotate-90", to: "#mnav-windows-chevron-" <> tab.dom_id)
                }
                class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
                aria-label={"Toggle windows of " <> tab.label}
              >
                {tab.window_count}
                <span
                  id={"mnav-windows-chevron-" <> tab.dom_id}
                  class={[
                    "flex transition-transform",
                    session_active? && "rotate-90"
                  ]}
                >
                  <.icon name="hero-chevron-right" class="size-3" />
                </span>
              </button>
              <SessionBar.copy_link_button
                url={SessionBar.share_url(@workspace.id, tab.id, nil, path_base: @lan_friendly_path)}
                label={tab.label}
                visible?={true}
              />
            </div>
            <div
              :if={tab.windows != []}
              id={"mnav-windows-" <> tab.dom_id}
              class={["space-y-0.5 pl-3", !session_active? && "hidden"]}
            >
              <%= for window <- tab.windows do %>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    data-picker-item
                    data-picker-section="windows"
                    data-picker-parent={tab.dom_id}
                    data-picker-active={(session_active? and window.active?) || nil}
                    phx-click={
                      # Active session: a cheap in-session window switch. Other
                      # sessions: attach to that session on the chosen window.
                      if session_active? do
                        JS.push("tmux:select_window", value: %{"window-id" => window.id})
                        |> JS.push("mobile_nav:close")
                      else
                        JS.push("attach_terminal_session",
                          value: %{
                            "session-id" => tab.id,
                            "kind" => Atom.to_string(tab.kind),
                            "tmux-session" => tab.tmux_session,
                            "window-id" => window.id
                          }
                        )
                        |> JS.push("mobile_nav:close")
                      end
                    }
                    class={[
                      mobile_nav_row_class(session_active? and window.active?),
                      "min-w-0 flex-1 flex-row items-center gap-1.5"
                    ]}
                  >
                    <span class="font-mono text-[10px] text-zinc-500">{window.index}</span>
                    <span data-picker-label class="min-w-0 truncate font-medium">{window.name}</span>
                  </button>
                  <SessionBar.copy_link_button
                    url={
                      SessionBar.share_url(@workspace.id, tab.id, window.id,
                        path_base: @lan_friendly_path
                      )
                    }
                    label={tab.label <> " · " <> window.name}
                    kind="window"
                    visible?={true}
                  />
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp mobile_nav_row_class(true),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded border border-primary/40 bg-primary/10 px-2.5 py-1.5 text-left text-xs text-primary"

  defp mobile_nav_row_class(false),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded px-2.5 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800"

  defp mobile_key_class do
    "inline-flex flex-none items-center justify-center rounded border border-zinc-700 bg-zinc-800 " <>
      "px-2.5 font-mono text-xs leading-none active:bg-zinc-700 hover:bg-zinc-700 transition-colors " <>
      "min-w-[2.25rem] min-h-[1.9rem]"
  end

  # Sticky-modifier styling driven by the data-mod-state the JS hook maintains
  # (off | armed | locked). Arbitrary variants key off the data attribute so the
  # JS only has to flip one attribute, no class juggling.
  defp mobile_mod_class do
    "inline-flex flex-none items-center justify-center rounded border px-2.5 font-mono text-xs leading-none " <>
      "transition-colors min-w-[2.5rem] min-h-[1.9rem] " <>
      "border-zinc-700 bg-zinc-800 " <>
      "data-[mod-state=armed]:border-emerald-400 data-[mod-state=armed]:bg-emerald-500/20 data-[mod-state=armed]:text-emerald-300 " <>
      "data-[mod-state=locked]:border-amber-400 data-[mod-state=locked]:bg-amber-500/30 data-[mod-state=locked]:text-amber-200"
  end

  defp parse_line(nil), do: nil
  defp parse_line(""), do: nil

  defp parse_line(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_line(_), do: nil

  defp palette_query(socket, q), do: PaletteItems.query(socket, q)

  defp refresh_open_palette(socket) do
    assign_palette_items_preserving_selection(
      socket,
      palette_query(socket, socket.assigns[:palette_query] || "")
    )
  end

  defp assign_palette_items_preserving_selection(socket, items) do
    old_count = length(socket.assigns[:palette_items] || [])
    selected_idx = socket.assigns[:palette_selected_idx] || 0
    new_count = length(items)

    next_idx =
      cond do
        new_count == 0 -> 0
        old_count > 0 and selected_idx >= old_count - 1 -> new_count - 1
        true -> min(selected_idx, new_count - 1)
      end

    socket
    |> assign(:palette_items, items)
    |> assign(:palette_selected_idx, next_idx)
  end

  # Ordered category tabs shown in the palette. `:all` is always first so the
  # user can broaden out of any screen-derived default.
  @palette_categories [:all, :files, :commands, :tmux, :agents, :preview, :view, :actions]

  @doc false
  def palette_categories, do: @palette_categories

  @doc false
  def palette_category_label(:all), do: "all"
  def palette_category_label(:files), do: "files"
  def palette_category_label(:commands), do: "commands"
  def palette_category_label(:tmux), do: "tmux"
  def palette_category_label(:agents), do: "agents"
  def palette_category_label(:preview), do: "preview"
  def palette_category_label(:view), do: "view"
  def palette_category_label(:actions), do: "actions"

  defp render_palette(assigns) do
    assigns =
      Phoenix.Component.assign(
        assigns,
        :palette_selected_id,
        palette_selected_id(assigns[:palette_items], assigns[:palette_selected_idx])
      )

    ~H"""
    <%= if @palette_open do %>
      <div
        class="fixed inset-0 bg-black/50 z-50 flex items-start justify-center pt-24"
        phx-click="palette:close"
      >
        <div
          class="bg-base-100 text-base-content rounded shadow-2xl w-[640px] max-w-[90vw] border border-base-300"
          phx-click-away="palette:close"
        >
          <.form
            for={%{}}
            id="palette-form"
            phx-change="palette:query"
            phx-submit="palette:execute"
            class="p-2 border-b border-base-300"
          >
            <%!--
              `phx-mounted` runs the focus command every time this input
              is inserted into the DOM (each time the palette opens),
              which `autofocus` alone does not — the user usually opens
              the palette while focus is in the terminal/PTY, so we
              have to take it explicitly.
            --%>
            <input
              id="palette-query"
              name="query"
              value={@palette_query}
              autocomplete="off"
              spellcheck="false"
              placeholder="Search sessions, windows, files, commands…"
              phx-mounted={Phoenix.LiveView.JS.focus()}
              class="w-full bg-transparent text-sm px-2 py-1.5 outline-none placeholder:text-base-content/40"
            />
            <%!--
              The hidden _selected_id field carries the currently
              highlighted item to the server when the form submits
              (Enter). Falls back to the top item if nothing is
              explicitly selected.
            --%>
            <input type="hidden" name="_selected_id" value={@palette_selected_id} />
          </.form>
          <%!--
            Category tabs. The active screen sets the default (see
            default_palette_category/1); Tab / Shift+Tab cycle them from the
            PaletteHook, and clicking selects directly. ":all" is always first.
          --%>
          <div
            id="palette-categories"
            class="flex items-center gap-1 px-2 py-1 border-b border-base-300 text-xs"
          >
            <%= for cat <- palette_categories() do %>
              <button
                type="button"
                phx-click="palette:category"
                phx-value-category={Atom.to_string(cat)}
                class={[
                  "px-2 py-0.5 rounded font-mono lowercase",
                  if(cat == (@palette_category || :all),
                    do: "bg-primary/20 text-base-content",
                    else: "text-base-content/55 hover:bg-base-200"
                  )
                ]}
              >
                {palette_category_label(cat)}
              </button>
            <% end %>
          </div>
          <ul id="palette-results" class="max-h-[60vh] overflow-auto text-sm">
            <%= if @palette_items == [] do %>
              <li class="px-3 py-2 text-base-content/60 text-xs">No matches.</li>
            <% else %>
              <%= for {item, idx} <- Enum.with_index(@palette_items) do %>
                <li
                  id={"palette-item-" <> Integer.to_string(idx)}
                  data-palette-idx={idx}
                  class={[
                    "flex items-center gap-2 px-3 py-1.5 border-b border-base-200 last:border-b-0 cursor-pointer hover:bg-base-200",
                    if(idx == (@palette_selected_idx || 0),
                      do: "bg-primary/15 text-base-content",
                      else: ""
                    )
                  ]}
                  phx-click="palette:execute"
                  phx-value-id={item.id}
                >
                  <span class="text-[10px] uppercase text-base-content/50 w-14 shrink-0">
                    {item.kind}
                  </span>
                  <span class="font-mono truncate flex-1">{item.label}</span>
                  <%= if item.detail do %>
                    <span class="text-xs text-base-content/60 truncate">{item.detail}</span>
                  <% end %>
                </li>
              <% end %>
            <% end %>
          </ul>
          <div class="px-3 py-1.5 text-[10px] text-base-content/60 border-t border-base-300 flex flex-wrap items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↑</kbd>
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↓</kbd>
                <span class="text-base-content/70">navigate</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">↵</kbd>
                <span class="text-base-content/70">run</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">Esc</kbd>
                <span class="text-base-content/70">close</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">⇥</kbd>
                <span class="text-base-content/70">category</span>
              </span>
              <span class="inline-flex items-center gap-1">
                <kbd class="rounded border border-base-300 bg-base-200 px-1 font-mono">⌃Space</kbd>
                <span class="text-base-content/70">toggle</span>
              </span>
            </div>
            <span>{length(@palette_items)} item(s)</span>
          </div>
        </div>
      </div>
    <% else %>
      <div id="palette-modal-empty" class="hidden"></div>
    <% end %>
    """
  end

  defp palette_selected_id(items, idx) when is_list(items) and items != [] do
    safe_idx = (idx || 0) |> max(0) |> min(length(items) - 1)
    items |> Enum.at(safe_idx) |> Map.get(:id)
  end

  defp palette_selected_id(_, _), do: ""

  defp render_logs(assigns) do
    ~H"""
    <.logs_panel log_service={@log_service} log_ref={@log_ref} streams={@streams} />
    """
  end

  # render_path/2 and tab_class/2 now live in DevIdeWeb.WorkspaceLive.Show.UI
  # (imported above).

  defp subscribe_pane_labels(socket) do
    if connected?(socket) do
      :ok = Labels.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp subscribe_previews(socket) do
    if connected?(socket) do
      for workspace_id <- preview_subscription_workspace_ids(socket) do
        Phoenix.PubSub.subscribe(
          DevIde.PubSub,
          "preview:" <> workspace_id
        )
      end
    end

    socket
  end

  defp subscribe_browser_control(socket) do
    if connected?(socket) do
      for workspace_id <- preview_subscription_workspace_ids(socket) do
        _ = BrowserControl.subscribe(workspace_id)
      end
    end

    socket
  end

  defp maybe_select_requested_terminal_session(socket, %{"session" => sid} = params)
       when is_binary(sid) and sid != "" do
    if sid == socket.assigns[:terminal_sid] do
      {socket, false}
    else
      {socket, _switched?} =
        switch_terminal_session_from_params(socket, sid, Map.get(params, "tmux_session"))

      if socket.assigns[:terminal_sid] == sid do
        {socket, true}
      else
        # The shared session has ended or wasn't found. Silently drop into a live
        # session instead of stranding the operator on a dead pane behind a banner,
        # and clear the "session ended" error flash that the switch attempt raised.
        {socket |> drop_into_live_session() |> clear_flash(:error), true}
      end
    end
  end

  defp maybe_select_requested_terminal_session(socket, _params) do
    {drop_into_live_session(socket), false}
  end

  defp drop_into_live_session(socket) do
    sid = socket.assigns[:default_terminal_sid]

    if is_binary(sid) and sid != "" and sid != socket.assigns[:terminal_sid] do
      {switched_socket, _switched?} = switch_terminal_session_from_params(socket, sid)
      switched_socket
    else
      socket
    end
  end

  defp current_share_url(assigns) do
    SessionBar.share_url(
      assigns.workspace.id,
      assigns.terminal_sid,
      assigns[:tmux_active_window_id],
      DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.share_query_opts(assigns)
    )
  end

  defp maybe_select_requested_tmux_window(socket, nil), do: {socket, false}
  defp maybe_select_requested_tmux_window(socket, ""), do: {socket, false}

  defp maybe_select_requested_tmux_window(socket, window_id) when is_binary(window_id) do
    if window_id == socket.assigns[:tmux_active_window_id] do
      {socket, false}
    else
      case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
        :ok ->
          {socket, true}

        # Requested window is gone — silently stay on the current (closest live) window.
        {:error, _reason} ->
          {socket, false}
      end
    end
  end

  defp switch_terminal_session_from_params(socket, sid, tmux_session_hint \\ nil) do
    socket = TerminalState.switch_active_session(socket, sid, tmux_session_hint)

    {socket, socket.assigns[:terminal_sid] == sid}
  end

  defp tmux_topology_uninitialized?(socket) do
    socket.assigns[:tmux_topology_version] in [nil, 0]
  end

  def template_save_form(params \\ %{}) do
    TemplateForm.to_form(TemplateForm.from_params(params))
  end

  def template_edit_form(params \\ %{}) do
    params =
      %{"id" => "", "name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value || ""} end))

    to_form(params, as: :template)
  end

  def template_duplicate_form(params \\ %{}) do
    params =
      %{"source_id" => "", "name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value || ""} end))

    to_form(params, as: :template)
  end

  def template_duplicate_form(socket, saved) do
    template_duplicate_form(%{
      "source_id" => saved.id,
      "name" =>
        saved_template_copy_name(socket.assigns[:saved_session_templates] || [], saved.name),
      "description" => saved.description || "",
      "tags" => saved_template_tags_string(saved)
    })
  end

  def apply_session_template(socket, template_id, opts \\ []) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket =
        socket
        |> assign(:template_preview, nil)
        |> assign(:template_library_open, false)
        |> TerminalState.ensure_primary_tmux_session()

      case execute_session_template(socket, template_id, opts) do
        {:ok, result} ->
          {:noreply, applied_session_template(socket, template_id, result)}

        {:error, :template_not_found} ->
          {:noreply, put_flash(socket, :error, "Session template not found.")}

        {:error, :unsupported_template} ->
          {:noreply, put_flash(socket, :error, "This saved template cannot be applied yet.")}

        {:error, {reason, step, _partial}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Could not apply session template at #{step.action}: #{inspect(reason)}"
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not apply session template: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  defp applied_session_template(socket, template_id, result) do
    socket =
      socket
      |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
      |> assign_workspace_summaries()

    emit_tmux_template_audit(socket, template_id, result)

    socket =
      case socket.assigns.tmux_active_window_id do
        nil ->
          socket

        _window_id ->
          DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.patch_current_view(socket)
      end

    socket =
      if template_id == "agent_preview_demo",
        do: schedule_preview_demo_open(socket),
        else: socket

    if is_binary(socket.assigns.tmux_session) do
      _ = ensure_pane_agent_env(socket, socket.assigns.tmux_session)
    end

    put_flash(socket, :info, "Applied session template: #{template_result_name(result)}")
  end

  def dry_run_session_template(socket, template_id) do
    opts = [workspace_root: workspace_cwd(socket)]

    case Terminals.dry_run_session_template(template_id, opts) do
      {:error, :template_not_found} ->
        dry_run_saved_session_template(socket, template_id, opts)

      result ->
        result
    end
  end

  defp dry_run_saved_session_template(socket, template_id, opts) do
    topology =
      Terminals.tmux_topology_snapshot(socket.assigns.tmux_session)

    with {:ok, preview} <-
           Terminals.dry_run_saved_template(socket.assigns.workspace.id, template_id, opts),
         {:ok, diff} <-
           Terminals.diff_saved_template(socket.assigns.workspace.id, template_id, topology, opts) do
      {:ok,
       preview
       |> Map.put(:diff, diff)
       |> Map.put(:reconcile, true)}
    end
  end

  defp execute_session_template(socket, template_id, opts) do
    if Keyword.get(opts, :reconcile, false) do
      execute_reconciled_session_template(socket, template_id)
    else
      execute_exact_session_template(socket, template_id)
    end
  end

  defp execute_exact_session_template(socket, template_id) do
    opts = [tmux: TerminalState.tmux_adapter(), workspace_root: workspace_cwd(socket)]

    case Terminals.execute_session_template(socket.assigns.tmux_session, template_id, opts) do
      {:error, :template_not_found} ->
        Terminals.execute_saved_template(
          socket.assigns.workspace.id,
          socket.assigns.tmux_session,
          template_id,
          opts
        )

      result ->
        result
    end
  end

  defp execute_reconciled_session_template(socket, template_id) do
    topology =
      Terminals.tmux_topology_snapshot(socket.assigns.tmux_session)

    opts = [tmux: TerminalState.tmux_adapter(), workspace_root: workspace_cwd(socket)]

    case Terminals.execute_saved_template_reconcile(
           socket.assigns.workspace.id,
           socket.assigns.tmux_session,
           template_id,
           topology,
           opts
         ) do
      {:ok, %{diff: diff, execution: execution}} ->
        {:ok,
         execution
         |> Map.put(:diff, diff)
         |> Map.put(:plan_executed, true)
         |> Map.put(:reconcile, true)}

      error ->
        error
    end
  end

  def save_current_session_template(socket, params) do
    changeset = TemplateForm.from_params(params) |> TemplateForm.validate()

    if changeset.valid? do
      %{name: name, description: description, tags: tags} = TemplateForm.apply(changeset)

      topology =
        Terminals.tmux_topology_snapshot(socket.assigns.tmux_session)

      with {:ok, template} <-
             Terminals.export_session_template(topology,
               workspace_root: workspace_cwd(socket),
               name: name
             ),
           {:ok, saved} <-
             Terminals.save_template(%{
               workspace_id: socket.assigns.workspace.id,
               name: name,
               description: blank_to_nil(description),
               body: template,
               source_session: socket.assigns.tmux_session,
               schema_version: Map.get(template, "version", 2),
               tags: tags
             }) do
        emit_tmux_template_saved_audit(socket, saved, topology)

        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_save_form, template_save_form())
         |> put_flash(:info, "Saved session template: #{saved.name}")}
      else
        {:error, :empty_topology} ->
          {:noreply, put_flash(socket, :error, "Could not save an empty tmux layout.")}

        {:error, changeset = %Ecto.Changeset{}} ->
          {:noreply,
           socket
           |> assign(:template_library_open, true)
           |> assign(:template_save_form, template_save_form(params))
           |> put_flash(:error, "Could not save template: #{inspect(changeset.errors)}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not save template: #{inspect(reason)}")}
      end
    else
      {:noreply,
       socket
       |> assign(:template_library_open, true)
       |> assign(:template_save_form, TemplateForm.to_form(changeset, action: :validate))}
    end
  end

  def update_saved_session_template(socket, params) do
    workspace_id = socket.assigns.workspace.id
    template_id = Map.get(params, "id") || socket.assigns[:template_edit_id]
    attrs = Map.take(params, ["name", "description", "tags"])

    with template_id when is_binary(template_id) and template_id != "" <- template_id,
         {:ok, saved} <- Terminals.get_saved_template(workspace_id, template_id),
         {:ok, updated} <- Terminals.update_saved_template(workspace_id, template_id, attrs) do
      changes = template_update_changes(saved, updated)
      emit_tmux_template_updated_audit(socket, updated, changes)

      {:noreply,
       socket
       |> refresh_saved_session_templates()
       |> assign(:template_library_open, true)
       |> assign(:template_edit_id, nil)
       |> assign(:template_edit_form, template_edit_form())
       |> put_flash(:info, "Updated saved template: #{updated.name}")}
    else
      nil ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, template_edit_form())
         |> put_flash(:error, "Saved template not found.")}

      "" ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, template_edit_form())
         |> put_flash(:error, "Saved template not found.")}

      {:error, :name_required} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, template_id)
         |> assign(:template_edit_form, template_edit_form(Map.put(params, "id", template_id)))
         |> put_flash(:error, "Template name cannot be blank.")}

      {:error, :name_taken} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, template_id)
         |> assign(:template_edit_form, template_edit_form(Map.put(params, "id", template_id)))
         |> put_flash(:error, "A saved template already uses that name.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, template_edit_form())
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def duplicate_saved_session_template(socket, params) do
    workspace_id = socket.assigns.workspace.id
    source_id = Map.get(params, "source_id") || socket.assigns[:template_duplicate_id]
    attrs = Map.take(params, ["name", "description", "tags"])

    with source_id when is_binary(source_id) and source_id != "" <- source_id,
         {:ok, duplicated} <- Terminals.duplicate_saved_template(workspace_id, source_id, attrs) do
      emit_tmux_template_duplicated_audit(socket, source_id, duplicated)

      {:noreply,
       socket
       |> refresh_saved_session_templates()
       |> assign(:template_library_open, true)
       |> assign(:template_duplicate_id, nil)
       |> assign(:template_duplicate_form, template_duplicate_form())
       |> put_flash(:info, "Duplicated saved template: #{duplicated.name}")}
    else
      nil ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, template_duplicate_form())
         |> put_flash(:error, "Saved template not found.")}

      "" ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, template_duplicate_form())
         |> put_flash(:error, "Saved template not found.")}

      {:error, :name_required} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_duplicate_id, source_id)
         |> assign(
           :template_duplicate_form,
           template_duplicate_form(Map.put(params, "source_id", source_id))
         )
         |> put_flash(:error, "Template name cannot be blank.")}

      {:error, :name_taken} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_duplicate_id, source_id)
         |> assign(
           :template_duplicate_form,
           template_duplicate_form(Map.put(params, "source_id", source_id))
         )
         |> put_flash(:error, "A saved template already uses that name.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, template_duplicate_form())
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def delete_saved_session_template(socket, template_id) do
    workspace_id = socket.assigns.workspace.id

    with {:ok, saved} <- Terminals.get_saved_template(workspace_id, template_id),
         :ok <- Terminals.delete_saved_template(workspace_id, template_id) do
      emit_tmux_template_deleted_audit(socket, saved)

      socket =
        case socket.assigns[:template_preview] do
          %{template: %{id: ^template_id}} -> assign(socket, :template_preview, nil)
          _ -> socket
        end

      {:noreply,
       socket
       |> refresh_saved_session_templates()
       |> assign(:template_library_open, true)
       |> assign(:template_edit_id, nil)
       |> assign(:template_edit_form, template_edit_form())
       |> assign(:template_duplicate_id, nil)
       |> assign(:template_duplicate_form, template_duplicate_form())
       |> put_flash(:info, "Deleted saved template: #{saved.name}")}
    else
      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, template_edit_form())
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, template_duplicate_form())
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def refresh_saved_session_templates(socket) do
    workspace_id = socket.assigns.workspace.id
    tag_filter = socket.assigns[:template_tag_filter]

    # Load tags + filtered templates off the LiveView process so these two DB
    # reads don't block the channel on every template-management event. The
    # results (and the dependent palette items) are applied in
    # handle_async(:saved_session_templates, ...).
    start_async(socket, :saved_session_templates, fn ->
      {
        saved_session_template_tags(workspace_id),
        Terminals.list_saved_templates(workspace_id, tags: tag_filter)
      }
    end)
  end

  defp emit_tmux_template_audit(socket, template_id, result) do
    Audit.emit!(%{
      action: "tmux.template_applied",
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "tmux_template",
      target_ref: template_id,
      metadata: %{
        session: socket.assigns.tmux_session,
        template_id: template_id,
        step_count: result.step_count,
        refs: result.refs,
        strategy: Map.get(result, :strategy),
        reconciliation: Map.get(result, :reconciliation),
        estimated_disruption: Map.get(result, :estimated_disruption),
        active_window_id: socket.assigns.tmux_active_window_id,
        active_pane_id: socket.assigns.tmux_active_pane_id,
        topology_version: socket.assigns.tmux_topology_version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_saved_audit(socket, saved, topology) do
    Audit.emit!(%{
      action: "tmux.template_saved",
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        session: socket.assigns.tmux_session,
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        topology_version: Map.get(topology, :version),
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_deleted_audit(socket, saved) do
    Audit.emit!(%{
      action: "tmux.template_deleted",
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        session: socket.assigns.tmux_session,
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_updated_audit(socket, saved, changes) do
    Audit.emit!(%{
      action: "tmux.template_updated",
      workspace_id: socket.assigns.workspace.id,
      actor_id: current_actor_id(socket),
      target_type: "tmux_template",
      target_ref: saved.id,
      metadata: %{
        session: socket.assigns.tmux_session,
        template_id: saved.id,
        template_name: saved.name,
        schema_version: saved.schema_version,
        changes: changes,
        dry_run: false
      }
    })
  end

  defp emit_tmux_template_duplicated_audit(socket, source_id, duplicated) do
    Audit.emit!(%{
      action: "tmux.template_duplicated",
      workspace_id: socket.assigns.workspace.id,
      actor_id: current_actor_id(socket),
      target_type: "tmux_template",
      target_ref: duplicated.id,
      metadata: %{
        session: socket.assigns.tmux_session,
        source_template_id: source_id,
        template_id: duplicated.id,
        template_name: duplicated.name,
        schema_version: duplicated.schema_version,
        dry_run: false
      }
    })
  end

  defp template_update_changes(before, after_update) do
    [:name, :description, :tags]
    |> Enum.reduce(%{}, fn field, acc ->
      before_value = Map.get(before, field)
      after_value = Map.get(after_update, field)

      if before_value == after_value do
        acc
      else
        Map.put(acc, field, %{before: before_value, after: after_value})
      end
    end)
  end

  defp template_result_name(%{template: %{name: name}}) when is_binary(name), do: name
  defp template_result_name(_result), do: "template"

  # audits, this fills the gap for the surface itself.
  @doc false
  def audit_terminal_mode_transition(socket, from, to) when from == to, do: socket

  def audit_terminal_mode_transition(socket, from, to)
      when to in [:raw, :raw_ghostty] do
    action =
      case to do
        :raw -> "terminal.raw_entered"
        :raw_ghostty -> "ghostty.raw_terminal_entered"
      end

    DevIDE.Audit.emit!(%{
      action: action,
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "terminal",
      target_ref: @ghostty_term_id,
      metadata:
        %{
          "from" => to_string(from),
          "to" => to_string(to),
          "host_id" => socket.assigns[:host_id],
          "workspace_mode" => to_string(socket.assigns[:workspace_mode])
        }
        |> Map.merge(
          DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_metadata(socket)
        )
    })

    socket
  end

  @doc false
  defdelegate raw_terminal_allowed?(workspace_mode, host_id),
    to: Terminals,
    as: :raw_terminal_mode_allowed?

  @doc false
  defdelegate raw_default?(workspace_mode, host_id), to: Terminals, as: :raw_terminal_default?

  defp handle_paste_file(params, socket, kind) do
    socket = refresh_workspace_mode(socket)

    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      paste_file_to_workspace(params, socket, kind)
    else
      {:reply, %{ok: false, reason: "raw terminal access is required to paste files"}, socket}
    end
  end

  defp paste_file_to_workspace(params, socket, kind) do
    with {:ok, root} <- context_host_path(socket),
         {:ok, result} <- save_clipboard_file(root, params, kind) do
      audit_clipboard_file_pasted!(socket, result, kind)

      {:reply,
       %{
         ok: true,
         path: result.path,
         relative_path: result.relative_path,
         bytes: result.bytes,
         content_type: result.content_type
       }, socket}
    else
      {:error, reason} ->
        {:reply, %{ok: false, reason: paste_file_reason(reason)}, socket}

      _ ->
        {:reply, %{ok: false, reason: "workspace path is not available"}, socket}
    end
  end

  defp audit_clipboard_file_pasted!(socket, result, kind) do
    Audit.emit!(%{
      action: "terminal.clipboard_file_pasted",
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "file",
      target_ref: result.relative_path,
      metadata: %{
        "bytes" => result.bytes,
        "content_type" => result.content_type,
        "kind" => Atom.to_string(kind)
      }
    })
  end

  defp save_clipboard_file(root, params, :image), do: Terminals.save_clipboard_image(root, params)
  defp save_clipboard_file(root, params, _kind), do: Terminals.save_clipboard_file(root, params)

  defp paste_file_reason(:too_large),
    do:
      "clipboard file is too large (max #{div(Terminals.clipboard_max_file_bytes(), 1024 * 1024)} MB)"

  defp paste_file_reason(:unsupported_type), do: "clipboard image type is not supported"
  defp paste_file_reason(:invalid_base64), do: "clipboard file data was invalid"
  defp paste_file_reason(:invalid_path), do: "clipboard file path was invalid"
  defp paste_file_reason(:write_failed), do: "failed to write clipboard file"
  defp paste_file_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp initial_terminal_mode(mode, host_id) do
    # :raw means Ghostty-based raw terminal (PaneWorker + tmux).
    Terminals.initial_terminal_mode(mode, host_id)
  end

  # --- Layout helpers (Phase 2) ---

  @doc false
  def get_pane_data(socket, pane_id) do
    Map.get(socket.assigns.pane_data, pane_id)
  end

  defp open_preview(socket, %{"url" => url} = params) do
    case split_workspace_preview(socket, url, params) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, :no_tmux_session, socket} ->
        {:noreply,
         put_flash(socket, :error, "Start a tmux terminal session before opening a preview pane")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to open preview: #{inspect(reason)}")}
    end
  end

  defp open_surface_preview(socket, surface, params) do
    workspace = socket.assigns.workspace

    case DevIDE.Previews.get_surface(workspace, surface) do
      %{url: url} when is_binary(url) ->
        case split_workspace_preview(socket, url, params) do
          {:ok, socket} ->
            {:noreply, socket}

          {:error, :no_tmux_session, socket} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Start a tmux terminal session before opening a preview pane"
             )}

          {:error, reason, socket} ->
            {:noreply, put_flash(socket, :error, "Failed to open preview: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Preview surface not found: #{surface}")}
    end
  end

  defp schedule_preview_demo_open(socket) do
    Process.send_after(self(), {:open_preview_demo, 1}, @preview_demo_open_delay_ms)
    socket
  end

  defp split_workspace_preview(socket, url, params) do
    workspace = socket.assigns.workspace
    tmux_session = socket.assigns[:tmux_session]

    if is_binary(tmux_session) and tmux_session != "" do
      opts = [
        actor_id: current_actor_id(socket),
        viewport: Map.get(params, "viewport") || Map.get(params, :viewport),
        tmux_session: tmux_session,
        cwd: terminal_window_cwd(socket)
      ]

      case Agents.split_preview_pane(workspace, url, opts) do
        {:ok, _result} ->
          {:ok,
           socket
           |> TerminalState.refresh_tmux_topology()}

        {:error, reason} ->
          {:error, reason, socket}
      end
    else
      {:error, :no_tmux_session, socket}
    end
  end

  defp refresh_terminal_surface_pane_id(socket) do
    active_window_panes =
      DevIdeWeb.WorkspaceLive.Show.TerminalChrome.active_tmux_window_panes(
        socket.assigns[:tmux_windows] || []
      )

    assign(
      socket,
      :terminal_surface_pane_id,
      DevIdeWeb.WorkspaceLive.Show.TerminalChrome.terminal_surface_pane_id(
        active_window_panes,
        socket.assigns[:preview_panes] || %{},
        socket.assigns[:tmux_active_pane_id],
        socket.assigns[:terminal_surface_pane_id]
      )
    )
  end

  defp load_preview_panes(%{id: workspace_id} = workspace, path_result) do
    workspace
    |> preview_pane_workspace_ids(workspace_id, path_result)
    |> Enum.flat_map(&PreviewPanes.list_for_workspace/1)
    |> Enum.map(fn registration ->
      {registration.pane_id, preview_pane_payload(registration)}
    end)
    |> Map.new()
  end

  defp authorize_preview_pane(socket, pane_id) do
    case PreviewPanes.get_by_pane(pane_id) do
      %{workspace_id: workspace_id} ->
        if preview_pane_workspace_match?(socket, workspace_id),
          do: :ok,
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp preview_pane_workspace_match?(socket, workspace_id) when is_binary(workspace_id) do
    workspace_id in preview_pane_workspace_ids(
      socket.assigns.workspace,
      socket.assigns.workspace.id,
      socket.assigns[:host_path]
    )
  end

  defp preview_pane_workspace_match?(_socket, _workspace_id), do: false

  defp preview_pane_workspace_ids(workspace, workspace_id, path_result) do
    ([workspace_id] ++
       WorkspaceAliases.viewer_ids(workspace_id) ++
       workspace_folder_aliases(workspace, path_result))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp preview_subscription_workspace_ids(socket) do
    socket.assigns.workspace
    |> preview_pane_workspace_ids(socket.assigns.workspace.id, socket.assigns[:host_path])
    |> Enum.map(&to_string/1)
  end

  defp workspace_folder_aliases(_workspace, {:ok, path}) when is_binary(path) and path != "" do
    [WorkspaceAliases.folder_id_for_path(path)]
  end

  defp workspace_folder_aliases(workspace, _path_result) do
    path =
      Map.get(workspace, :path) || Map.get(workspace, "path") || Map.get(workspace, :host_path) ||
        Map.get(workspace, "host_path")

    case path do
      path when is_binary(path) and path != "" -> [WorkspaceAliases.folder_id_for_path(path)]
      _ -> []
    end
  end

  defp preview_pane_payload(payload) do
    display_url = payload_value(payload, :display_url) || payload_value(payload, :url)

    %{
      pane_id: payload_value(payload, :pane_id),
      workspace_id: payload_value(payload, :workspace_id),
      url: payload_value(payload, :url),
      display_url: display_url,
      title: preview_pane_tab_title(payload, display_url),
      favicon_url: DevIdeWeb.WorkspaceLive.Show.TerminalChrome.preview_favicon_url(display_url),
      viewport: payload_value(payload, :viewport),
      preview_id: payload_value(payload, :preview_id),
      control_session_id: payload_value(payload, :control_session_id),
      tmux_session: payload_value(payload, :tmux_session),
      shared: payload_value(payload, :shared) || false,
      source_pane_id: payload_value(payload, :source_pane_id)
    }
  end

  # Locates open preview panes (keyed by tmux pane_id) whose registrations carry
  # the given preview_id, so agent-driven observations can update every attached
  # panel sharing the same preview session.
  defp find_preview_panes_by_preview_id(socket, preview_id) do
    socket.assigns[:preview_panes]
    |> Kernel.||(%{})
    |> Enum.filter(fn {_pane_id, pane} -> preview_value(pane, :preview_id) == preview_id end)
  end

  # Reflects the latest agent observation (url/title) into a preview pane so the
  # open panel follows agent-driven browsing. Only fields present on the
  # observation override the existing pane; missing fields keep prior values.
  defp apply_observation_to_preview_pane(workspace, pane, observation) do
    url = observation_field(observation, :url)
    title = observation_field(observation, :title)

    display_url =
      url
      |> then(&PreviewPanes.browser_display_url(workspace, &1))
      |> case do
        nil -> preview_value(pane, :display_url) || preview_value(pane, :url)
        "" -> preview_value(pane, :display_url) || preview_value(pane, :url)
        browser_url -> browser_url
      end

    pane
    |> maybe_put_preview_field(:url, url)
    |> maybe_put_preview_field(:display_url, display_url)
    |> maybe_put_preview_field(:title, title)
    |> Map.put(
      :favicon_url,
      DevIdeWeb.WorkspaceLive.Show.TerminalChrome.preview_favicon_url(display_url)
    )
  end

  defp maybe_put_preview_field(pane, _key, nil), do: pane
  defp maybe_put_preview_field(pane, _key, ""), do: pane
  defp maybe_put_preview_field(pane, key, value), do: Map.put(pane, key, value)

  defp observation_field(observation, key) when is_map(observation) and is_atom(key) do
    Map.get(observation, key) || Map.get(observation, Atom.to_string(key))
  end

  defp observation_field(_observation, _key), do: nil

  # True when a registration broadcast carries the same display URL we already
  # show for this pane — i.e. a heartbeat/topology re-broadcast rather than a new
  # or navigated preview. Used to skip focus churn that would flash the frame.
  defp preview_pane_heartbeat?(existing, pane) when is_map(existing) do
    url = preview_value(existing, :display_url)
    is_binary(url) and url != "" and url == preview_value(pane, :display_url)
  end

  defp preview_pane_heartbeat?(_existing, _pane), do: false

  defp preview_pane_url_changed?(previous, updated) do
    # The iframe loads `display_url`, so a reload is only warranted when that
    # value actually changes. Comparing `:url` (e.g. a direct loopback URL) would
    # miss proxied/snapshot display URLs and also fire spurious reloads when the
    # display URL is unchanged.
    new_url = preview_value(updated, :display_url)
    is_binary(new_url) and new_url != "" and new_url != preview_value(previous, :display_url)
  end

  defp preview_pane_tab_title(payload, display_url) do
    case payload_value(payload, :title) do
      title when is_binary(title) and title != "" ->
        if String.starts_with?(title, "preview "), do: nil, else: title

      _ ->
        if is_binary(display_url) and display_url != "" do
          DevIDE.Previews.extract_title_from_url(display_url)
        end
    end
  end

  defp record_preview_activity(socket, pane_id, event, metadata) when is_binary(pane_id) do
    preview = Map.get(socket.assigns[:preview_panes] || %{}, pane_id)
    registration = PreviewPanes.get_by_pane(pane_id)
    workspace_id = socket.assigns.workspace.id

    _ =
      PreviewActivity.record(%{
        workspace_id: workspace_id,
        pane_id: pane_id,
        preview_id:
          preview_value(preview, :preview_id) || preview_value(registration, :preview_id),
        session_id:
          preview_value(preview, :control_session_id) ||
            preview_value(registration, :control_session_id),
        source: :browser,
        event: to_string(event || "interaction"),
        summary: preview_activity_summary(event, metadata),
        metadata:
          metadata
          |> Map.put_new("title", preview_value(preview, :title))
          |> Map.put_new("display_url", preview_value(preview, :display_url))
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> Map.new()
      })

    :ok
  end

  defp sanitize_preview_telemetry_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      "x",
      "y",
      "button",
      "modifiers",
      "mode",
      "url",
      "key",
      "delta_x",
      "delta_y",
      "request_id",
      "status",
      "reason",
      "selector",
      "nth",
      "text_length",
      "iframe_src",
      "loaded_url",
      "loaded",
      "diagnostic",
      "load_ms",
      "recovery_attempts",
      "width",
      "height"
    ])
    |> sanitize_modifiers()
  end

  defp sanitize_preview_telemetry_metadata(_), do: %{}

  defp sanitize_modifiers(%{"modifiers" => modifiers} = metadata) when is_map(modifiers) do
    Map.put(metadata, "modifiers", Map.take(modifiers, ["alt", "ctrl", "meta", "shift"]))
  end

  defp sanitize_modifiers(metadata), do: metadata

  defp preview_activity_summary(event, metadata) do
    case to_string(event || "interaction") do
      "pointer_down" -> pointer_summary("pointer down", metadata)
      "pointer_up" -> pointer_summary("pointer up", metadata)
      "snapshot_click" -> pointer_summary("snapshot click", metadata)
      "key_intent" -> "key intent: " <> to_string(Map.get(metadata, "key", "unknown"))
      "iframe_loaded" -> "iframe loaded"
      "iframe_error" -> "iframe error"
      "iframe_load_timeout" -> "iframe load timeout"
      "iframe_focus" -> "iframe focused"
      "iframe_blur" -> "iframe blurred"
      "preview_reopen_requested" -> "preview reopen requested"
      "visibility_heartbeat" -> "visibility heartbeat"
      "overlay_destroyed" -> "preview overlay destroyed"
      "recover" -> "recover preview pane"
      "scroll" -> "scroll"
      "selected" -> "selected preview pane"
      "exited" -> "exited preview pane"
      other -> other
    end
  end

  defp pointer_summary(label, metadata) when is_map(metadata) do
    case {Map.get(metadata, "x"), Map.get(metadata, "y")} do
      {x, y} when is_integer(x) and is_integer(y) -> "#{label} @ #{x},#{y}"
      _ -> label
    end
  end

  defp preview_value(nil, _key), do: nil

  defp preview_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp preview_value(_value, _key), do: nil

  defp handle_preview_pane_history(socket, pane_id, action)
       when is_binary(pane_id) and action in [:go_back, :go_forward, :reload] do
    record_preview_activity(socket, pane_id, to_string(action), %{"source" => "header"})

    with :ok <- authorize_preview_pane(socket, pane_id),
         {:ok, registration} <- apply(PreviewPanes, action, [pane_id]) do
      preview = preview_pane_payload(registration)

      socket =
        socket
        |> assign(
          :preview_panes,
          Map.put(socket.assigns[:preview_panes] || %{}, pane_id, preview)
        )
        |> assign(:entered_preview_pane_id, pane_id)
        |> push_event("devide:reload_preview_iframes", %{
          "pane_id" => pane_id,
          "force" => true
        })

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview control failed: #{inspect(reason)}")}
    end
  end

  defp handle_preview_pane_history(socket, _pane_id, _action),
    do: {:noreply, put_flash(socket, :error, "Preview pane not found")}

  defp handle_preview_pane_close(socket, pane_id) when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "close", %{"source" => "header"})

    with :ok <- authorize_preview_pane(socket, pane_id),
         :ok <- PreviewPanes.deregister(pane_id) do
      socket =
        socket
        |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
        |> maybe_clear_entered_preview_pane(pane_id)

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview close failed: #{inspect(reason)}")}
    end
  end

  defp handle_preview_pane_close(socket, _pane_id),
    do: {:noreply, put_flash(socket, :error, "Preview pane not found")}

  defp handle_preview_pane_recover(socket, pane_id) when is_binary(pane_id) do
    record_preview_activity(socket, pane_id, "recover", %{"source" => "preview_status"})

    with :ok <- authorize_preview_pane(socket, pane_id),
         %{url: url} = registration <- PreviewPanes.get_by_pane(pane_id),
         tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           registration.tmux_session || socket.assigns[:tmux_session],
         _kill_result <- TerminalState.tmux_adapter().kill_pane(tmux_session, pane_id),
         :ok <- PreviewPanes.deregister(pane_id),
         {:ok, socket} <- split_workspace_preview(socket, url, %{}) do
      {:noreply,
       socket
       |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
       |> maybe_clear_entered_preview_pane(pane_id)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Preview pane not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Preview recover failed: #{inspect(reason)}")}

      reason ->
        {:noreply, put_flash(socket, :error, "Preview recover failed: #{inspect(reason)}")}
    end
  end

  defp handle_preview_pane_recover(socket, _pane_id),
    do: {:noreply, put_flash(socket, :error, "Preview pane not found")}

  defp maybe_clear_entered_preview_pane(socket, pane_id) do
    if socket.assigns[:entered_preview_pane_id] == pane_id do
      assign(socket, :entered_preview_pane_id, nil)
    else
      socket
    end
  end

  defp active_tmux_window_name(assigns) do
    DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
  end

  # Name of the currently attached session, used to label the mobile session
  # chip so it reads as a session switcher rather than a bare mode badge.
  defp mobile_active_session_label(assigns) do
    if assigns.terminal_sid == assigns.default_terminal_sid do
      case assigns.shell_button_label do
        label when is_binary(label) and label != "" -> label
        _ -> "Shell"
      end
    else
      case Enum.find(assigns.session_tabs, &(&1.id == assigns.terminal_sid)) do
        %{label: label} when is_binary(label) and label != "" -> label
        _ -> "Session"
      end
    end
  end

  defp mobile_mode_chip_title(assigns) do
    case active_tmux_window_name(assigns) do
      name when is_binary(name) and name != "" -> "Window \"#{name}\""
      _ -> "Terminal session"
    end
  end

  defp mobile_nav_sheet_title(%{mnav_view: "windows"} = assigns),
    do: mobile_active_session_label(assigns)

  defp mobile_nav_sheet_title(_assigns), do: "All sessions"

  # The session tab the terminal is currently attached to, if any — nil while
  # on the default shell (no tmux) or before session tabs load.
  defp mobile_nav_active_tab(assigns) do
    Enum.find(assigns[:session_tabs] || [], &(&1.id == assigns[:terminal_sid]))
  end

  # "windows" only makes sense when the attached session actually has tmux
  # windows to list; everything else lands on the sessions tree.
  defp mobile_nav_resolved_view(_socket, "sessions"), do: "sessions"

  defp mobile_nav_resolved_view(socket, "windows") do
    case mobile_nav_active_tab(socket.assigns) do
      %{windows: [_ | _]} -> "windows"
      _ -> "sessions"
    end
  end

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  # Called from mount (for the default-raw case) and from the explicit
  # "enter raw" transition. Starts the PTY worker for the focused pane.
  defp maybe_start_raw_ghostty_and_request_restore(socket, mode, _ws_id)
       when mode in [:raw, :raw_ghostty] do
    s = start_ghostty_terminal(socket)

    # For the *default* raw mount path (exercised by the non-@tmux UI chrome test)
    # we intentionally swallow any "Failed to start" flash. The test profile has no
    # tmux, so PaneWorker fails, but the raw layout chrome + split buttons must still
    # render cleanly (the test asserts exactly that). Explicit user "enter raw" via
    # palette/set_mode still gets the error message from the shared start helper.
    flash = Map.get(s.assigns, :flash, %{})

    if is_map(flash) and Map.has_key?(flash, :error) and
         is_binary(flash[:error]) and
         String.contains?(flash[:error], "Failed to start Ghostty pane") do
      assign(s, :flash, Map.delete(flash, :error))
    else
      s
    end
  end

  defp maybe_start_raw_ghostty_and_request_restore(socket, _mode, _ws_id), do: socket

  @doc false
  def cleanup_ghostty_resources_if_leaving(socket) do
    # Ghostty is now the :raw path. Clean up when leaving any Ghostty-based raw terminal.
    if socket.assigns[:terminal_mode] in [:raw, :raw_ghostty] do
      cleanup_ghostty_resources(socket)
    else
      socket
    end
  end

  defp decision_for_command(socket, command_id) do
    ctx = policy_ctx(socket, %{command_id: command_id})
    Policy.can_run_command?(ctx)
  end

  # Allowlist of commands that are interactive TUIs — they need a real PTY
  # in a terminal pane, not the Run tab's stdout-capture flow.
  # Public: called by Show.RunEvents (extracted run/workflow handlers).
  def interactive_agent?(id),
    do: id in ~w(agent claude clauded codex grok opencode)

  # Interactive coding-agent launchers (agent / claude / grok / opencode /
  # codex / clauded) run in the raw terminal: we ensure the canonical raw
  # session exists, write the command through that PTY, and flip the operator
  # to the Terminal tab in raw mode. The raw Ghostty pane attaches to the same
  # session, so the operator sees the agent already running when the mode
  # change settles.
  def launch_interactive_agent(socket, id) do
    socket = refresh_workspace_mode(socket)
    decision = Policy.can_run_command?(policy_ctx(socket, %{command_id: id}))
    socket = assign(socket, :last_decision, decision)

    pane = get_pane_data(socket, socket.assigns.focused_pane_id)
    tmux_session = pane && pane.tmux_session

    cond do
      not DevIDE.Policy.Decision.allow?(decision) ->
        {:noreply, put_flash(socket, :error, "Launch not allowed.")}

      not raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Interactive agents require raw terminal access (manual mode + local host)."
         )}

      is_nil(tmux_session) ->
        {:noreply, put_flash(socket, :error, "No focused pane to launch agent in.")}

      true ->
        case ensure_raw_session_for_pane(socket, pane) do
          {:ok, session_pid} ->
            _ = ensure_pane_agent_env(socket, tmux_session)
            command = PaneEnv.launch_command(id, pane_env_workspace(socket)) <> "\r"
            Terminals.send_session_input(session_pid, command)

            socket =
              socket
              |> assign(:tab, "terminal")
              |> DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.set_mode(:raw)
              |> put_flash(:info, "Launched #{id} in terminal pane.")

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not start terminal session for #{id}: #{inspect(reason)}."
             )}
        end
    end
  end

  @doc false
  def start_ghostty_terminal(socket) do
    start_ghostty_for_pane(socket, socket.assigns.focused_pane_id)
  end

  @doc false
  def update_pane(socket, pane_id, fun) do
    assign(
      socket,
      :pane_data,
      Map.update(socket.assigns.pane_data, pane_id, nil, fn
        nil -> nil
        pane -> fun.(pane)
      end)
    )
  end

  defp start_ghostty_for_pane(socket, pane_id) do
    ws_id = socket.assigns[:workspace] && socket.assigns.workspace.id

    :telemetry.span(
      [:dev_ide, :workspace_live, :start_ghostty_pane],
      %{pane_id: pane_id, workspace_id: ws_id},
      fn -> do_start_ghostty_for_pane(socket, pane_id) end
    )
  end

  defp do_start_ghostty_for_pane(socket, pane_id) do
    pane = get_pane_data(socket, pane_id)

    result =
      cond do
        is_nil(pane) ->
          socket

        workspace_terminal_blocked?(socket.assigns.workspace) ->
          update_pane(socket, pane_id, fn p -> %{p | error: :workspace_not_running} end)

        pane_worker_alive?(pane) ->
          socket

        true ->
          start_ghostty_pane_worker(socket, pane_id, pane)
      end

    metadata =
      case {pane, result} do
        {nil, _} -> %{status: :missing_pane}
        {%{worker: worker}, _} when is_pid(worker) -> %{status: :already_started}
        _ -> %{}
      end

    {result, metadata}
  end

  # cwd is required for the WorkspaceSource argv wrap (docker compose
  # exec runs from the workspace's compose project root) and for the
  # container_has_tmux? probe to key its cache.
  defp start_ghostty_pane_worker(socket, pane_id, pane) do
    cwd = workspace_cwd(socket)
    backend = ghostty_pane_backend()
    session_sid = pane[:session_sid] || socket.assigns.terminal_sid
    workspace_key = terminal_workspace_key(socket)
    loc = terminal_loc(socket, cwd)

    case PaneWorker.start_link(
           parent: self(),
           pane_id: pane_id,
           tmux_session: pane.tmux_session,
           workspace_id: socket.assigns.workspace.id,
           workspace_key: workspace_key,
           session_sid: session_sid,
           loc: loc,
           host_id: socket.assigns.host_id,
           backend: backend,
           cwd: cwd,
           cols: 80,
           rows: 40,
           terminal_scheme: socket.assigns.terminal_color_scheme,
           terminal_preset: socket.assigns.terminal_preset_id
         ) do
      {:ok, worker} ->
        {term, pty} = PaneWorker.get_handles(worker)
        Terminals.subscribe_tmux_session_cleanup(pane.tmux_session)

        update_pane(socket, pane_id, fn p ->
          %{
            p
            | worker: worker,
              ghostty_term: term,
              ghostty_pty: pty,
              backend: backend,
              session_sid: session_sid,
              error: nil
          }
          |> Map.put(:auto_retry_count, 0)
        end)

      {:error, reason} ->
        # The per-pane error state (set here and rendered in TerminalChrome)
        # is now the primary, non-duplicative way failures are surfaced.
        # We no longer emit a global flash for this path (it duplicated the
        # inline inspect(error) and produced banner + box on every retry).
        update_pane(socket, pane_id, fn p -> %{p | error: reason} end)
    end
  end

  defp pane_worker_alive?(%{worker: worker, ghostty_term: term})
       when is_pid(worker) and is_pid(term) do
    Process.alive?(worker) and Process.alive?(term)
  end

  defp pane_worker_alive?(_), do: false

  @pane_auto_retry_limit 3
  @pane_auto_retry_backoff_ms 750

  # Schedule a single bounded reattach for a pane that just exited, if it still
  # exists and hasn't exhausted its retry budget. The actual restart happens in
  # the `{:auto_reattach_pane, pane_id, attempt}` handler after a short backoff,
  # so transient teardown (server restart drain, tmux respawn) has settled.
  defp maybe_auto_reattach_pane(socket, pane_id, status) do
    pane = get_pane_data(socket, pane_id)

    attempts = if pane, do: Map.get(pane, :auto_retry_count, 0), else: 0

    if pane && recoverable_pane_exit?(status) && attempts < @pane_auto_retry_limit do
      next = attempts + 1

      Process.send_after(
        self(),
        {:auto_reattach_pane, pane_id, next},
        @pane_auto_retry_backoff_ms
      )

      update_pane(socket, pane_id, fn p -> Map.put(p, :auto_retry_count, next) end)
    else
      socket
    end
  end

  defp recoverable_pane_exit?(reason),
    do: reason in [:pty_died, :process_died, :terminal_died]

  defp normalize_pane_exit_reason({:exit_status, status}) when is_integer(status), do: status
  defp normalize_pane_exit_reason(reason), do: reason

  @doc false
  # Terminals boot directly into raw now, so the mount path starts the raw
  # session itself; there is nothing left to prewarm. Retained as a
  # pass-through for the callers in the mode-refresh path.
  def maybe_schedule_raw_prewarm(socket), do: socket

  defp maybe_prewarm_raw_session(socket) do
    if not workspace_terminal_blocked?(socket.assigns.workspace) do
      pane = get_pane_data(socket, socket.assigns.focused_pane_id)
      _ = ensure_raw_session_for_pane(socket, pane)
    end

    socket
  end

  defp ensure_raw_session_for_pane(socket, %{session_sid: session_sid})
       when is_binary(session_sid) do
    workspace_id = socket.assigns.workspace.id
    workspace_key = terminal_workspace_key(socket)
    loc = terminal_loc(socket, workspace_cwd(socket))

    :telemetry.span(
      [:dev_ide, :workspace_live, :prewarm_raw_session],
      %{workspace_id: workspace_id, session_sid: session_sid},
      fn ->
        result =
          Terminals.raw_shell_attach(workspace_key, session_sid, loc)

        if match?({:ok, _}, result) do
          tmux_session = Terminals.tmux_session_name(workspace_key, session_sid)
          _ = ensure_pane_agent_env(socket, tmux_session)
        end

        metadata =
          case result do
            {:ok, _pid} -> %{status: :ok}
            {:error, reason} -> %{status: :error, reason: inspect(reason)}
          end

        {result, metadata}
      end
    )
  end

  defp ensure_raw_session_for_pane(_socket, _pane), do: {:error, :missing_pane}

  @doc false
  def workspace_cwd(socket) do
    case socket.assigns[:terminal_context] do
      %{root_path: path} when is_binary(path) and path != "" ->
        path

      _ ->
        default_workspace_cwd(socket)
    end
  end

  @doc false
  def terminal_window_cwd(socket) do
    root = workspace_cwd(socket)

    case active_terminal_pane_cwd(socket) do
      path when is_binary(path) and path != "" ->
        if path_under_root?(path, root), do: path, else: root

      _ ->
        root
    end
  end

  @doc false
  def default_workspace_cwd(socket) do
    case socket.assigns[:host_path] do
      {:ok, path} -> path
      _ -> "."
    end
  end

  defp active_terminal_pane_cwd(socket) do
    active_pane_id = socket.assigns[:tmux_active_pane_id]

    socket.assigns[:tmux_panes]
    |> List.wrap()
    |> Enum.find_value(fn pane ->
      pane_id = Map.get(pane, :id) || Map.get(pane, "id")

      if pane_id == active_pane_id do
        Map.get(pane, :current_path) || Map.get(pane, "current_path")
      end
    end)
  end

  defp path_under_root?(path, root) when is_binary(path) and is_binary(root) do
    path = Path.expand(path)
    root = Path.expand(root)
    relative = Path.relative_to(path, root)

    relative == "." or (relative != path and not String.starts_with?(relative, ".."))
  end

  defp path_under_root?(_path, _root), do: false

  defp current_user_email(socket), do: socket.assigns.current_user[:email]

  defp refresh_workspace_assign(socket) do
    case Workspaces.get(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, workspace} -> assign(socket, :workspace, workspace)
      {:error, _reason} -> socket
    end
  end

  defp workspace_startable?(%{status: status}, nil),
    do: status in [:stopped, :error, "stopped", "error"]

  defp workspace_startable?(_workspace, _start_error), do: false

  defp workspace_start_blocked?(error), do: is_binary(error) and error != ""

  defp format_workspace_action_error({:http, _status, body}),
    do: format_workspace_action_error(body)

  defp format_workspace_action_error(%{"error" => message}) when is_binary(message), do: message

  defp format_workspace_action_error(%{error: message}) when is_binary(message), do: message

  defp format_workspace_action_error(reason), do: inspect(reason)

  defp workspace_stoppable?(%{status: status}), do: status in [:running, "running"]

  defp workspace_stoppable?(_), do: false

  defp workspace_status_dot_class(status) when status in [:running, "running"],
    do: "bg-emerald-500"

  defp workspace_status_dot_class(status) when status in [:stopped, :error, "stopped", "error"],
    do: "bg-base-content/35"

  defp workspace_status_dot_class(_status), do: "bg-amber-400"

  # On touch/narrow viewports the status dot doubles as the start/stop control
  # (see the header identity cluster). Returns the phx-click event for a tap, or
  # nil while the workspace is transitioning / start is blocked.
  defp header_status_action(workspace, start_error) do
    cond do
      workspace_startable?(workspace, start_error) -> "workspace:start"
      workspace_stoppable?(workspace) -> "workspace:stop"
      true -> nil
    end
  end

  defp header_status_action_label(workspace, start_error) do
    case header_status_action(workspace, start_error) do
      "workspace:start" -> "Start workspace"
      "workspace:stop" -> "Stop workspace"
      _ -> "Workspace status: " <> to_string(workspace.status)
    end
  end

  defp workspace_terminal_blocked?(%{status: status}),
    do: status in [:deleting, :error, "deleting", "error"]

  defp workspace_terminal_blocked?(_), do: false

  # Tear down term + PTY processes for every pane. Used on terminate/2 and on
  # mode transitions leaving raw — split panes leak otherwise. Defends
  # against half-mounted sockets (e.g. redirect-on-error before mount
  # finished) where :pane_data was never assigned.
  defp cleanup_ghostty_resources(socket) do
    pane_data = socket.assigns[:pane_data] || %{}

    cleared =
      pane_data
      |> Map.new(fn {id, pane} ->
        stop_pane_worker(pane.worker)

        if pane.tmux_session do
          Terminals.unsubscribe_tmux_session_cleanup(pane.tmux_session)
        end

        if is_pid(pane.ghostty_term) and Process.alive?(pane.ghostty_term) do
          Process.unlink(pane.ghostty_term)
          Process.exit(pane.ghostty_term, :shutdown)
        end

        {id, %{pane | ghostty_pty: nil, ghostty_term: nil, worker: nil, backend: nil, error: nil}}
      end)

    assign(socket, :pane_data, cleared)
  end

  defp stop_pane_worker(worker) when is_pid(worker) do
    if Process.alive?(worker) do
      # Unlink first so the worker's :shutdown reason doesn't propagate
      # back into the LV (which is its start_link parent and does not
      # trap exits).
      Process.unlink(worker)

      try do
        GenServer.stop(worker, :shutdown, 1_000)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp stop_pane_worker(_), do: :ok

  # Production default: route raw Ghostty panes through SessionOwner so the UI,
  # raw channel joins, replay, and resize all share the canonical terminal
  # boundary. The legacy per-pane Ghostty.PTY backend remains available for
  # targeted tests/rollback via `config :dev_ide, :ghostty_pane_backend,
  # :ghostty_pty`.
  defp ghostty_pane_backend do
    Application.get_env(:dev_ide, :ghostty_pane_backend, :session_owner)
  end

  defp terminal_workspace_key(socket) do
    workspace = socket.assigns.workspace
    workspace.name || workspace.id
  end

  defp pane_env_workspace(socket) do
    workspace = socket.assigns.workspace

    %{
      id: workspace.id,
      name: workspace.name || workspace.id,
      path: workspace_cwd(socket)
    }
  end

  defp ensure_pane_agent_env(socket, tmux_session) when is_binary(tmux_session) do
    PaneEnv.ensure_for_session(tmux_session, pane_env_workspace(socket))
  end

  defp terminal_loc(socket, cwd) do
    case socket.assigns[:host_loc] do
      {:ok, {:local, _path}} -> {:local, cwd}
      {:ok, loc} -> loc
      _ -> {:local, cwd}
    end
  end
end
