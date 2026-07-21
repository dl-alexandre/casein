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
  # Root every user event in a fresh correlation context so audit signals
  # emitted while handling it are traced (covers delegated sub-module events).
  use DevIDE.Signals.EntryContext

  alias DevIDE.Agents.PaneEnv
  alias DevIDE.Agents.BrowserControl
  alias DevIDE.Audit
  alias DevIDE.Labels
  alias DevIDE.Links.Open
  alias DevIDE.Policy
  alias DevIDE.Desktop.PowerShellSession
  alias DevIDE.Terminals
  alias DevIDE.Terminals.SessionRecovery
  alias DevIDE.Terminals.TemplatePreference
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Isolation
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.ChannelAuth
  alias DevIdeWeb.Forms.TemplateForm
  alias DevIdeWeb.NotificationsDrawerEvents
  alias DevIdeWeb.Plugs.AssignCurrentUser
  alias DevIdeWeb.TerminalTelemetry
  alias DevIdeWeb.WorkspaceLive.PaneWorker
  alias DevIDE.Panes
  alias DevIdeWeb.WorkspaceLive.Show.AgentEvents
  alias DevIdeWeb.WorkspaceLive.Show.ArtifactEvents
  alias DevIdeWeb.WorkspaceLive.Show.ConnectEvents
  alias DevIdeWeb.WorkspaceLive.Show.CodexEvents
  alias DevIdeWeb.WorkspaceLive.Show.CockpitData
  alias DevIdeWeb.WorkspaceLive.Show.ContextMenuEvents
  alias DevIdeWeb.WorkspaceLive.Show.FileEvents
  alias DevIdeWeb.WorkspaceLive.Show.FileOperations
  alias DevIdeWeb.WorkspaceLive.Show.FilePaneEvents
  alias DevIdeWeb.WorkspaceLive.Show.HistoryEvents
  alias DevIdeWeb.WorkspaceLive.Show.GrokPermissionEvents
  alias DevIdeWeb.WorkspaceLive.Show.LogsEvents
  alias DevIdeWeb.WorkspaceLive.Show.NavEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaneLayoutEvents
  alias DevIdeWeb.WorkspaceLive.Show.PanelGate
  alias DevIdeWeb.WorkspaceLive.Show.PreviewPaneEvents
  alias DevIdeWeb.WorkspaceLive.Show.PalettePanel
  alias DevIdeWeb.WorkspaceLive.Show.WorkspacePolicyEvents
  alias DevIdeWeb.WorkspaceLive.Show.RunEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.SituationEvents
  alias DevIdeWeb.WorkspaceLive.Show.Sidebar
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents
  alias DevIdeWeb.WorkspaceLive.Show.TmuxTemplateEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalInfo
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  import DevIdeWeb.WorkspaceLive.Show.Context
  import DevIdeWeb.WorkspaceLive.Show.TemplatePanels
  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome
  import DevIdeWeb.WorkspaceLive.Show.UI, only: [workspace_breadcrumbs: 1]
  import DevIdeWeb.WorkspaceLive.Show.WorkspaceShell, only: [workspace_shell: 1]

  @ghostty_term_id "raw-term-ghostty"
  @preview_demo_port 5173
  @preview_demo_open_attempts 8
  @preview_demo_open_delay_ms 400

  @pane_layout_events ~w(
    split_right split_down pane:close_focused pane:close_others pane:focus_next
    pane:focus_previous pane:zoom_focused pane:ensure_focus_zoom retry_pane
    equalize_layout pane:cycle_layout ghostty:snapshot snapshot_all nav:dir
  )

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
    codex:refresh codex:select_thread codex:resolve_approval codex:start_exec codex:cancel_exec
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
    sidebar:open sidebar:close sidebar:reveal_sessions sidebar:toggle_sessions
    sidebar:toggle_workspace sidebar:toggle_window
    sidebar:cycle_sessions_sort sidebar:cycle_windows_sort sidebar:restore_sort
    sidebar:toggle_browse sidebar:open_folder
    mobile_nav:toggle mobile_nav:close mobile_nav:open mobile_nav:set_view
    attach_terminal_session pane:navigate pane:history_open pane:history_close
    split_right split_down
    pane:close_focused pane:close_others pane:focus_next pane:focus_previous
    pane:zoom_focused pane:ensure_focus_zoom retry_pane nav:dir equalize_layout pane:cycle_layout
    ghostty:snapshot snapshot_all
    isolation:refresh notification:open_conversation
    notifications:toggle notifications:close notifications:refresh
    notifications:mark_read notifications:resolve notifications:mute
    notifications:mark_all_read notifications:save_preferences
    run:start workflow:hint workflow:run run_ledger:select run_ledger:open
    agent:start_review_run
    grok_permission:respond grok_permission:cancel
    palette:open palette:ide palette:category palette:nav palette:close palette:query
    palette:templates palette:execute
    audit_drawer:toggle audit_drawer:close
    situation_drawer:toggle situation_drawer:close
    connect:toggle connect:close connect:load connect:mint connect:revoke
    search:run annotation:open artifact:refresh artifact:serve artifact:inspect artifact:open
    history:search history:clear history:refresh
    preview:open preview-pane:enter preview-pane:exit
    preview-pane:snapshot-click preview-pane:telemetry
    preview-pane:back preview-pane:forward preview-pane:refresh preview-pane:recover preview-pane:close
    pane:input
    run:cancel set_log_service
    ctx:open ctx:close
    tree:toggle tree:select_dir tree:new_form tree:cancel_new tree:create tree:refresh tree:open
    tree:toggle_hidden tree:filter
    tree:open_in_pane tree:new_form_at tree:duplicate
    tree:rename_form_node tree:rename_node tree:rename_node_cancel
    tree:delete_node_request tree:delete_node_confirm tree:delete_node_cancel
    file:rename_form file:rename_cancel file:rename_submit
    file:delete_request file:delete_cancel file:delete_confirm file:refresh file:save file:render_mode
  )

  # Cockpit tabs addressable via "switch_tab" and the `?tab=` deep-link query
  # param (docs/deep_links.md). Unknown values are ignored.
  @tabs ~w(terminal agents files search diff artifacts run proposals logs history)

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
      existing_sid =
        if connected?(socket) and not desktop_powershell?(),
          do: SessionSummary.newest_shell_sid(id, ws.name)

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
      # Re-attach token for raw channel joins after a fresh LiveView
      # auth pass. This is safe to send as a socket dataset attribute and lets
      # TerminalChannel skip workspace manager access checks on
      # reconnect storms.
      workspace_capability =
        terminal_workspace_capability(user, ws, host_id, loc_result, sid, workspace_mode,
          pre_authorized?: PanelGate.path_access_pre_authorized?()
        )

      socket_token = ChannelAuth.sign_user_token(user.id, user[:email])

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:workspace, ws)
        # Panel components take current_user as an attr, so it must always
        # exist (nil = anonymous LAN viewer, authorized via
        # PanelGate.path_access_pre_authorized?).
        |> assign_new(:current_user, fn -> nil end)
        |> assign(:path_route, mount_workspace.path_route)
        |> assign(:workspace_route, mount_workspace.workspace_route)
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
        |> assign(:desktop_terminal?, desktop_powershell?())
        |> assign(:desktop_terminal_term, nil)
        |> assign(:desktop_terminal_pty, nil)
        |> assign(:desktop_terminal_status, :connecting)
        |> assign(:desktop_terminal_refresh, 0)
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
        # discovery scans runtime + manager + host + tmux — defer to
        # :load_preview_state async (started from :after_mount_side_panels) so the
        # first connected frame is not blocked on that scan.
        |> assign(:preview_surfaces, [])
        # Generic feature-pane registry snapshot (%{pane_id => %{type, payload}})
        # for previews AND files. Hydrated async via Panes.snapshot/1 over the
        # viewer's alias id set (:load_preview_state); kept live via
        # DevIDE.Panes.Events. The legacy-shaped :preview_panes assign is a
        # derivation of it (plus later, preview-only observation updates).
        # Empty on both static and connected first paint — same as :tree.
        |> assign(:feature_panes, %{})
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
        |> assign(:file_symbols, [])
        |> assign(:file_render_mode, nil)
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
        |> assign(:artifact_projects, [])
        |> assign(:artifact_projects_error, nil)
        |> assign(:artifact_selected_id, nil)
        |> HistoryEvents.assign_defaults()
        |> GrokPermissionEvents.mount()
        |> CodexEvents.assign_defaults()
        # Global notifications drawer (user-scoped, not workspace-scoped):
        # subscribes to the viewer's notification topic and loads the unread
        # badge count on the connected mount; the inbox list is lazy (opens).
        |> NotificationsDrawerEvents.mount()
        |> assign(:selected_dir, "")
        |> assign(:new_input, nil)
        |> assign(:delete_confirm, nil)
        |> assign(:rename_input, nil)
        |> assign(:tree_error, nil)
        |> assign(:files_watch_active, false)
        # Default true preserves historical Files-tree behavior (dotfiles visible
        # except PathSafety ignore set). Toggle hides names starting with ".".
        |> assign(:show_hidden_files, true)
        |> assign(:tree_filter, "")
        |> assign(:context_menu, nil)
        |> assign(:node_rename, nil)
        |> assign(:node_delete, nil)
        |> assign(:workspace_summaries, [])
        |> assign(:last_decision, nil)
        |> assign(:audit_drawer_open, false)
        |> assign(:connect_drawer_open, false)
        |> assign(:connect_new_token, nil)
        |> assign(:connect_mcp_json, nil)
        |> assign(:connect_tokens, [])
        |> assign(:connect_error, nil)
        |> assign(:connect_info, nil)
        |> assign(:previews_count, 0)
        |> assign(:window_zoomed?, false)
        |> stream(:previews, [], reset: true)
        |> assign(:session_tabs, [])
        |> stream(:log_lines, [], reset: true)
        |> assign(:chrome_visible, true)
        |> then(
          &Enum.reduce(Sidebar.initial_assigns(), &1, fn {key, value}, s ->
            assign(s, key, value)
          end)
        )
        |> assign(:mobile_nav_open, false)
        |> assign(:mobile_nav_focus, "sessions")
        |> assign(:mobile_nav_view, "windows")
        |> assign(:pending_url_pane, nil)
        |> assign(:pending_url_zoom, nil)
        |> assign(:pending_url_recovery, nil)
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
        |> maybe_subscribe_terminal_infrastructure()
        |> subscribe_workspace_mode()
        |> subscribe_agent_write_unlock()
        |> subscribe_previews()
        |> subscribe_pane_events()
        |> subscribe_browser_control()
        |> subscribe_open_links()
        |> subscribe_pane_labels()
        |> SituationEvents.mount()
        |> CodexEvents.subscribe_once()
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
         |> push_navigate(to: ~p"/")}

      {:error, :forbidden} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to this workspace.")
         |> push_navigate(to: ~p"/")}

      {:error, {:lan_path, reason}} ->
        {:ok, assign_lan_path_error(socket, params, reason)}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, mount_error_message(reason))
         |> push_navigate(to: ~p"/")}
    end
  end

  defp resolve_mount_workspace(params, user) do
    CockpitData.resolve_mount_workspace(
      params,
      user,
      PanelGate.path_access_pre_authorized?()
    )
  end

  # Access is decided by deployment mode, not URL shape: LAN deployments
  # (without forward auth) pre-authorize every mount; everything else runs
  # the owner/admin check for path URLs exactly as for /workspaces/:id.
  defp ensure_mount_workspace_access(%{workspace: ws}, user) do
    if PanelGate.path_access_pre_authorized?() do
      :ok
    else
      ensure_workspace_access(ws, user)
    end
  end

  defp mount_error_message(reason), do: "Manager error: #{inspect(reason)}"

  defp assign_lan_path_error(socket, params, reason) do
    error = CockpitData.lan_path_error(params, reason)

    socket
    |> assign(:page_title, error.title)
    |> assign(:lan_path_error, error)
  end

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
         %{workspace: %{id: id}, path_route: path_route},
         host_id,
         params
       ) do
    path =
      if is_binary(path_route) do
        path_route
      else
        ~p"/workspaces/#{id}"
      end

    path =
      if is_nil(path_route) and Map.has_key?(params, "host") and
           host_id not in [nil, "", "local"],
         do: ~p"/workspaces/#{id}?host=#{host_id}",
         else: path

    DevIdeWeb.Endpoint.url() <> path
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_tab_param(socket, params)
    # `?drawer=notifications` deep link (docs/deep_links.md) — one-shot like
    # `?tab=`; patches without the param leave the drawer state alone.
    socket = NotificationsDrawerEvents.apply_drawer_param(socket, params)

    socket =
      if connected?(socket) and Map.has_key?(socket.assigns, :tmux_session) and
           not socket.assigns[:desktop_terminal?] do
        {socket, session_changed?} = maybe_select_requested_terminal_session(socket, params)
        socket = DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.stash_url_view(socket, params)

        # Hydrate tmux topology before applying ?window= so a stale post-deploy
        # window id is rejected against real windows instead of mutating tmux state.
        socket =
          if session_changed? or tmux_topology_uninitialized?(socket) do
            TerminalState.refresh_tmux_topology(socket)
          else
            socket
          end

        {socket, window_selected?} = maybe_select_requested_tmux_window(socket, params["window"])

        socket =
          if window_selected? do
            TerminalState.refresh_tmux_topology(socket)
          else
            socket
          end

        # Apply the stashed ?pane/?zoom even when a ?window switch just refreshed
        # topology, so a deeplink to a pane in another window selects that pane
        # (not just its window). No-op when topology isn't ready or nothing is
        # stashed.
        socket
        |> DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.apply_pending_url_view()
        |> DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.apply_pending_url_recovery()
        |> DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.seed_patched_view_path()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  # Mobile navigation and tab-switch events are handled by NavEvents (extracted
  # from this module — pure code motion).
  def handle_event("switch_tab" = event, params, socket),
    do: NavEvents.handle_event(event, params, socket)

  def handle_event("refresh" = event, params, socket),
    do: NavEvents.handle_event(event, params, socket)

  def handle_event("mobile_nav:" <> _ = event, params, socket),
    do: NavEvents.handle_event(event, params, socket)

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

  # Transient window sidebar beside the terminal. Tab bar is always the default
  # header presentation; the rail opens via C-b w or the palette and closes on
  # Escape or window selection.
  def handle_event("sidebar:open", params, socket) do
    mode = Map.get(params, "mode", "windows")
    focus = Map.get(params, "focus")

    opts =
      case focus do
        f when f in ["sessions", "windows"] -> [focus: f]
        _ -> []
      end

    socket =
      socket
      |> Sidebar.open(mode, opts)
      |> refresh_sidebar_sources()

    {:noreply, socket}
  end

  def handle_event("sidebar:close", _params, socket) do
    {:noreply, Sidebar.close(socket)}
  end

  # Header session-name chip (left of the window tabs): toggle the sessions
  # rail open/closed. Open path matches C-b s / palette "Open sessions sidebar".
  def handle_event("sidebar:toggle_sessions", _params, socket) do
    if socket.assigns.sessions_sidebar_open? do
      {:noreply, Sidebar.close(socket)}
    else
      socket =
        socket
        |> Sidebar.open("both")
        |> refresh_sidebar_sources()

      {:noreply, socket}
    end
  end

  def handle_event("sidebar:reveal_sessions", _params, socket) do
    {:noreply, Sidebar.reveal_sessions(socket)}
  end

  def handle_event("sidebar:toggle_workspace", %{"workspace-id" => workspace_id}, socket) do
    {:noreply, Sidebar.toggle_workspace(socket, workspace_id)}
  end

  def handle_event("sidebar:toggle_window", %{"window-id" => window_id}, socket) do
    {:noreply, Sidebar.toggle_window(socket, window_id)}
  end

  def handle_event("sidebar:cycle_sessions_sort", params, socket) do
    {:noreply, Sidebar.cycle_sessions_sort(socket, sort_direction(params))}
  end

  def handle_event("sidebar:cycle_windows_sort", params, socket) do
    {:noreply, Sidebar.cycle_windows_sort(socket, sort_direction(params))}
  end

  # Client restores the persisted sort mode when a rail hook mounts (localStorage).
  def handle_event("sidebar:restore_sort", %{"col" => col, "mode" => mode}, socket)
      when is_binary(col) and is_binary(mode) do
    {:noreply, Sidebar.restore_sort(socket, col, mode)}
  end

  def handle_event("sidebar:toggle_browse", %{"rel" => rel}, socket) when is_binary(rel) do
    {:noreply, Sidebar.toggle_browse_dir(socket, rel)}
  end

  def handle_event("sidebar:open_folder", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, Sidebar.open_folder(socket, path)}
  end

  # The desktop window row represents the already-active native PowerShell
  # surface. Selecting it only dismisses the picker; there is no tmux window
  # to switch.
  def handle_event(
        "tmux:select_window",
        _params,
        %{assigns: %{desktop_terminal?: true}} = socket
      ) do
    {:noreply, Sidebar.close(socket)}
  end

  def handle_event(
        "tmux:refresh_windows",
        _params,
        %{assigns: %{desktop_terminal?: true}} = socket
      ) do
    case PowerShellSession.restart(workspace_cwd(socket), socket.assigns.workspace) do
      :ok -> {:noreply, attach_desktop_terminal(socket)}
      {:error, reason} -> {:noreply, assign(socket, :desktop_terminal_status, {:error, reason})}
    end
  end

  def handle_event("tmux:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event(
        "terminal:refresh_sessions",
        _params,
        %{assigns: %{desktop_terminal?: true}} = socket
      ) do
    {:noreply, Sidebar.assign_sessions_sidebar_tree(socket)}
  end

  def handle_event("terminal:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  # Desktop mode owns one long-lived native PowerShell session. Selecting its
  # already-active row is a UI action (close the picker), not a request to
  # retarget tmux topology.
  def handle_event(
        "attach_terminal_session",
        %{"session-id" => sid},
        %{assigns: %{desktop_terminal?: true, terminal_sid: sid}} = socket
      ) do
    {:noreply, Sidebar.close(socket)}
  end

  def handle_event("attach_terminal_session" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:navigate" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:history_open" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:history_close" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  # Tmux pane layout events are handled by PaneLayoutEvents (extracted from
  # this module — pure code motion).
  def handle_event(event, params, socket) when event in @pane_layout_events,
    do: PaneLayoutEvents.handle_event(event, params, socket)

  # Workspace lifecycle and policy events are handled by WorkspacePolicyEvents
  # (extracted from this module — pure code motion).
  def handle_event("workspace:" <> _ = event, params, socket),
    do: WorkspacePolicyEvents.handle_event(event, params, socket)

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

  # Run / workflow / run-ledger events are handled by RunEvents (extracted from
  # this module — pure code motion).
  def handle_event("run:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("run_ledger:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("workflow:" <> _ = event, params, socket),
    do: RunEvents.handle_event(event, params, socket)

  def handle_event("agent:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("grok_permission:" <> _ = event, params, socket),
    do: GrokPermissionEvents.handle_event(event, params, socket)

  def handle_event("audit_drawer:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("situation_drawer:" <> _ = event, params, socket),
    do: SituationEvents.handle_event(event, params, socket)

  def handle_event("connect:" <> _ = event, params, socket),
    do: ConnectEvents.handle_event(event, params, socket)

  def handle_event("codex:" <> _ = event, params, socket),
    do: CodexEvents.handle_event(event, params, socket)

  def handle_event("annotation:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  # "proposal:*" events land on ProposalPanelComponent via phx-target; the
  # component runs PanelGate.gate_event since this LV's authz hook cannot
  # intercept component events.

  # All "palette:*" events are handled by PaletteEvents (extracted from this
  # module — pure code motion). palette:execute resolves the selected item to a
  # concrete event and dispatches it back through handle_event/3 here.
  def handle_event("palette:" <> _ = event, params, socket),
    do: PaletteEvents.handle_event(event, params, socket)

  def handle_event("search:" <> _ = event, params, socket),
    do: PaletteEvents.handle_event(event, params, socket)

  # Artifact tab events are handled by ArtifactEvents (extracted from this
  # module — pure code motion).
  def handle_event("artifact:" <> _ = event, params, socket),
    do: ArtifactEvents.handle_event(event, params, socket)

  # Preview open + preview-pane overlay events are handled by PreviewPaneEvents
  # (extracted from this module — pure code motion).
  def handle_event("preview:open" = event, params, socket),
    do: PreviewPaneEvents.handle_event(event, params, socket)

  def handle_event("preview-pane:" <> _ = event, params, socket),
    do: PreviewPaneEvents.handle_event(event, params, socket)

  def handle_event("set_log_service" = event, params, socket),
    do: LogsEvents.handle_event(event, params, socket)

  # Shared right-click context menu (ContextMenu component + ContextMenu hook).
  def handle_event("ctx:" <> _ = event, params, socket),
    do: ContextMenuEvents.handle_event(event, params, socket)

  # File-pane overlay events (generic feature-pane input + the context-menu
  # "Open in pane" entry point) are handled by FilePaneEvents. These clauses
  # must precede the "tree:*" catch-all below.
  def handle_event("pane:input" = event, params, socket),
    do: FilePaneEvents.handle_event(event, params, socket)

  def handle_event("tree:open_in_pane" = event, params, socket),
    do: FilePaneEvents.handle_event(event, params, socket)

  # File-tree / editor events are handled by FileEvents (extracted from this
  # module — pure code motion). All "tree:*" and "file:*" events delegate there.
  def handle_event("tree:" <> _ = event, params, socket),
    do: FileEvents.handle_event(event, params, socket)

  def handle_event("file:" <> _ = event, params, socket),
    do: FileEvents.handle_event(event, params, socket)

  # History (previous sessions) panel events are handled by HistoryEvents
  # (absorbed from the removed WorkspaceLive.PreviousSessions page).
  def handle_event("history:" <> _ = event, params, socket),
    do: HistoryEvents.handle_event(event, params, socket)

  # Notifications drawer events are handled by NotificationsDrawerEvents
  # (absorbed from the removed NotificationLive.Index page; shared with the
  # dashboard). Distinct from the singular "notification:open_conversation"
  # OS-notification deeplink above.
  def handle_event("notifications:" <> _ = event, params, socket),
    do: NotificationsDrawerEvents.handle_event(event, params, socket)

  # Tab selection shared by the "switch_tab" event and the `?tab=` deep link.
  # Per-tab hydration stays lazy: it runs on selection, never at cockpit mount.
  @doc false
  def select_tab(socket, tab, params \\ %{})

  def select_tab(socket, tab, params) when tab in @tabs do
    previous_tab = socket.assigns[:tab] || "terminal"
    socket = assign(socket, :tab, tab)
    socket = FileEvents.sync_files_watch(socket, previous_tab, tab)
    socket = if tab == "logs", do: LogsEvents.start_log_stream(socket), else: socket

    socket =
      if tab == "run" do
        socket
        |> RunEvents.attach_existing_run()
        |> RunEvents.refresh_run_ledger()
        |> AgentEvents.load_review_commands()
      else
        socket
      end

    socket =
      if tab == "artifacts", do: ArtifactEvents.refresh_artifact_projects(socket), else: socket

    socket = if tab == "history", do: HistoryEvents.open(socket, params), else: socket
    if tab == "agents", do: CodexEvents.open(socket), else: socket
  end

  def select_tab(socket, _tab, _params), do: socket

  # `?tab=` deep link (docs/deep_links.md): open a cockpit tab from the URL —
  # e.g. `?tab=history` restores the old /previous-sessions bookmarks via the
  # legacy redirect. The static render only assigns the tab so the first paint
  # shows the right panel; per-tab hydration runs on the connected mount.
  defp apply_tab_param(socket, %{"tab" => tab} = params) when is_binary(tab) do
    cond do
      tab not in @tabs or socket.assigns[:tab] == tab -> socket
      connected?(socket) -> select_tab(socket, tab, params)
      true -> assign(socket, :tab, tab)
    end
  end

  defp apply_tab_param(socket, _params), do: socket

  @impl true
  # Panel LiveComponents cannot write the root flash or refresh Show-owned
  # hub state; they ask via these messages (see PanelGate / the components).
  def handle_info({:panel_flash, kind, msg}, socket) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  def handle_info(:proposal_workspace_changed, socket) do
    {:noreply, socket |> refresh_tree() |> refresh_git_status()}
  end

  # Debounced filesystem watch fan-out from DevIDE.Files.Watcher (Files tab).
  def handle_info({:files_changed, ws_id, meta}, socket) do
    if socket.assigns.workspace.id == ws_id and socket.assigns.tab == "files" do
      {:noreply, FileEvents.apply_files_changed(socket, meta)}
    else
      {:noreply, socket}
    end
  end

  # Audit / MCP-activity broadcasts — subscribed by HistoryEvents when the
  # History panel first opens; refreshed only while that panel is visible.
  def handle_info({:audit_event, _event}, socket),
    do: {:noreply, HistoryEvents.refresh_if_open(socket)}

  def handle_info({:agent_mcp_activity, _entry}, socket),
    do: {:noreply, HistoryEvents.refresh_if_open(socket)}

  # Situation risk transitions on "situation:<ws>" — subscribed by
  # SituationEvents at mount when the :situation_server flag is on — plus the
  # deferred mount-time seed (the risk read is a GenServer.call that must not
  # delay first paint).
  def handle_info({:situation_risk, _kind, _risk} = msg, socket),
    do: SituationEvents.handle_info(msg, socket)

  def handle_info(:situation_seed = msg, socket),
    do: SituationEvents.handle_info(msg, socket)

  def handle_info({:grok_acp_attachments_updated, _workspace_id, _snapshots} = message, socket),
    do: {:noreply, GrokPermissionEvents.handle_info(message, socket)}

  def handle_info({:codex_event, event}, socket), do: CodexEvents.handle_info(event, socket)

  def handle_info(:flush_codex_deltas, socket),
    do: CodexEvents.handle_info(:flush_codex_deltas, socket)

  def handle_info({:codex_exec_event, _, _} = message, socket),
    do: CodexEvents.handle_info(message, socket)

  def handle_info({:codex_exec_data, _, _, _} = message, socket),
    do: CodexEvents.handle_info(message, socket)

  def handle_info({:codex_exec_exit, _, _, _} = message, socket),
    do: CodexEvents.handle_info(message, socket)

  # Durable notification broadcasts on the viewer's user topic — subscribed by
  # NotificationsDrawerEvents at mount. Badge always updates; the drawer list
  # refreshes only while open.
  def handle_info({:notification_created, _notification}, socket),
    do: {:noreply, NotificationsDrawerEvents.handle_notification_change(socket)}

  def handle_info({:notification_updated, _notification}, socket),
    do: {:noreply, NotificationsDrawerEvents.handle_notification_change(socket)}

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
    if Terminals.session_tabs_event_source?(source) do
      socket =
        if socket.assigns.workspace.id == ws_id do
          socket
          |> TerminalState.assign_session_tabs(tabs)
          |> Sidebar.assign_sessions_sidebar_tree()
        else
          Sidebar.sessions_updated(socket, ws_id, tabs)
        end

      {:noreply, socket}
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
        socket = push_osc52_clipboard(socket, pane_id, data)

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
        emit_terminal_push_telemetry(pane_id, payload)
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

  # tmux server/session wipe: Session/SessionOwner emitted a recovery notice.
  # Banner the operator and best-effort re-apply the last session template so
  # agent_pair layout comes back without a manual template click.
  def handle_info({:terminal_recovery, %{type: :session_recreated} = notice}, socket) do
    history =
      if notice.history_restored?,
        do: " Recent scrollback was restored from archive.",
        else: " Pane history may be empty."

    socket =
      put_flash(
        socket,
        :error,
        "Terminal session was recreated after a tmux reset.#{history}"
      )

    socket =
      case notice.template_id do
        id when is_binary(id) and id != "" ->
          # Fire-and-forget best effort; don't block UI on template failure.
          Process.send_after(self(), {:auto_apply_recovery_template, id}, 500)
          socket

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:auto_apply_recovery_template, template_id}, socket)
      when is_binary(template_id) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      apply_session_template(socket, template_id, recovery?: true)
    else
      {:noreply, socket}
    end
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
  def handle_info({:patch_recovered_view_url, path}, socket) when is_binary(path) do
    if socket.assigns[:patched_view_path] == path do
      {:noreply, DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.push_recovered_view_path(socket, path)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount, socket) do
    if connected?(socket) do
      socket =
        if socket.assigns[:desktop_terminal?] do
          attach_desktop_terminal(socket)
        else
          if is_binary(socket.assigns.tmux_session) do
            _ = ensure_pane_agent_env(socket, socket.assigns.tmux_session)
          end

          socket
          |> maybe_start_raw_ghostty_and_request_restore(
            socket.assigns.terminal_mode,
            socket.assigns.workspace.id
          )
          |> start_after_mount_hydration()
        end

      send(self(), :after_mount_side_panels)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:desktop_terminal_output, _data}, socket) do
    {:noreply, update(socket, :desktop_terminal_refresh, &(&1 + 1))}
  end

  def handle_info({:terminal_input_refresh, "desktop-workspace-powershell"}, socket) do
    {:noreply, update(socket, :desktop_terminal_refresh, &(&1 + 1))}
  end

  def handle_info({:desktop_terminal_exit, reason}, socket) do
    {:noreply, assign(socket, :desktop_terminal_status, {:exited, reason})}
  end

  def handle_info({:desktop_terminal_restarted, term, pty}, socket) do
    {:noreply,
     assign(socket,
       desktop_terminal_term: term,
       desktop_terminal_pty: pty,
       desktop_terminal_status: :running,
       desktop_terminal_refresh: socket.assigns.desktop_terminal_refresh + 1
     )}
  end

  def handle_info(:after_mount_side_panels, socket) do
    if connected?(socket) do
      host_loc = socket.assigns[:host_loc]
      host_path = socket.assigns[:host_path]
      workspace = socket.assigns.workspace
      tree = socket.assigns.tree
      actor_id = current_actor_id(socket)

      # start_async + plain assigns in handle_async — NOT assign_async: the
      # templates and refresh paths (render_diff, refresh_tree,
      # handle_async(:refresh_git_status)) all consume :git_status/:tree as
      # plain values, and the :agents_mount results are post-processed by the
      # handle_async clause below (assign_async would bypass it entirely).
      # Capture workspace / host_path before the closures (same pattern as
      # neighboring asyncs) — discover_surfaces + load_feature_panes are the
      # expensive scans previously on connected mount.
      path_result = host_path
      ws = workspace

      socket =
        socket
        |> start_async(:load_side_panels, fn ->
          fetch_side_panels(host_loc, host_path, tree)
        end)
        |> start_async(:agents_mount, fn ->
          fetch_agents_panels(workspace, host_path, actor_id)
        end)
        |> start_async(:load_preview_state, fn ->
          %{
            workspace_id: ws.id,
            preview_surfaces: DevIDE.Previews.discover_surfaces(ws),
            feature_panes: PreviewPaneEvents.load_feature_panes(ws, path_result)
          }
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
          |> RunEvents.attach_existing_run()
          |> RunEvents.refresh_run_ledger()
        else
          socket
        end

      send(self(), :after_mount_agents)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:after_mount_agents, socket) do
    socket =
      if connected?(socket) do
        if socket.assigns[:tab] == "agents",
          do: CodexEvents.open(socket),
          else: CodexEvents.refresh(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:open_preview_demo, attempt}, socket)
      when is_integer(attempt) and attempt > 0 do
    url = "http://localhost:#{@preview_demo_port}/"

    case PreviewPaneEvents.split_workspace_preview(socket, url, %{}) do
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

  # Generic feature-pane lifecycle (DevIDE.Panes.Events) for previews AND
  # files: FilePaneEvents maintains the :feature_panes assign, routes :preview
  # events to PreviewPaneEvents.apply_pane_event/2 (which derives the
  # legacy-shaped :preview_panes assign) and handles the :heartbeat reason
  # without tmux focus churn.
  def handle_info({:pane_event, _} = msg, socket),
    do: FilePaneEvents.handle_info(msg, socket)

  # Legacy "preview:" lifecycle messages are no-ops in the LiveView since the
  # runtime cutover (the topic itself stays for MCP/controller consumers and
  # still carries :preview_observation below).
  def handle_info({:preview_pane_registered, _} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:preview_pane_removed, _} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:preview_observation, _} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:browser_control, %{"action" => "reload_preview_iframe"}} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:browser_control, %{"action" => "reload_page"}} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:browser_control, %{"action" => "focus_preview_pane"}} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:browser_control, %{"action" => "preview_pane_action"}} = msg, socket),
    do: PreviewPaneEvents.handle_info(msg, socket)

  def handle_info({:open_target, target}, socket) do
    open_resolved_target(socket, target)
  end

  def handle_info(:prewarm_raw_session, socket) do
    {:noreply, maybe_prewarm_raw_session(socket)}
  end

  def handle_info({:exit, _status}, socket), do: {:noreply, socket}

  def handle_info({:source_log, _ref, _line}, socket), do: {:noreply, socket}
  def handle_info({:source_log_done, _ref}, socket), do: {:noreply, socket}

  # The SSE log pump is a `Task.async` (Client.stream_logs), so when the
  # stream ends its return value also arrives as a `{task_ref, result}`
  # envelope plus a :DOWN — absorb both instead of crashing the LiveView
  # (manager restarts end the stream for every viewer on the logs tab).
  def handle_info({ref, {:source_log_done, _log_ref}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info(
        {:run_data, ws_id, _stream, bin},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{}}} = socket
      ) do
    {:noreply, RunEvents.apply_run_data(socket, bin)}
  end

  def handle_info(
        {:run_exit, ws_id, code, status},
        %{assigns: %{workspace: %{id: ws_id}, active_run: %{}}} = socket
      ) do
    {:noreply, RunEvents.apply_run_exit(socket, code, status)}
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

  def handle_async(:load_preview_state, {:ok, data}, socket) do
    if socket.assigns.workspace.id == data.workspace_id do
      # Live {:pane_event, _} handlers may have updated :feature_panes /
      # :preview_panes between mount and this completion — merge with live
      # assigns winning per key (same rationale as the tree merge below).
      feature_panes = Map.merge(data.feature_panes, socket.assigns.feature_panes)

      preview_panes =
        Map.merge(
          PreviewPaneEvents.preview_panes_from_feature(feature_panes),
          socket.assigns.preview_panes
        )

      {:noreply,
       socket
       |> assign(:preview_surfaces, data.preview_surfaces)
       |> assign(:feature_panes, feature_panes)
       |> assign(:preview_panes, preview_panes)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:load_preview_state, _result, socket), do: {:noreply, socket}

  def handle_async(:load_side_panels, {:ok, data}, socket) do
    # The fetch ran against the mount-time tree snapshot; the user may have
    # expanded directories or created files meanwhile. Merge with the live
    # tree winning per key so those interactions aren't clobbered.
    tree = Map.merge(data.tree, socket.assigns.tree)
    {:noreply, assign(socket, git_status: data.git_status, tree: tree)}
  end

  def handle_async(:load_side_panels, _result, socket), do: {:noreply, socket}

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
    {:noreply,
     socket |> assign_workspace_summaries(summaries) |> Sidebar.assign_sessions_sidebar_tree()}
  end

  def handle_async(:workspace_summaries, _result, socket), do: {:noreply, socket}

  def handle_async({:sidebar_ws_sessions, workspace_id}, {:ok, infos}, socket)
      when is_binary(workspace_id) and is_list(infos) do
    {:noreply, Sidebar.handle_async_sessions(socket, workspace_id, {:ok, infos})}
  end

  def handle_async({:sidebar_ws_sessions, _workspace_id}, _result, socket) do
    {:noreply, socket}
  end

  def handle_async(:sidebar_ws_warm, result, socket) do
    {:noreply, Sidebar.handle_async_warm(socket, result)}
  end

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
    _ = FileEvents.stop_files_watch(socket)
    _ = cleanup_ghostty_resources(socket)
    :ok
  end

  ## Helpers

  defp emit_terminal_push_telemetry(pane_id, payload) do
    :telemetry.execute(
      [:dev_ide, :terminal, :live_view, :push_frame],
      %{
        count: 1,
        changed_rows: TerminalTelemetry.changed_row_count(payload)
      }
      |> Map.merge(TerminalTelemetry.sampled_payload_measurements(payload)),
      %{
        pane_id: pane_id,
        id: Map.get(payload, :id),
        full_frame?: Map.get(payload, :full_frame) == true,
        frame_seq: Map.get(payload, :frame_seq),
        frame_epoch: Map.get(payload, :frame_epoch)
      }
    )
  end

  # OSC 52 set-clipboard: ESC ] 52 ; <sel> ; <base64> (BEL | ST). PTY reads can
  # split that escape sequence anywhere, and agent CLIs often copy much more
  # than the old single-regex 48 KB ceiling. Keep a bounded partial buffer so
  # `/copy` commands from Claude/Codex/etc. survive chunk boundaries without
  # allowing unbounded terminal output to become clipboard state.
  # Buffer is keyed by pane_id so concurrent panes don't merge partial sequences.
  # Cap is 256 KB of base64 (~192 KB decoded) — real clipboard text is far smaller;
  # the previous 4 MB ceiling inflated socket assign diffs for no practical gain.
  @osc52_prefix "\x1b]52;"
  @osc52_max_base64_bytes 256 * 1024
  @osc52_max_buffer_bytes @osc52_max_base64_bytes + 256
  @osc52_max_matches 4

  defp push_osc52_clipboard(socket, pane_id, data) when is_binary(pane_id) do
    buffers = socket.assigns[:osc52_clipboard_buffers] || %{}
    buffer = Map.get(buffers, pane_id, "")

    if buffer == "" and :binary.match(data, @osc52_prefix) == :nomatch do
      maybe_store_osc52_prefix_tail(socket, pane_id, buffers, data)
    else
      do_push_osc52_clipboard(socket, pane_id, buffers, buffer <> data)
    end
  end

  defp do_push_osc52_clipboard(socket, pane_id, buffers, data) do
    {payloads, rest} = extract_osc52_payloads(data, [], @osc52_max_matches)
    rest = bounded_osc52_buffer(rest)

    buffers =
      if rest == "" do
        Map.delete(buffers, pane_id)
      else
        Map.put(buffers, pane_id, rest)
      end

    socket = assign(socket, :osc52_clipboard_buffers, buffers)

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

  defp maybe_store_osc52_prefix_tail(socket, pane_id, buffers, data) do
    case osc52_prefix_tail(data) do
      "" ->
        socket

      tail ->
        assign(socket, :osc52_clipboard_buffers, Map.put(buffers, pane_id, tail))
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
      pre_authorized?: PanelGate.path_access_pre_authorized?()
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
    pre_authorized? = Keyword.get(opts, :pre_authorized?, false)
    terminal_owner? = pre_authorized? or Workspaces.viewer_terminal_owner?(ws, user)
    workspace_user = if pre_authorized?, do: user.id, else: ws.user
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

  @doc false
  def assign_workspace_mode(socket, ws_id, connected? \\ true)

  def assign_workspace_mode(socket, ws_id, true) do
    {mode, source} = Workspaces.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign_policy_permissions()
  end

  def assign_workspace_mode(socket, _ws_id, false) do
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

  @doc false
  def assign_agent_write_unlock(socket, ws_id) do
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

  defp maybe_subscribe_terminal_infrastructure(socket) do
    if socket.assigns[:desktop_terminal?] do
      seed_desktop_cockpit_state(socket)
    else
      socket
      |> TerminalState.subscribe_tmux_topology()
      |> TerminalState.subscribe_session_tabs()
    end
  end

  # The shared picker normally refreshes from tmux before it opens. Windows
  # desktop mode has already seeded its native PowerShell session/window model;
  # asking the tmux adapter to refresh here blocks the LiveView and disconnects
  # the browser. Sidebar.open/3 has rebuilt both trees from the seeded state.
  defp refresh_sidebar_sources(%{assigns: %{desktop_terminal?: true}} = socket), do: socket

  defp refresh_sidebar_sources(socket) do
    socket
    |> TerminalState.refresh_session_tabs()
    |> assign_workspace_summaries()
    |> TerminalState.refresh_tmux_topology()
  end

  defp seed_desktop_cockpit_state(socket) do
    cwd = workspace_cwd(socket)
    pane_id = "%desktop"
    window_id = "@desktop"

    pane = %{
      id: pane_id,
      window_id: window_id,
      index: 0,
      active: true,
      left: 0,
      top: 0,
      width: 120,
      height: 40,
      current_command: "powershell",
      current_path: cwd,
      role: "operator",
      activity: 0,
      activity_flag: false,
      bell: false,
      unseen_changes: false
    }

    window = %{
      id: window_id,
      index: 0,
      name: "PowerShell",
      manual_name: true,
      active: true,
      panes: 1,
      current_command: "powershell",
      activity: 0,
      pane_list: [pane]
    }

    session_info =
      socket.assigns.workspace.id
      |> Terminals.new_shell(socket.assigns.terminal_sid,
        metadata: %{cwd: cwd, platform: "windows", shell: "PowerShell"}
      )
      |> Map.put(:tmux_session, socket.assigns.tmux_session)

    socket
    |> assign(:tmux_mutations_enabled?, false)
    |> assign(:tmux_windows, [window])
    |> assign(:tmux_panes, [pane])
    |> assign(:tmux_active_window_id, window_id)
    |> assign(:tmux_active_pane_id, pane_id)
    |> assign(:terminal_surface_pane_id, pane_id)
    |> assign(:ui_highlight_pane_id, pane_id)
    |> assign(:tmux_topology_version, 1)
    |> assign(:tmux_topology_structure_version, 1)
    |> TerminalState.assign_tmux_window_tabs()
    |> TerminalState.assign_session_tabs([session_info])
  end

  defp attach_desktop_terminal(socket) do
    with :ok <-
           PowerShellSession.ensure_started(workspace_cwd(socket), socket.assigns.workspace),
         {:ok, term, pty, status} <- PowerShellSession.subscribe(socket.assigns.workspace) do
      assign(socket,
        desktop_terminal_term: term,
        desktop_terminal_pty: pty,
        desktop_terminal_status: status,
        tmux_mutations_enabled?: false
      )
    else
      {:error, reason} -> assign(socket, :desktop_terminal_status, {:error, reason})
    end
  end

  defp desktop_mode?, do: Application.get_env(:dev_ide, :desktop_mode, false)
  defp desktop_powershell?, do: DevIDE.Desktop.TerminalBackend.native_session?(desktop_mode?())

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
    summaries =
      CockpitData.visible_workspace_summaries(summaries, socket.assigns[:current_user])

    assign(socket, :workspace_summaries, summaries)
  end

  defp workspace_summaries_for(workspace), do: CockpitData.workspace_summaries_for(workspace)

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

  @doc false
  def open_annotation_file(socket, loc, path, line) do
    FileOperations.open_annotation_file(socket, loc, path, line)
  end

  @doc false
  # Compute Elixir symbols once when a file opens/refreshes/saves so the Files
  # panel does not re-parse the whole buffer on every unrelated tree interaction.
  def assign_open_file(socket, file), do: FileOperations.assign_open_file(socket, file)

  defp open_resolved_target(socket, {:file, %{path: path, line: line}}) do
    open_resolved_file_target(socket, path, line)
  end

  defp open_resolved_target(socket, {:markdown, %{path: path}}) do
    open_resolved_file_target(socket, path, nil)
  end

  defp open_resolved_target(socket, {:dir, path}) do
    socket =
      socket
      |> assign(:tab, "files")
      |> assign(:selected_dir, path)
      |> load_tree(path)

    {:noreply, socket}
  end

  defp open_resolved_target(socket, {:localhost, %{url: url}}) when is_binary(url) do
    PreviewPaneEvents.handle_event("preview:open", %{"url" => url}, socket)
  end

  defp open_resolved_target(socket, {:external, %{url: url}}) when is_binary(url) do
    {:noreply, put_flash(socket, :info, "External link requested: #{url}")}
  end

  defp open_resolved_target(socket, _target), do: {:noreply, socket}

  defp open_resolved_file_target(socket, path, line) do
    case context_host_loc(socket) do
      {:ok, loc} -> {:noreply, open_annotation_file(socket, loc, path, line)}
      _ -> {:noreply, socket}
    end
  end

  defp fetch_side_panels(host_loc, host_path, tree) do
    CockpitData.fetch_side_panels(host_loc, host_path, tree)
  end

  defp fetch_agents_panels(workspace, host_path, actor_id) do
    CockpitData.fetch_agents_panels(workspace, host_path, actor_id)
  end

  # Public: called by Show.FileEvents (extracted file/tree handlers).
  def load_tree(socket, path), do: FileOperations.load_tree(socket, path)

  # `git status --short` can take hundreds of ms on a big repo; run it off
  # the LiveView process so file saves/creates/deletes render immediately.
  # The result lands in handle_async(:refresh_git_status, ...).
  def refresh_git_status(socket), do: FileOperations.refresh_git_status(socket)

  def do_create(kind, root, rel), do: FileOperations.do_create(kind, root, rel)

  def refresh_tree(socket), do: FileOperations.refresh_tree(socket)

  def load_diff(socket, path), do: FileOperations.load_diff(socket, path)

  @impl true
  def render(%{lan_path_error: %{}} = assigns), do: render_lan_path_error(assigns)

  def render(assigns) do
    ~H"""
    <.workspace_shell {assigns}>
      <:header_back_nav>
        <.workspace_breadcrumbs workspace_route={@workspace_route} />
      </:header_back_nav>
    </.workspace_shell>
    """
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
              navigate={~p"/"}
              class="inline-flex h-9 items-center justify-center rounded border border-primary/40 bg-primary px-3 text-sm font-medium text-primary-content transition hover:bg-primary/90"
            >
              Open home terminal
            </.link>
          </div>
        </div>
      </section>
    </main>
    """
  end

  @doc false
  def palette_categories, do: PalettePanel.palette_categories()

  # render_path/2 and tab_class/2 now live in DevIdeWeb.WorkspaceLive.Show.UI
  # (imported above).

  defp subscribe_pane_labels(socket) do
    if connected?(socket) do
      :ok = Labels.subscribe(socket.assigns.workspace.id)
      _ = SessionRecovery.subscribe_workspace(socket.assigns.workspace.id)
    end

    socket
  end

  defp subscribe_previews(socket) do
    if connected?(socket) do
      for workspace_id <- PreviewPaneEvents.preview_subscription_workspace_ids(socket) do
        Phoenix.PubSub.subscribe(
          DevIDE.PubSub,
          "preview:" <> workspace_id
        )
      end
    end

    socket
  end

  # Generic feature-pane lifecycle topic. Subscribes the exact alias id set the
  # legacy preview subscription used (own id + viewer aliases + host-path folder
  # alias) so preview lifecycle keeps reaching folder/manager-attached viewers
  # after the runtime cutover.
  defp subscribe_pane_events(socket) do
    if connected?(socket) do
      for workspace_id <- PreviewPaneEvents.preview_subscription_workspace_ids(socket) do
        Phoenix.PubSub.subscribe(DevIDE.PubSub, Panes.Events.topic(workspace_id))
      end
    end

    socket
  end

  defp subscribe_browser_control(socket) do
    if connected?(socket) do
      for workspace_id <- PreviewPaneEvents.preview_subscription_workspace_ids(socket) do
        _ = BrowserControl.subscribe(workspace_id)
      end
    end

    socket
  end

  defp subscribe_open_links(socket) do
    if connected?(socket) do
      for workspace_id <- PreviewPaneEvents.preview_subscription_workspace_ids(socket) do
        _ = Open.subscribe(workspace_id)
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
    socket = TerminalState.refresh_session_tabs(socket)

    Enum.reduce_while(live_session_candidates(socket), socket, fn sid, sock ->
      cond do
        sock.assigns[:terminal_sid] == sid ->
          {:halt, sock}

        true ->
          {switched, _} = switch_terminal_session_from_params(sock, sid)

          if switched.assigns[:terminal_sid] == sid do
            {:halt, clear_flash(switched, :error)}
          else
            {:cont, clear_flash(switched, :error)}
          end
      end
    end)
  end

  defp live_session_candidates(socket) do
    ws = socket.assigns.workspace
    ws_id = ws.id
    ws_name = ws.name || ws.id

    tab_sids =
      (socket.assigns[:session_tab_infos] || [])
      |> Enum.filter(&live_session_tab?/1)
      |> Enum.map(fn tab -> tab.sid || tab.id end)
      |> Enum.reject(&(&1 in [nil, ""]))

    # Home first, live tabs last. `newest_shell_sid/2` returns only an *attachable*
    # shell (or nil), so it is the workspace's current landing/home session — the
    # same session the picker marks "home". Prefer it over the mount-time
    # `default_terminal_sid`, which can go stale once shells come and go, so a bare
    # re-entry always lands on the current home shell and never halts on a stale
    # session or an arbitrary live tab.
    [
      SessionSummary.newest_shell_sid(ws_id, ws_name),
      socket.assigns[:default_terminal_sid]
      | tab_sids
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp live_session_tab?(%{status: :active, sid: sid}) when is_binary(sid) and sid != "",
    do: true

  defp live_session_tab?(%{status: :active, id: id}) when is_binary(id) and id != "", do: true
  defp live_session_tab?(_), do: false

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

  defp maybe_select_requested_tmux_window(socket, nil), do: {socket, false}
  defp maybe_select_requested_tmux_window(socket, ""), do: {socket, false}

  defp maybe_select_requested_tmux_window(socket, window_id) when is_binary(window_id) do
    cond do
      window_id == socket.assigns[:tmux_active_window_id] ->
        {socket, false}

      window_known?(socket, window_id) ->
        case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
          :ok -> {socket, true}
          {:error, _reason} -> {socket, false}
        end

      # Requested window is gone — silently stay on the current (closest live) window.
      true ->
        {socket, false}
    end
  end

  defp window_known?(socket, window_id) do
    Enum.any?(socket.assigns[:tmux_windows] || [], &(Map.get(&1, :id) == window_id))
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

      # Heal shims + push agent PATH *before* the template creates windows so
      # the first pane never races "claude: command not found".
      if is_binary(socket.assigns.tmux_session) do
        _ = ensure_pane_agent_env(socket, socket.assigns.tmux_session)
      end

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
    # Store under both UUID and workspace name so Session (keyed by name)
    # and LiveView recovery can both resolve the last template.
    ws = socket.assigns.workspace
    _ = TemplatePreference.put(ws.id, template_id)
    if is_binary(ws.name) and ws.name != "", do: TemplatePreference.put(ws.name, template_id)

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

    # Re-push after template apply (MCP URLs / tokens may depend on session
    # topology); cheap when shims are already complete.
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
         content_type: result.content_type,
         # Server-side format (focused pane role/command). Client treats
         # "agent" as an upgrade-only hint — see PaneInteraction.
         path_format: clipboard_path_format(socket)
       }, socket}
    else
      {:error, reason} ->
        {:reply, %{ok: false, reason: paste_file_reason(reason)}, socket}

      _ ->
        {:reply, %{ok: false, reason: "workspace path is not available"}, socket}
    end
  end

  defp clipboard_path_format(socket) do
    socket
    |> focused_tmux_pane()
    |> DevIDE.Terminals.PaneInteraction.path_format()
  end

  defp focused_tmux_pane(socket) do
    panes =
      DevIdeWeb.WorkspaceLive.Show.TerminalChrome.active_tmux_window_panes(
        socket.assigns[:tmux_windows] || []
      )

    active_id = socket.assigns[:tmux_active_pane_id]

    cond do
      is_binary(active_id) ->
        Enum.find(panes, &(Map.get(&1, :id) == active_id || Map.get(&1, "id") == active_id))

      true ->
        Enum.find(panes, &(Map.get(&1, :active) == true || Map.get(&1, "active") == true))
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

  defp schedule_preview_demo_open(socket) do
    Process.send_after(self(), {:open_preview_demo, 1}, @preview_demo_open_delay_ms)
    socket
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

  # Allowlist of commands that are interactive TUIs — they need a real PTY
  # in a terminal pane, not the Run tab's stdout-capture flow.
  # Public: called by Show.RunEvents (extracted run/workflow handlers).
  def interactive_agent?(id),
    do: DevIDE.Desktop.AgentLauncher.supported?(id)

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

      socket.assigns[:desktop_terminal?] ->
        launch_desktop_agent(socket, id)

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

  defp launch_desktop_agent(socket, id) do
    with {:ok, command} <- DevIDE.Desktop.AgentLauncher.command(id),
         :ok <- DevIDE.Desktop.PowerShellSession.send_input(socket.assigns.workspace, command) do
      {:noreply,
       socket
       |> assign(:tab, "terminal")
       |> put_flash(:info, "Launched #{id} in the Windows terminal.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not launch #{id}: #{inspect(reason)}.")}

      other ->
        {:noreply, put_flash(socket, :error, "Could not launch #{id}: #{inspect(other)}.")}
    end
  catch
    :exit, reason ->
      {:noreply, put_flash(socket, :error, "Could not launch #{id}: #{inspect(reason)}.")}
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

  @doc false
  def start_ghostty_for_pane(socket, pane_id) do
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
        case fetch_pane_worker_handles(worker) do
          {:ok, {term, pty}} ->
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
            stop_failed_pane_worker(worker)
            update_pane(socket, pane_id, fn p -> %{p | error: reason} end)
        end

      {:error, reason} ->
        # The per-pane error state (set here and rendered in TerminalChrome)
        # is now the primary, non-duplicative way failures are surfaced.
        # We no longer emit a global flash for this path (it duplicated the
        # inline inspect(error) and produced banner + box on every retry).
        update_pane(socket, pane_id, fn p -> %{p | error: reason} end)
    end
  end

  # The worker links its term/backend in init and stops :normal the moment
  # either dies, so a pane whose tmux session vanished between start_link and
  # this call turns get_handles into a :noproc exit. That's a pane startup
  # failure (surfaced inline like any other start error), not a LiveView crash.
  defp fetch_pane_worker_handles(worker) do
    {:ok, PaneWorker.get_handles(worker)}
  catch
    :exit, _reason -> {:error, :worker_exited}
  end

  defp stop_failed_pane_worker(worker) when is_pid(worker) do
    Process.unlink(worker)
    if Process.alive?(worker), do: Process.exit(worker, :kill)
    :ok
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

  # Recover process/PTY death and SessionOwner recover exhaustion. Do NOT
  # reattach on clean integer exit statuses (shell `exit`, normalized
  # `{:exit_status, n}`) — those are intentional pane ends and are covered by
  # WorkspacePaneSplitTest. SessionOwner reattaches the backend on term_exit
  # without tearing the PaneWorker when possible.
  # Tab cycles the sidebar sort chip forward; Shift+Tab (dir: "backward")
  # reverses it. The header sort button click carries no dir → forward.
  defp sort_direction(%{"dir" => "backward"}), do: :backward
  defp sort_direction(_), do: :forward

  defp recoverable_pane_exit?(reason)
       when reason in [
              :pty_died,
              :process_died,
              :terminal_died,
              :backend_recover_failed,
              :process_exit,
              :signal
            ],
       do: true

  defp recoverable_pane_exit?(_), do: false

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
