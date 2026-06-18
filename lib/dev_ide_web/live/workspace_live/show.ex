defmodule DevIdeWeb.WorkspaceLive.Show do
  use DevIdeWeb, :live_view

  alias DevIDE.Agents
  alias DevIDE.Agents.Activity
  alias DevIDE.Annotations
  alias DevIDE.Agents.PaneEnv
  alias DevIDE.Agents.BrowserControl
  alias DevIDE.Audit
  alias DevIDE.BoundedBuffer
  alias DevIDE.Elixir, as: ElixirNav
  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Files
  alias DevIDE.Labels
  alias DevIDE.Logs
  alias DevIDE.Policy
  alias DevIDE.PreviewActivity
  alias DevIDE.PreviewPanes
  alias DevIDE.Proposals
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status
  alias DevIDE.Terminals.ClipboardPaste
  alias DevIDE.Terminals.GhosttyRawAdapter
  alias DevIDE.Terminals.GhosttySnapshot
  alias DevIDE.Terminals.ModePolicy
  alias DevIDE.Terminals.Session
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.Templates
  alias DevIDE.Terminals.Theme
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxJanitor
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIDE.Workspaces.FileAccess
  alias DevIDE.Workspaces.Isolation
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.ChannelAuth
  alias DevIdeWeb.Plugs.AssignCurrentUser
  alias DevIdeWeb.WorkspaceLive.PaneWorker
  alias DevIdeWeb.WorkspaceLive.Show.AgentEvents
  alias DevIdeWeb.WorkspaceLive.Show.FileEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteEvents
  alias DevIdeWeb.WorkspaceLive.Show.RunEvents
  alias DevIdeWeb.WorkspaceLive.Show.PaletteItems
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalInfo
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  import DevIdeWeb.WorkspaceLive.Show.Context
  import DevIdeWeb.WorkspaceLive.Show.UI
  import DevIdeWeb.WorkspaceLive.Show.AuditDrawer
  import DevIdeWeb.WorkspaceLive.Show.LogsPanel
  import DevIdeWeb.WorkspaceLive.Show.TemplatePanels
  import DevIdeWeb.WorkspaceLive.Show.AgentsPanel
  import DevIdeWeb.WorkspaceLive.Show.SidePanels
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

  @max_log_lines 500
  @mcp_activity_limit 30
  @preview_activity_limit 20
  @workspace_operator_notifications_limit 5

  # --- Authorization dispatch table (see authz_gate/3) ---
  #
  # Every top-level event this LiveView knowingly handles. The table exists to
  # make authorization coverage *structural*: authz_gate/3 runs before every
  # handle_event clause and denies any event not listed here (or covered by the
  # tmux:/terminal: delegation prefixes), so a newly-added handler fails closed
  # until it is registered — instead of silently running unauthorized.
  #
  # This table intentionally does NOT add per-event role checks. DevIDE is a
  # single-trust-tier internal cockpit: the real authorization boundary is
  # workspace *access* (`Workspaces.get/2` at mount) plus workspace *mode*, and
  # the genuinely sensitive actions already funnel through `DevIDE.Policy` inside
  # their handlers (file edits -> can_edit_file?, run/command -> can_run_command?,
  # mode change -> can_set_workspace_mode?, proposals -> can_view_proposal?,
  # review agent -> can_start_review_agent?). Those handler gates remain the real
  # decision; listing the events here just records they are accounted for.
  @known_events ~w(
    switch_tab refresh
    workspace:start workspace:stop workspace:set_mode
    tmux:apply_template tmux:apply_previewed_template
    tmux:save_template tmux:update_saved_template
    tmux:duplicate_saved_template tmux:delete_saved_template
    tmux:preview_template tmux:open_template_library tmux:close_template_library
    tmux:filter_saved_templates tmux:edit_saved_template tmux:cancel_saved_template_edit
    tmux:duplicate_saved_template_start tmux:cancel_saved_template_duplicate
    tmux:cancel_template_preview
    terminal:paste_file terminal:paste_image terminal:toggle_chrome terminal:auto_hide_chrome
    mobile_nav:toggle mobile_nav:close
    attach_terminal_session pane:navigate
    split_right split_down
    pane:close_focused pane:close_others pane:focus_next pane:focus_previous
    pane:zoom_focused retry_pane nav:dir equalize_layout pane:cycle_layout
    ghostty:snapshot snapshot_all
    agents:refresh agent_worktree:attach agent_worktree:compare isolation:refresh
    agent_mcp_activity:focus preview_activity:focus
    annotation:approve annotation:reject
    proposal:select proposal:clear agent_run:start agent_run:cancel
    run:start workflow:hint workflow:run run_ledger:select run_ledger:open
    palette:open palette:ide palette:category palette:nav palette:close palette:query
    palette:templates palette:execute
    audit_drawer:toggle audit_drawer:close audit_drawer:refresh audit_drawer:filter_window
    agents_panel:toggle agents_panel:close
    search:run annotation:open preview:open preview-pane:enter preview-pane:exit
    preview-pane:snapshot-click preview-pane:telemetry
    preview-pane:back preview-pane:forward preview-pane:refresh preview-pane:close
    run:cancel set_log_service
    tree:toggle tree:select_dir tree:new_form tree:cancel_new tree:create tree:refresh tree:open
    file:rename_form file:rename_cancel file:rename_submit
    file:delete_request file:delete_cancel file:delete_confirm file:refresh file:save
  )

  @impl true
  def mount(params, session, socket) do
    %{"id" => id} = params
    user = AssignCurrentUser.from_session(session)
    host_id = normalize_local_host_id(Map.get(params, "host", "local"))

    # Host gate: the cockpit is host-aware (product.md §9.1, FP-4), but
    # cross-host workspace resolution is not yet wired through the
    # runtime. Refuse non-local hosts politely — §11 "hide rather than
    # mock". The picker only links to hosts whose workspaces are listed,
    # so this path is defensive against direct-URL navigation.
    with :ok <- continue_if_fresh_static(socket, workspace_external_url(id, host_id, params)),
         :ok <- ensure_local_host(host_id),
         {:ok, ws} <- Workspaces.get(id, user[:email]) do
      path_result = Workspaces.safe_host_path(ws)
      loc_result = Workspaces.safe_host_loc(ws)
      # Per-tab session id: each browser tab/window (identified by the tab_id
      # connect param from sessionStorage) gets its own session that survives
      # its own refreshes, so multiple windows stay independent instead of
      # converging on one shared session. Falls back to a plain per-user sid
      # when the param is absent (disconnected mount / non-browser clients).
      tab_id = connect_tab_id(socket)
      sid = if tab_id, do: "u-" <> user.id <> "-" <> tab_id, else: "u-" <> user.id
      tmux_session = Tmux.session_name(ws.name || ws.id, sid)

      {workspace_mode, workspace_mode_source} =
        if connected?(socket),
          do: Workspaces.State.mode_for(id),
          else: {:review, :default}

      workspace_record = if connected?(socket), do: load_record(id), else: nil

      terminal_mode = initial_terminal_mode(workspace_mode, host_id)
      # NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3
      # Re-attach token for raw channel joins after a fresh LiveView
      # auth pass. This is safe to send as a socket dataset attribute and lets
      # TerminalChannel skip workspace manager access checks on
      # reconnect storms.
      workspace_capability =
        terminal_workspace_capability(user, ws, host_id, loc_result, sid, workspace_mode)

      socket_token = ChannelAuth.sign_user_token(user.id, user[:email])

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:current_user, user)
        |> assign(:workspace, ws)
        |> assign(:workspace_start_error, nil)
        |> assign(:host_id, host_id)
        |> assign(:host_path, path_result)
        |> assign(:host_loc, loc_result)
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
        |> assign(:active_session_kind, :shell)
        |> assign(:tmux_mutations_enabled?, true)
        |> assign(:terminal_sid, sid)
        |> assign(:default_terminal_sid, sid)
        |> assign(:terminal_mode, terminal_mode)
        |> assign(:window_terminal_modes, %{})
        |> assign(:window_terminal_mode_names, %{})
        |> assign(:new_windows_default_raw?, false)
        |> assign(:pending_url_terminal_mode, nil)
        |> assign(:audit_window_filter, "")
        |> TerminalState.assign_header_session_labels(%{panes: [], active_window_id: nil})
        |> assign(:ghostty_term_id, @ghostty_term_id)
        # One tmux session per browser tab. The seed pane uses the
        # workspace's primary session name so external subscribers
        # (TmuxJanitor, attachment helpers) keep working unchanged;
        # split panes get a derived session name (see do_split).
        |> assign(:pane_data, TerminalState.primary_pane_data(sid, tmux_session))
        |> assign(:preview_surfaces, DevIDE.Previews.discover_surfaces(ws))
        |> assign(:preview_panes, load_preview_panes(ws, path_result))
        |> assign(:entered_preview_pane_id, nil)
        |> assign(:terminal_surface_pane_id, nil)
        |> assign(:ui_highlight_pane_id, nil)
        |> assign(:focused_pane_id, "pane-1")
        |> assign(:terminal_preset_id, "catppuccin")
        |> assign(:terminal_themes, Theme.client_bundle())
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
        |> assign(:agent_caps, [])
        |> assign(:agent_worktrees, [])
        |> assign(:agent_mcp_activity, [])
        |> assign(:preview_activity, [])
        |> assign(:workspace_operator_notifications, [])
        |> assign(:pending_annotations, [])
        |> assign(:agent_review_cmds, [])
        |> assign(:agent_run, nil)
        |> assign(:agent_run_error, nil)
        |> assign(:selected_proposal, nil)
        |> assign(:proposal_analysis, nil)
        |> assign(:workspace_record, workspace_record)
        |> assign(:workspace_summaries, [])
        |> assign(:workspace_session_tabs, [])
        |> assign(:last_decision, nil)
        |> assign(:audit_drawer_open, false)
        |> assign(:agents_panel_open, false)
        |> assign(:audit_events_count, 0)
        |> assign(:audit_deny_count, 0)
        |> assign(:audit_ledger_count, 0)
        |> assign(:previews_count, 0)
        |> assign(:window_zoomed?, false)
        |> assign(:proposals_count, 0)
        |> assign(:agent_transcripts_count, 0)
        |> stream(:audit_events, [], reset: true)
        |> stream(:previews, [], reset: true)
        |> assign(:session_tabs, [])
        |> stream(:proposals, [], reset: true)
        |> stream(:agent_transcripts, [], reset: true)
        |> stream(:log_lines, [], reset: true)
        |> assign(:chrome_visible, true)
        |> assign(:mobile_nav_open, false)
        |> assign(:view_link_notice, nil)
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
        |> assign(:session_templates, SessionTemplate.list())
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
        |> assign(:deployment_panel, deployment_panel())
        |> assign_policy_permissions()
        |> TerminalState.subscribe_tmux_topology()
        |> TerminalState.subscribe_session_tabs()
        |> subscribe_workspace_mode()
        |> subscribe_previews()
        |> subscribe_browser_control()
        |> subscribe_agent_activity()
        |> subscribe_preview_activity()
        |> subscribe_workspace_annotations()
        |> subscribe_pane_labels()
        |> Phoenix.LiveView.attach_hook(:authz_gate, :handle_event, &authz_gate/3)

      # Defer PTY startup and every non-essential read out of mount so the
      # first HTML render (time-to-first-paint) is as fast as possible.
      send(self(), :after_mount)

      {:ok, socket}
    else
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

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Manager error: #{inspect(reason)}")
         |> push_navigate(to: ~p"/workspaces")}
    end
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

  defp workspace_external_url(id, host_id, params) do
    path =
      if Map.has_key?(params, "host") and host_id not in [nil, "", "local"],
        do: ~p"/workspaces/#{id}?host=#{host_id}",
        else: ~p"/workspaces/#{id}"

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

        socket =
          socket
          |> DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.stash_url_mode(params["mode"])
          |> DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.apply_pending_url_mode()

        socket =
          if topology_refreshed? do
            socket
          else
            DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.apply_pending_url_view(socket)
          end

        DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.seed_patched_view_path(socket)
      else
        socket
        |> DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.stash_url_mode(params["mode"])
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, :tab, tab)
    socket = if tab == "logs", do: start_log_stream(socket), else: socket

    socket =
      if tab == "run" do
        socket
        |> attach_existing_run()
        |> refresh_run_ledger()
      else
        socket
      end

    socket = if tab == "agents", do: load_agents(socket), else: socket
    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    # Older Ghostty assets sent component refreshes to the parent LiveView.
    # Keep that harmless during rolling deploys instead of crashing the socket.
    {:noreply, socket}
  end

  def handle_event("tmux:apply_template", %{"template-id" => template_id}, socket) do
    apply_session_template(socket, template_id)
  end

  def handle_event("tmux:preview_template", %{"template-id" => template_id}, socket) do
    case dry_run_session_template(socket, template_id) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> assign(:template_library_open, false)
         |> assign(:template_preview, preview)}

      {:error, :template_not_found} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(:error, "Session template not found.")}

      {:error, :unsupported_template} ->
        {:noreply,
         socket
         |> assign(:palette_open, false)
         |> put_flash(:error, "This saved template cannot be applied yet.")}
    end
  end

  def handle_event("tmux:open_template_library", _params, socket) do
    {:noreply,
     socket
     |> refresh_saved_session_templates()
     |> assign(:template_library_open, true)
     |> assign(:template_save_form, template_save_form())
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, template_duplicate_form())}
  end

  def handle_event("tmux:close_template_library", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_library_open, false)
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, template_duplicate_form())}
  end

  def handle_event("tmux:filter_saved_templates", params, socket) do
    tag =
      params
      |> Map.get("tag", "")
      |> to_string()
      |> String.trim()
      |> blank_to_nil()

    {:noreply,
     socket
     |> assign(:template_tag_filter, tag)
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, template_edit_form())
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, template_duplicate_form())
     |> refresh_saved_session_templates()
     |> assign(:template_library_open, true)}
  end

  def handle_event("tmux:save_template", %{"template" => params}, socket) do
    save_current_session_template(socket, params)
  end

  def handle_event("tmux:edit_saved_template", %{"template-id" => template_id}, socket) do
    case Templates.get(socket.assigns.workspace.id, template_id) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, saved.id)
         |> assign(:template_edit_form, template_edit_form(saved))
         |> assign(:template_duplicate_id, nil)
         |> assign(:template_duplicate_form, template_duplicate_form())}

      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def handle_event("tmux:cancel_saved_template_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, template_edit_form())}
  end

  def handle_event("tmux:update_saved_template", %{"template" => params}, socket) do
    update_saved_session_template(socket, params)
  end

  def handle_event("tmux:duplicate_saved_template_start", %{"template-id" => template_id}, socket) do
    case Templates.get(socket.assigns.workspace.id, template_id) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:template_library_open, true)
         |> assign(:template_edit_id, nil)
         |> assign(:template_edit_form, template_edit_form())
         |> assign(:template_duplicate_id, saved.id)
         |> assign(:template_duplicate_form, template_duplicate_form(socket, saved))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_saved_session_templates()
         |> assign(:template_library_open, true)
         |> put_flash(:error, "Saved template not found.")}
    end
  end

  def handle_event("tmux:cancel_saved_template_duplicate", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_duplicate_id, nil)
     |> assign(:template_duplicate_form, template_duplicate_form())}
  end

  def handle_event("tmux:duplicate_saved_template", %{"template" => params}, socket) do
    duplicate_saved_session_template(socket, params)
  end

  def handle_event("tmux:delete_saved_template", %{"template-id" => template_id}, socket) do
    delete_saved_session_template(socket, template_id)
  end

  def handle_event("tmux:cancel_template_preview", _params, socket) do
    {:noreply, assign(socket, :template_preview, nil)}
  end

  def handle_event("tmux:apply_previewed_template", params, socket) do
    case socket.assigns[:template_preview] do
      %{template: %{id: template_id}} ->
        mode =
          Map.get(params, "mode") ||
            template_preview_default_apply_mode(socket.assigns.template_preview)

        socket
        |> assign(:template_preview, nil)
        |> apply_session_template(template_id, reconcile: mode == "reconcile")

      _ ->
        {:noreply, assign(socket, :template_preview, nil)}
    end
  end

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

  def handle_event("mobile_nav:toggle", _params, socket) do
    {:noreply, update(socket, :mobile_nav_open, &(!&1))}
  end

  def handle_event("mobile_nav:close", _params, socket) do
    {:noreply, assign(socket, :mobile_nav_open, false)}
  end

  def handle_event("view_link_notice:dismiss", _params, socket) do
    {:noreply, DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.clear_view_link_notice(socket)}
  end

  def handle_event("tmux:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("terminal:" <> _ = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("attach_terminal_session" = event, params, socket),
    do: TerminalEvents.handle_event(event, params, socket)

  def handle_event("pane:navigate" = event, params, socket),
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
          GhosttySnapshot.capture(term, ws_id)

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
          GhosttySnapshot.capture(term, ws_id)

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

  # Agent / proposal events are handled by AgentEvents (extracted from this
  # module — pure code motion).
  def handle_event("agents:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("agent_worktree:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("agent_run:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("proposal:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("agent_mcp_activity:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("preview_activity:" <> _ = event, params, socket),
    do: AgentEvents.handle_event(event, params, socket)

  def handle_event("annotation:approve", params, socket),
    do: AgentEvents.handle_event("annotation:approve", params, socket)

  def handle_event("annotation:reject", params, socket),
    do: AgentEvents.handle_event("annotation:reject", params, socket)

  def handle_event("isolation:refresh", _, socket),
    do: {:noreply, refresh_isolation(socket, audit: true)}

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
        {_, _} = DevIDE.Workspaces.State.set_mode(ws_id, mode)

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
         |> maybe_reset_terminal_mode()
         |> refresh_terminal_workspace_capability()
         |> maybe_schedule_raw_prewarm()}
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

  # All "palette:*" events are handled by PaletteEvents (extracted from this
  # module — pure code motion). palette:execute resolves the selected item to a
  # concrete event and dispatches it back through handle_event/3 here.
  def handle_event("palette:" <> _ = event, params, socket),
    do: PaletteEvents.handle_event(event, params, socket)

  # Evidence drawer — single time-ordered audit stream per product.md §9.4.
  # Defaults closed; refresh fetches the latest from the audit adapter on open.
  def handle_event("audit_drawer:toggle", _, socket) do
    open? = not socket.assigns.audit_drawer_open

    socket =
      socket
      |> assign(:audit_drawer_open, open?)
      |> then(fn s -> if open?, do: refresh_audit_stream(s), else: s end)

    {:noreply, socket}
  end

  def handle_event("audit_drawer:close", _, socket),
    do: {:noreply, assign(socket, :audit_drawer_open, false)}

  def handle_event("audit_drawer:refresh", _, socket),
    do: {:noreply, refresh_audit_stream(socket)}

  def handle_event("audit_drawer:filter_window", %{"filter" => filter}, socket) do
    filter = String.trim(to_string(filter || ""))

    {:noreply,
     socket
     |> assign(:audit_window_filter, filter)
     |> refresh_audit_stream()}
  end

  def handle_event("agents_panel:toggle", _, socket) do
    open? = not socket.assigns.agents_panel_open
    socket = assign(socket, :agents_panel_open, open?)
    socket = if open?, do: load_agents(socket), else: socket
    {:noreply, socket}
  end

  def handle_event("agents_panel:close", _, socket),
    do: {:noreply, assign(socket, :agents_panel_open, false)}

  def handle_event("search:run", %{"query" => query}, socket) do
    case host_loc(socket) do
      {:ok, loc} -> {:noreply, run_search(socket, loc, query)}
      _ -> {:noreply, assign(socket, :search_state, {:error, :no_root})}
    end
  end

  def handle_event("annotation:open", %{"path" => path} = params, socket) do
    line = parse_line(params["line"])

    case host_path(socket) do
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
          "pane_id" => pane_id,
          "workspace_id" => socket.assigns.workspace.id
        })
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("set_log_service", %{"service" => service}, socket) do
    socket =
      socket
      |> assign(:log_service, service)
      |> stream(:log_lines, [], reset: true)

    {:noreply, start_log_stream(socket)}
  end

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
          TmuxTopology.snapshot(session, tmux: TerminalState.tmux_adapter()).active_pane_id

      with pane_id when is_binary(pane_id) <- target_pane,
           {:ok, _new_pane_id} <-
             TerminalState.tmux_adapter().split_pane(session, pane_id, flag,
               cwd: workspace_cwd(socket)
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
  def handle_info({:source_log, ref, line}, %{assigns: %{log_ref: ref}} = socket) do
    entry = %{id: "log-#{System.unique_integer([:positive])}", text: line}

    {:noreply, stream_insert(socket, :log_lines, entry, at: -1, limit: -@max_log_lines)}
  end

  def handle_info({TmuxTopology, {:updated, %{session: session} = topology}}, socket) do
    socket =
      if socket.assigns[:tmux_session] == session do
        TerminalState.assign_tmux_topology(socket, topology)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({TmuxTopology, {:session_terminated, %{session: session} = payload}}, socket) do
    # A terminated signal from a previous watcher incarnation (the session
    # was recreated under the same name and we already resubscribed) must not
    # blank the current window tabs.
    stale_generation? =
      is_integer(payload[:generation]) and
        is_integer(socket.assigns[:tmux_topology_generation]) and
        payload[:generation] != socket.assigns[:tmux_topology_generation]

    socket =
      if socket.assigns[:tmux_session] == session and not stale_generation? do
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
  # another browser tab, a fleet execution, the janitor). The directory
  # broadcasts the viewer-independent list; we apply this viewer's filter.
  def handle_info({DevIDE.Terminals.SessionDirectory, {:sessions_updated, ws_id, tabs}}, socket) do
    if socket.assigns.workspace.id == ws_id do
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
       |> maybe_reset_terminal_mode()
       |> refresh_terminal_workspace_capability()
       |> maybe_schedule_raw_prewarm()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_ready, _, _, _} = msg, socket),
    do: TerminalInfo.handle_info(msg, socket)

  def handle_info({:terminal_resize, _, _, _} = msg, socket),
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

  # Live observation push from PreviewControl (agent-driven MCP browsing, or
  # another viewer acting on the same preview). Update only when it targets the
  # preview this panel is currently showing.
  def handle_info({:agent_mcp_activity, entry}, socket) do
    activity =
      [entry | socket.assigns[:agent_mcp_activity] || []] |> Enum.take(@mcp_activity_limit)

    socket =
      socket
      |> assign(:agent_mcp_activity, activity)
      |> maybe_push_agent_mcp_error(entry)

    {:noreply, socket}
  end

  def handle_info({:preview_activity, entry}, socket) do
    activity =
      [entry | socket.assigns[:preview_activity] || []] |> Enum.take(@preview_activity_limit)

    {:noreply, assign(socket, :preview_activity, activity)}
  end

  def handle_info({:annotation_created, annotation}, socket) do
    socket =
      socket
      |> refresh_pending_annotations()
      |> maybe_push_annotation_pending(annotation)

    {:noreply, socket}
  end

  def handle_info({:annotation_updated, _annotation}, socket) do
    {:noreply, refresh_pending_annotations(socket)}
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

    socket =
      socket
      |> assign(
        :preview_panes,
        Map.put(socket.assigns[:preview_panes] || %{}, pane.pane_id, pane)
      )
      |> assign(:ui_highlight_pane_id, pane.pane_id)
      |> refresh_terminal_surface_pane_id()
      |> TerminalState.restore_operator_tmux_focus()

    {:noreply, socket}
  end

  def handle_info({:preview_pane_removed, payload}, socket) do
    pane_id = payload_value(payload, :pane_id)

    socket =
      socket
      |> assign(:preview_panes, Map.delete(socket.assigns[:preview_panes] || %{}, pane_id))
      |> maybe_clear_entered_preview_pane(pane_id)
      |> refresh_terminal_surface_pane_id()

    {:noreply, socket}
  end

  def handle_info(
        {:preview_observation,
         %{preview_id: preview_id, session_id: _session_id, observation: observation}},
        socket
      )
      when is_binary(preview_id) do
    case find_preview_pane_by_preview_id(socket, preview_id) do
      {pane_id, pane} ->
        updated = apply_observation_to_preview_pane(pane, observation)

        socket =
          socket
          |> assign(
            :preview_panes,
            Map.put(socket.assigns[:preview_panes] || %{}, pane_id, updated)
          )
          |> maybe_navigate_preview_pane(pane_id, pane, updated)

        {:noreply, socket}

      :error ->
        # Workspace isn't currently showing this preview — nothing to update.
        {:noreply, socket}
    end
  end

  def handle_info({:preview_observation, _payload}, socket), do: {:noreply, socket}

  def handle_info({:browser_control, %{"action" => "reload_preview_iframe"} = payload}, socket) do
    {:noreply, push_event(socket, "devide:reload_preview_iframes", payload)}
  end

  def handle_info({:browser_control, %{"action" => "reload_page"} = payload}, socket) do
    {:noreply, push_event(socket, "devide:reload_page", payload)}
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

  def handle_info(
        {:agent_run_data, ws_id, _stream, bin},
        %{assigns: %{workspace: %{id: ws_id}, agent_run: %{} = run}} = socket
      ) do
    updated = Map.update!(run, :buffer, &append_run_buffer(&1, bin))
    {:noreply, assign(socket, :agent_run, updated)}
  end

  def handle_info(
        {:agent_run_exit, ws_id, code, status},
        %{assigns: %{workspace: %{id: ws_id}, agent_run: %{} = run}} = socket
      ) do
    updated = %{run | exit_code: code, status: status, finished_at: DateTime.utc_now()}
    {:noreply, socket |> assign(:agent_run, updated) |> load_agents()}
  end

  def handle_info({:agent_run_data, _, _, _}, socket), do: {:noreply, socket}
  def handle_info({:agent_run_exit, _, _, _}, socket), do: {:noreply, socket}

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
        agent_caps: data.agent_caps,
        agent_worktrees: data.agent_worktrees,
        agent_mcp_activity: data.agent_mcp_activity,
        agent_review_cmds: data.agent_review_cmds,
        preview_activity: data.preview_activity,
        workspace_operator_notifications: data.workspace_operator_notifications,
        pending_annotations: data.pending_annotations,
        db_isolation: data.db_isolation,
        workspace_record: data.workspace_record,
        project_meta: data.project_meta,
        tooling: data.tooling
      )
      |> stream_agent_transcripts(data.agent_transcripts)
      |> stream_proposals(data.proposals)
      |> attach_existing_agent_run()
      |> maybe_insert_audit_event(audit_event)

    {:noreply, socket}
  end

  def handle_async(:agents_mount, _result, socket) do
    socket =
      socket
      |> assign(
        agent_caps: [],
        agent_worktrees: [],
        agent_mcp_activity: [],
        preview_activity: [],
        workspace_operator_notifications: [],
        pending_annotations: [],
        agent_review_cmds: [],
        project_meta: %{},
        tooling: %{}
      )
      |> stream_agent_transcripts([])
      |> stream_proposals([])

    {:noreply, socket}
  end

  def handle_async(:load_agents, {:ok, data}, socket) do
    {:noreply,
     socket
     |> assign(
       agent_caps: data.agent_caps,
       agent_worktrees: data.agent_worktrees,
       agent_mcp_activity: data.agent_mcp_activity,
       preview_activity: data.preview_activity,
       workspace_operator_notifications: data.workspace_operator_notifications,
       pending_annotations: data.pending_annotations,
       agent_review_cmds: data.agent_review_cmds
     )
     |> stream_agent_transcripts(data.agent_transcripts)
     |> stream_proposals(data.proposals)
     |> attach_existing_agent_run()}
  end

  # Scan crashed or was cancelled — keep the current assigns rather than
  # blanking a panel the user is looking at.
  def handle_async(:load_agents, _result, socket), do: {:noreply, socket}

  def handle_async(:refresh_git_status, {:ok, entries}, socket) do
    {:noreply, assign(socket, :git_status, entries)}
  end

  def handle_async(:refresh_git_status, _result, socket), do: {:noreply, socket}

  def handle_async(:workspace_summaries, {:ok, summaries}, socket) do
    {:noreply, assign_workspace_summaries(socket, summaries)}
  end

  def handle_async(:workspace_summaries, _result, socket), do: {:noreply, socket}

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
      socket.assigns.host_loc,
      sid,
      socket.assigns.workspace_mode
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

  defp terminal_workspace_capability(user, ws, host_id, loc_result, sid, workspace_mode) do
    terminal_owner? = Workspaces.viewer_terminal_owner?(ws, user)

    ChannelAuth.sign_terminal_capability(
      user.id,
      Map.get(ws, :id),
      workspace_name: ws.name,
      workspace_user: ws.user,
      workspace_path: ws.path,
      workspace_loc: workspace_loc_for_capability(loc_result),
      workspace_host_id: host_id,
      raw_terminal_ok: terminal_owner? and raw_terminal_allowed?(workspace_mode, host_id),
      owner_ok: terminal_owner?,
      terminal_owner_ok: terminal_owner?,
      terminal_sid: sid
    )
  end

  defp assign_workspace_mode(socket, ws_id, connected? \\ true)

  defp assign_workspace_mode(socket, ws_id, true) do
    {mode, source} = DevIDE.Workspaces.State.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign(:workspace_record, load_record(ws_id))
    |> assign_policy_permissions()
  end

  defp assign_workspace_mode(socket, _ws_id, false) do
    socket
    |> assign(:workspace_record, nil)
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
      _ = DevIDE.Workspaces.State.subscribe_mode_changes(socket.assigns.workspace.id)
    end

    socket
  end

  @doc false
  def refresh_workspace_mode(%{assigns: %{workspace: %{id: ws_id}}} = socket)
      when is_binary(ws_id) do
    socket
    |> assign_workspace_mode(ws_id)
    |> refresh_terminal_workspace_capability()
  end

  def refresh_workspace_mode(socket), do: socket

  defp load_record(ws_id) do
    case DevIDE.Workspaces.State.get(ws_id) do
      {:ok, r} -> r
      _ -> nil
    end
  end

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
        |> SessionDirectory.refresh_now(workspace_name: workspace_name)
        |> DevIDE.Terminals.visible_tabs(default_sid)
        |> SessionBarVM.session_tabs()

      saved_templates = Templates.list_for_workspace(workspace_id)

      %{
        workspace_id: workspace_id,
        tmux_session: tmux_session,
        previews: DevIDE.Previews.list_for_workspace(workspace_id),
        session_tabs: session_tabs,
        tmux_topology: TmuxTopology.snapshot(tmux_session, tmux: TerminalState.tmux_adapter()),
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
        assign(
          socket,
          :palette_items,
          palette_query(socket, socket.assigns[:palette_query] || "")
        )
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
    DevIDE.Workspaces.State.list()
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
      case host_path(socket) do
        {:ok, root} -> Isolation.detect(socket.assigns.workspace, root)
        _ -> %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()}
      end

    _ = DevIDE.Workspaces.State.persist_isolation(socket.assigns.workspace.id, iso)

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
    |> assign(:workspace_record, load_record(socket.assigns.workspace.id))
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
    if known_event?(event, params),
      do: {:cont, socket},
      else: {:halt, deny_event(socket, event)}
  end

  defp known_event?(event, _params) do
    event in @known_events or
      String.starts_with?(event, "tmux:") or
      String.starts_with?(event, "terminal:")
  end

  defp deny_event(socket, event) do
    ctx = policy_ctx(socket)
    decision = Policy.Decision.deny(:ui_event, Policy.mode(ctx), :unknown_action, %{event: event})

    _ =
      Audit.emit_decision(decision, %{
        target_type: "ui_event",
        target_ref: event,
        actor_id: ctx.actor_id,
        workspace_id: socket.assigns.workspace.id,
        metadata: %{event: event}
      })

    socket
    |> assign(:last_decision, decision)
    |> put_flash(:error, "That action isn't available here.")
  end

  defp refreshed_audit(socket) do
    Audit.recent_for(socket.assigns.workspace.id, 50)
  end

  @max_audit_stream 50

  def refresh_audit_stream(socket) do
    if connected?(socket) do
      events =
        socket
        |> refreshed_audit()
        |> filter_audit_events(socket.assigns[:audit_window_filter])

      socket
      |> stream(:audit_events, events, reset: true)
      |> assign(:audit_events_count, length(events))
      |> assign(:audit_deny_count, deny_count(events))
      |> assign(:audit_ledger_count, ledger_event_count(events))
    else
      socket
    end
  end

  defp filter_audit_events(events, filter) when filter in [nil, ""], do: events

  defp filter_audit_events(events, filter) when is_list(events) do
    needle = String.downcase(to_string(filter))
    Enum.filter(events, &audit_event_matches_window?(&1, needle))
  end

  defp filter_audit_events(events, _filter), do: events

  defp audit_event_matches_window?(event, needle) do
    case audit_event_window_ref(event) do
      ref when is_binary(ref) and ref != "" -> String.contains?(String.downcase(ref), needle)
      _ -> false
    end
  end

  defp audit_event_window_ref(%{metadata: metadata}) when is_map(metadata) do
    name = metadata["tmux_window_name"] || metadata[:tmux_window_name]
    id = metadata["tmux_window_id"] || metadata[:tmux_window_id]

    cond do
      is_binary(name) and name != "" -> name
      is_binary(id) and id != "" -> id
      true -> nil
    end
  end

  defp audit_event_window_ref(_), do: nil

  defp maybe_insert_audit_event(socket, nil), do: socket

  defp maybe_insert_audit_event(socket, %Audit.Event{} = event) do
    filter = socket.assigns[:audit_window_filter]

    if connected?(socket) and audit_event_visible?(event, filter) do
      count = (socket.assigns[:audit_events_count] || 0) + 1

      socket =
        socket
        |> stream_insert(:audit_events, event, at: 0)
        |> assign(:audit_events_count, count)
        |> update(:audit_deny_count, &(&1 + if(event.decision == :deny, do: 1, else: 0)))
        |> update(:audit_ledger_count, &(&1 + if(Ledger.ledger_event?(event), do: 1, else: 0)))

      if count > @max_audit_stream, do: refresh_audit_stream(socket), else: socket
    else
      socket
    end
  end

  defp audit_event_visible?(_event, filter) when filter in [nil, ""], do: true

  defp audit_event_visible?(event, filter),
    do: audit_event_matches_window?(event, String.downcase(to_string(filter)))

  defp stream_proposals(socket, proposals) do
    items = Enum.map(proposals, &Map.put(Map.from_struct(&1), :id, &1.rel_path))

    socket
    |> stream(:proposals, items, reset: true)
    |> assign(:proposals_count, length(items))
  end

  defp stream_agent_transcripts(socket, transcripts) do
    items = Enum.map(transcripts, &Map.put(Map.from_struct(&1), :id, &1.rel_path))

    socket
    |> stream(:agent_transcripts, items, reset: true)
    |> assign(:agent_transcripts_count, length(items))
  end

  defp mode_change_denied_message(%Policy.Decision{reason: :config_override}),
    do: "Workspace mode is pinned by configuration."

  defp mode_change_denied_message(%Policy.Decision{reason: :forbidden}),
    do: "Only the workspace owner can change mode."

  defp mode_change_denied_message(%Policy.Decision{reason: reason}) when not is_nil(reason),
    do: "Cannot change mode: #{reason |> Atom.to_string() |> String.replace("_", " ")}"

  defp mode_change_denied_message(_), do: "Cannot change workspace mode."

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
    case TerminalState.tmux_adapter().new_window(session, cwd: workspace_cwd(socket)) do
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

  defp run_search(socket, loc, query) do
    case FileAccess.search(loc, String.trim(query), []) do
      {:ok, results} ->
        state = if results == [], do: :empty, else: :ok

        socket
        |> assign(:search_query, query)
        |> assign(:search_results, results)
        |> assign(:search_state, state)

      {:error, reason} ->
        socket
        |> assign(:search_query, query)
        |> assign(:search_results, [])
        |> assign(:search_state, {:error, reason})
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
        _ = DevIDE.Workspaces.State.persist_isolation(workspace.id, iso)

        caps = Agents.detect(root, workspace)

        %{
          agent_caps: caps,
          agent_worktrees: DevIDE.Runtimes.list_agent_worktrees(workspace.id),
          agent_mcp_activity: Activity.recent(workspace.id),
          preview_activity:
            PreviewActivity.recent_workspace(workspace.id, @preview_activity_limit),
          workspace_operator_notifications:
            workspace_operator_notifications(
              workspace.id,
              @workspace_operator_notifications_limit
            ),
          pending_annotations: pending_annotations(workspace.id),
          agent_transcripts: Agents.transcripts(root),
          agent_review_cmds: Agents.review_commands(caps),
          proposals: Proposals.discover(root),
          db_isolation: iso,
          workspace_record: load_record(workspace.id),
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
          agent_caps: [],
          agent_worktrees: DevIDE.Runtimes.list_agent_worktrees(workspace.id),
          agent_mcp_activity: [],
          preview_activity: [],
          workspace_operator_notifications:
            workspace_operator_notifications(
              workspace.id,
              @workspace_operator_notifications_limit
            ),
          pending_annotations: pending_annotations(workspace.id),
          agent_transcripts: [],
          agent_review_cmds: [],
          proposals: [],
          db_isolation: %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()},
          workspace_record: load_record(workspace.id),
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
        with {:ok, root} <- host_path(socket),
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

  defp start_log_stream(socket) do
    case Logs.Adapter.start_stream(
           socket.assigns.workspace.id,
           socket.assigns.log_service,
           self()
         ) do
      {:ok, ref} -> assign(socket, :log_ref, ref)
      {:error, _reason} -> assign(socket, :log_ref, nil)
    end
  end

  # `git status --short` can take hundreds of ms on a big repo; run it off
  # the LiveView process so file saves/creates/deletes render immediately.
  # The result lands in handle_async(:refresh_git_status, ...).
  def refresh_git_status(socket) do
    case host_loc(socket) do
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

  # Kicks the agents-panel filesystem scans (capability detect, transcript
  # listing, proposal discovery) off the LiveView process; results land in
  # handle_async(:load_agents, ...). Events that used to block on these scans
  # (switch_tab, agents:refresh, agent_run_exit) now render immediately with
  # the current assigns and patch when the scan completes.
  def load_agents(socket) do
    workspace = socket.assigns.workspace

    case host_path(socket) do
      {:ok, root} ->
        start_async(socket, :load_agents, fn ->
          caps = Agents.detect(root, workspace)

          %{
            agent_caps: caps,
            agent_worktrees: DevIDE.Runtimes.list_agent_worktrees(workspace.id),
            agent_mcp_activity: Activity.recent(workspace.id),
            preview_activity:
              PreviewActivity.recent_workspace(workspace.id, @preview_activity_limit),
            workspace_operator_notifications:
              workspace_operator_notifications(
                workspace.id,
                @workspace_operator_notifications_limit
              ),
            pending_annotations: pending_annotations(workspace.id),
            agent_transcripts: Agents.transcripts(root),
            agent_review_cmds: Agents.review_commands(caps),
            proposals: Proposals.discover(root)
          }
        end)

      _ ->
        socket
        |> assign(:agent_caps, [])
        |> assign(:agent_worktrees, DevIDE.Runtimes.list_agent_worktrees(workspace.id))
        |> assign(:agent_mcp_activity, [])
        |> assign(:preview_activity, [])
        |> assign(
          :workspace_operator_notifications,
          workspace_operator_notifications(workspace.id, @workspace_operator_notifications_limit)
        )
        |> assign(:pending_annotations, pending_annotations(workspace.id))
        |> stream_agent_transcripts([])
        |> assign(:agent_review_cmds, [])
        |> stream_proposals([])
    end
  end

  def attach_agent_worktree(socket, %{runtime_id: sid, path: path})
      when is_binary(sid) and is_binary(path) do
    workspace = socket.assigns.workspace
    tmux_session = Tmux.session_name(workspace.name || workspace.id, sid)

    case TerminalState.tmux_adapter().ensure_session(tmux_session, path) do
      :ok ->
        socket =
          socket
          |> TerminalState.switch_active_session(sid, tmux_session)
          # ensure_session may have just created this tmux session — the
          # directory cache can't know about it yet, so force a recompute.
          |> TerminalState.refresh_session_tabs()
          |> assign(:agent_worktrees, DevIDE.Runtimes.list_agent_worktrees(workspace.id))

        if socket.assigns.terminal_sid == sid do
          TerminalState.patch_current_session(socket)
        else
          socket
        end

      {:error, reason} ->
        put_flash(socket, :error, "Could not attach agent worktree: #{inspect(reason)}")
    end
  end

  def attach_agent_worktree(socket, _worktree),
    do: put_flash(socket, :error, "Agent worktree is missing a path.")

  def attach_existing_agent_run(socket) do
    case DevIDE.Agents.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} ->
        case DevIDE.Agents.Run.subscribe(pid) do
          {:ok, snap} -> assign(socket, :agent_run, snap)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  # Batch command runs were retired with the delegated-execution stack; there
  # is no longer an in-flight run process to re-attach to.
  def attach_existing_run(socket), do: socket

  @run_buffer_cap 256 * 1024

  defp append_run_buffer(buffer, chunk) do
    BoundedBuffer.append(buffer, chunk, @run_buffer_cap, truncation_marker: "[…truncated]\n")
  end

  def load_diff(socket, path) do
    case host_loc(socket) do
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
  def render(assigns) do
    ~H"""
    <div id="palette-anchor" phx-hook="PaletteHook" class="hidden"></div>
    <div
      id={"window-terminal-modes-" <> @workspace.id}
      phx-hook="WindowTerminalModes"
      data-workspace-id={@workspace.id}
      data-terminal-sid={@terminal_sid}
      class="hidden"
    >
    </div>
    {render_palette(assigns)}
    {render_template_preview(assigns)}
    {render_template_library(assigns)}
    <Layouts.flash_group flash={@flash} />
    {render_view_link_notice(assigns)}
    <div id="terminal-activity" phx-hook="TerminalActivity" class="hidden" aria-hidden="true"></div>
    <div
      id="workspace-leader-root"
      phx-hook="WorkspaceLeader"
      data-terminal-themes={Jason.encode!(@terminal_themes)}
      class="workspace-shell flex h-dvh w-full max-w-full flex-col overflow-x-hidden bg-base-100 text-base-content px-4 pt-1 pb-1.5 pointer-coarse:px-2 pointer-coarse:pt-0.5 pointer-coarse:pb-0 lg:px-6"
    >
      <% workspace_path = render_path(@host_loc, @host_path) %>
      <%= if @chrome_visible do %>
        <header
          id={"workspace-header-" <> @workspace.id}
          phx-hook="ChromeWidth"
          class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 border-b border-base-300/70 px-0.5 pb-0.5 text-xs pointer-coarse:gap-0.5"
        >
          <div class="header-identity-cluster flex min-w-0 flex-1 items-center gap-1 overflow-x-clip">
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
            <h1
              class="header-p-low header-p-as-block max-w-40 shrink-0 truncate text-sm font-semibold leading-none"
              title={workspace_path}
            >
              {workspace_short_name(@workspace.name)}
            </h1>
            <span
              class={[
                "header-p-touch-show header-p-as-inline size-2 shrink-0 rounded-full",
                workspace_status_dot_class(@workspace.status)
              ]}
              title={@workspace.status}
              aria-label={"Workspace status: " <> to_string(@workspace.status)}
            ></span>
            <span class="header-p-low header-p-as-inline shrink-0 rounded bg-base-200 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-base-content/70">
              {@workspace.status}
            </span>
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
            <span
              :if={@workspace.branch}
              class="header-p-low header-p-as-inline shrink-0 font-mono text-[11px] text-base-content/60"
              title={"Workspace branch: " <> @workspace.branch}
            >
              {@workspace.branch}
            </span>
          </div>
          <button
            :if={@tab == "terminal"}
            id={"leader-prefix-button-" <> @workspace.id}
            type="button"
            data-leader-prefix-button="true"
            class="leader-prefix-button shrink-0 rounded border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-[10px] font-semibold leading-none text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content active:scale-[0.98]"
            title="tmux prefix key"
            aria-label="tmux prefix key"
            aria-pressed="false"
          >
            C-b
          </button>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <div class="header-terminal-pickers flex min-w-0 shrink items-center pointer-coarse:hidden">
              <div class="header-p-mid header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300"></div>
              <SessionBar.session_dropdown
                workspace_id={@workspace.id}
                tabs={@session_tabs}
                workspace_tabs={@workspace_session_tabs}
                active_id={@terminal_sid}
                preview_panes={@preview_panes}
                shell_active?={@terminal_sid == @default_terminal_sid}
                shell_session_id={@default_terminal_sid}
                shell_label={@shell_button_label}
                shell_detail={@shell_button_detail}
                shell_title={shell_tab_title(@default_terminal_sid)}
                active_fallback_label={session_kind_label(@active_session_kind)}
                active_fallback_detail={terminal_session_label(@tmux_session, @terminal_sid)}
              />
              <div class="header-p-mid header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300"></div>
              <SessionBar.window_dropdown
                workspace_id={@workspace.id}
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
            <div class="header-terminal-chrome flex min-w-0 shrink items-center pointer-coarse:hidden">
              <div class="header-p-low header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300"></div>
              <div class="header-p-low header-p-as-flex shrink-0 items-center gap-1 rounded bg-base-200/40 px-1 py-px">
                <span
                  id="terminal-mode-raw"
                  class="header-p-as-inline shrink-0 rounded border border-warning/40 bg-warning/20 px-1.5 py-0.5 font-mono text-[10px] uppercase tracking-wide text-warning-content"
                  title="Terminal: RAW — keystrokes reach the shell directly"
                >
                  raw
                </span>
              </div>
              <%= if @active_session_kind == :execution do %>
                <span class="header-p-low header-p-as-inline shrink-0 rounded border border-sky-300/40 bg-sky-500/10 px-1.5 py-0.5 font-mono text-[10px] uppercase tracking-wide text-sky-700">
                  fleet exec
                </span>
              <% end %>
            </div>
          <% end %>
          {render_header_overflow_menu(assigns)}
          <div class="ml-auto flex shrink-0 items-center gap-0.5 pointer-coarse:gap-0.5">
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
                <button
                  type="button"
                  phx-click="snapshot_all"
                  class="header-p-low rounded border border-base-300 px-1.5 py-0.5 text-[10px] text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                  title="Snapshot every Ghostty pane in this workspace (server-side)"
                >
                  snap all
                </button>
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
              id="agents-panel-toggle"
              phx-click="agents_panel:toggle"
              class={[
                "rounded border p-1 text-sm transition pointer-coarse:p-0.5",
                if(@agents_panel_open,
                  do: "border-primary bg-primary/10 text-primary",
                  else: "border-base-300 text-base-content/80 hover:bg-base-200"
                )
              ]}
              title="Agents — capabilities, mode, MCP"
              aria-label="Toggle agents panel"
            >
              <.icon name="hero-cpu-chip" class="size-4 pointer-coarse:size-3.5" />
            </button>
            <button
              phx-click="terminal:toggle_chrome"
              data-shortcut="Ctrl/Cmd + Shift + F"
              class="rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:p-0.5"
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
          class="mb-1 h-1.5 pointer-coarse:h-7 w-full cursor-pointer rounded bg-base-300/40 hover:bg-emerald-400/40 active:bg-emerald-400/60 transition-colors flex items-center justify-center"
          phx-click="terminal:toggle_chrome"
          title="Show chrome. Shortcut: Ctrl/Cmd + Shift + F"
          aria-label="Show header and utility bar"
        >
          <span class="sr-only">Show chrome</span>
          <span
            class="hidden pointer-coarse:block leading-none text-base-content/50"
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
        {if @tab == "files", do: render_files(assigns)}
        {if @tab == "search", do: render_search(assigns)}
        {if @tab == "diff", do: render_diff(assigns)}
        {if @tab == "run", do: render_run(assigns)}
        {if @tab == "logs", do: render_logs(assigns)}
      </div>
    </div>
    {render_audit_drawer(assigns)}
    {render_agents_panel_drawer(assigns)}
    {render_leader_cheatsheet(assigns)}
    """
  end

  # `C-b ?` — tmux list-keys equivalent. Toggled client-side (JS.toggle) by the
  # hidden leader target; clicking anywhere or pressing C-b ? again closes it.
  defp render_leader_cheatsheet(assigns) do
    ~H"""
    <div
      id="leader-cheatsheet"
      class="fixed inset-0 z-50 hidden"
      phx-click={JS.hide(to: "#leader-cheatsheet")}
    >
      <div class="absolute inset-0 bg-black/30"></div>
      <div class="absolute top-1/2 left-1/2 max-h-[80vh] w-[30rem] max-w-[92vw] -translate-x-1/2 -translate-y-1/2 overflow-auto rounded border border-base-300 bg-base-100 p-4 text-xs shadow-xl">
        <h2 class="mb-2 text-sm font-semibold">Keyboard shortcuts</h2>
        <p class="mb-3 text-[11px] text-base-content/60">
          Press <kbd>Ctrl + B</kbd>, then the key shown below. Works from anywhere, even inside the terminal.
        </p>
        <div class="grid grid-cols-2 gap-x-6 gap-y-1">
          <div class="font-semibold text-base-content/60 col-span-2 mt-1">Sessions & windows</div>
          <.cheat_row keys="s" desc="pick a session (↑↓ browse, o open, l copy)" />
          <.cheat_row keys="w" desc="pick a window (↑↓ browse, o open, l copy)" />
          <.cheat_row keys="c" desc="open a new window" />
          <.cheat_row keys="C" desc="new window in a new browser tab" />
          <.cheat_row keys="n / p" desc="next or previous window" />
          <.cheat_row keys="l" desc="jump back to your last window" />
          <.cheat_row keys="y" desc="copy a link to this session and window" />
          <.cheat_row keys="1–9" desc="jump to window 1–9" />
          <.cheat_row keys="," desc="rename this window" />
          <.cheat_row keys="&" desc="close this window" />
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
          <div class="font-semibold text-base-content/60 col-span-2 mt-2">Handy extras</div>
          <.cheat_row keys=":" desc="open the command palette" />
          <.cheat_row keys="?" desc="show this help" />
          <.cheat_row keys="Esc / Ctrl + B" desc="cancel (when waiting for a second key)" />
          <.cheat_row keys="Space" desc="focus the terminal" />
          <div class="font-semibold text-base-content/60 col-span-2 mt-2">
            From anywhere (no Ctrl + B)
          </div>
          <.cheat_row keys="Ctrl+P" desc="open the command palette" />
          <.cheat_row keys="Ctrl+Space" desc="open the command palette" />
          <.cheat_row keys="Ctrl+Shift+F" desc="hide the header for more terminal space" />
          <.cheat_row keys="Ctrl+← →" desc="previous or next pane" />
          <.cheat_row keys="Ctrl+↑ ↓" desc="previous or next session" />
          <div class="font-semibold text-base-content/60 col-span-2 mt-2">
            Inside the command palette
          </div>
          <.cheat_row keys="Tab" desc="switch category (Files, Commands, Terminal, …)" />
          <.cheat_row keys="Shift+Tab" desc="previous category" />
          <.cheat_row keys="↑ ↓ Enter" desc="browse results and run the one you want" />
          <div class="font-semibold text-base-content/60 col-span-2 mt-2">Safe command line</div>
          <.cheat_row keys="ide" desc="open the palette (terminal actions)" />
          <.cheat_row keys="help" desc="see commands you can run here" />
        </div>
        <p class="mt-3 text-[10px] text-base-content/50">
          More detail in <code>docs/leader_keys.md</code>
        </p>
      </div>
    </div>
    """
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

  defp render_audit_drawer(assigns) do
    ~H"""
    <.audit_drawer
      audit_drawer_open={@audit_drawer_open}
      audit_events_count={@audit_events_count}
      audit_ledger_count={@audit_ledger_count}
      audit_window_filter={@audit_window_filter}
      workspace={@workspace}
      streams={@streams}
    />
    """
  end

  defp render_agents_panel_drawer(assigns) do
    ~H"""
    <div
      :if={@agents_panel_open}
      class="fixed inset-0 z-40 pointer-events-none"
    >
      <div
        class="absolute inset-0 bg-black/20 pointer-events-auto"
        phx-click="agents_panel:close"
      >
      </div>
      <aside
        class={[
          "absolute top-0 bottom-0 bg-base-100 border-l border-base-300 shadow-xl pointer-events-auto flex flex-col",
          agents_panel_drawer_classes(assigns)
        ]}
        role="complementary"
        aria-label="Agents panel"
      >
        <header class="flex shrink-0 items-center justify-between border-b border-base-300 px-4 py-3">
          <h2 class="text-sm font-semibold tracking-tight">Agents</h2>
          <button
            phx-click="agents_panel:close"
            class="rounded border border-base-300 px-2 py-0.5 text-[11px] hover:bg-base-200"
            title="close"
          >
            ×
          </button>
        </header>
        <div class="min-h-0 flex-1 overflow-auto px-4 py-3">
          {render_agents(assigns)}
        </div>
      </aside>
    </div>
    """
  end

  defp render_terminal(assigns) do
    ~H"""
    <section class="terminal-shell -mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
      <div class="flex h-full min-h-0 flex-col overflow-hidden">
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
              <%= cond do %>
                <% @terminal_mode in [:raw, :raw_ghostty] and tmux_pane_surface?(assigns) -> %>
                  {render_tmux_pane_geometry(assign_tmux_pane_geometry(assigns))}
                <% @terminal_mode in [:raw, :raw_ghostty] -> %>
                  <div class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950">
                    {render_raw_terminal_surface(assigns)}
                  </div>
                <% tmux_multi_pane_geometry?(assigns) -> %>
                  {render_tmux_pane_geometry(assign_tmux_pane_geometry(assigns))}
                <% true -> %>
                  <div class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950">
                    {render_raw_terminal_surface(assigns)}
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
        class="flex cursor-pointer list-none select-none items-center rounded border border-base-300 px-1.5 py-0.5 text-base-content/70 transition hover:bg-base-200 [&::-webkit-details-marker]:hidden"
        title="More workspace and terminal controls"
        aria-label="More header controls"
      >
        ⋯
      </summary>
      <div class="header-overflow-menu">
        <div class="border-b border-base-300/70 px-3 py-1.5 text-[10px] font-semibold uppercase tracking-wide text-base-content/50">
          {@workspace.name}
        </div>
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
        <%= if @tab == "terminal" do %>
          <div class="my-0.5 border-t border-base-300/70"></div>
          <div class="px-3 py-1 text-[11px] text-base-content/60">
            Mode: raw
          </div>
        <% end %>
        <%= if @tab == "terminal" and @active_session_kind == :execution do %>
          <div class="px-3 py-1 text-[11px] text-sky-700">fleet exec session</div>
        <% end %>
        <%= if @tab == "terminal" and @terminal_mode in [:raw, :raw_ghostty] do %>
          <div class="px-3 py-1 font-mono text-[10px] text-base-content/50">
            tmux {terminal_session_label(@tmux_session, @terminal_sid)}
          </div>
          <button
            type="button"
            phx-click="snapshot_all"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            Snap all panes
          </button>
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
      style="bottom: var(--devide-mobile-keybar-bottom, 0px); padding-bottom: max(0.25rem, env(safe-area-inset-bottom));"
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
          <span class={[
            "shrink-0 rounded px-1 py-0.5 font-mono text-[8px] uppercase leading-none tracking-wide",
            if(@terminal_mode in [:raw, :raw_ghostty],
              do: "bg-warning/20 text-warning",
              else: "bg-primary/20 text-primary"
            )
          ]}>
            {mobile_mode_chip_short(assigns)}
          </span>
        </button>
        <%!-- Static modifier + navigation keys. phx-update="ignore" preserves ctrl/alt latch state. --%>
        <div
          id={"mobile-key-bar-keys-" <> @workspace.id}
          phx-update="ignore"
          class="contents"
        >
          <span
            class="leader-indicator mr-0.5 shrink-0 items-center gap-0.5 rounded border border-amber-500/50 bg-amber-500/10 px-1 py-0.5 text-[9px] font-bold text-amber-500"
            aria-live="polite"
            aria-label="Leader key active"
          >
            Ctrl + B
          </span>
          <button type="button" data-keybar-key="Escape" class={mobile_key_class()}>esc</button>
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
            data-keybar-key="Paste"
            class={mobile_key_class()}
            aria-label="Paste from clipboard"
          >
            paste
          </button>
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
        <%!-- LiveView-updated pane/window action buttons --%>
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
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
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
            class={mobile_key_class()}
            aria-label="Next window"
            title="Next window"
          >
            ›
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

  defp render_view_link_notice(assigns) do
    ~H"""
    <div
      :if={@view_link_notice}
      id="view-link-notice"
      class="mx-4 mb-2 rounded border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-base-content"
      role="status"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <p class="font-medium">{view_link_notice_title(@view_link_notice)}</p>
          <p class="mt-0.5 text-base-content/70">
            <%= cond do %>
              <% @view_link_notice.kind == :session -> %>
                <span class="font-mono">{@view_link_notice.requested}</span>
                has ended or was not found. Open a live session below.
              <% true -> %>
                <span class="font-mono">{@view_link_notice.requested}</span>
                was not found. Opened the closest live view instead.
            <% end %>
          </p>
        </div>
        <button
          type="button"
          phx-click="view_link_notice:dismiss"
          class="shrink-0 rounded px-2 py-0.5 text-base-content/55 hover:bg-base-200 hover:text-base-content"
        >
          Dismiss
        </button>
      </div>
      <div
        :if={@view_link_notice.alternatives != []}
        class="mt-2 flex flex-wrap items-center gap-1.5"
      >
        <%= for alt <- @view_link_notice.alternatives do %>
          <.link
            patch={alt.patch}
            class="rounded border border-base-300 bg-base-100 px-2 py-0.5 font-medium hover:border-primary/40 hover:text-primary"
          >
            {alt.label}
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  defp view_link_notice_title(%{kind: :session}),
    do: "That shared session is no longer available."

  defp view_link_notice_title(%{kind: :window}), do: "That shared window is no longer available."
  defp view_link_notice_title(%{kind: :pane}), do: "That shared pane is no longer available."
  defp view_link_notice_title(%{kind: :zoom}), do: "Could not restore zoom from that link."

  defp render_mobile_nav_sheet(assigns) do
    ~H"""
    <div
      :if={@mobile_nav_open}
      id={"mobile-nav-sheet-" <> @workspace.id}
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
          <div class="min-w-0">
            <div class="text-[10px] font-semibold uppercase tracking-wide text-zinc-500">
              Navigate
            </div>
            <div class="truncate text-sm font-medium">{mobile_mode_chip_title(assigns)}</div>
          </div>
          <button
            type="button"
            phx-click="mobile_nav:close"
            class="shrink-0 rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-300"
          >
            Done
          </button>
        </div>
        <div class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-zinc-500">
          Sessions
        </div>
        <div class="mb-3 space-y-0.5">
          <div class="flex items-center gap-1">
            <button
              type="button"
              phx-click={
                JS.push("terminal:switch_to_shell")
                |> JS.push("mobile_nav:close")
              }
              class={[mobile_nav_row_class(@terminal_sid == @default_terminal_sid), "min-w-0 flex-1"]}
            >
              <span class="truncate font-medium">{@shell_button_label}</span>
              <span
                :if={@shell_button_detail != ""}
                class="truncate font-mono text-[10px] text-zinc-500"
              >
                {@shell_button_detail}
              </span>
            </button>
            <SessionBar.copy_link_button
              url={SessionBar.share_url(@workspace.id, @default_terminal_sid)}
              label={@shell_button_label}
              visible?={true}
            />
          </div>
          <%= for tab <- @session_tabs do %>
            <div class="flex items-center gap-1">
              <button
                type="button"
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
                class={[mobile_nav_row_class(@terminal_sid == tab.id), "min-w-0 flex-1"]}
              >
                <span class="truncate font-medium">{tab.label}</span>
                <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-zinc-500">
                  {tab.detail}
                </span>
              </button>
              <SessionBar.copy_link_button
                url={SessionBar.share_url(@workspace.id, tab.id)}
                label={tab.label}
                visible?={true}
              />
            </div>
          <% end %>
        </div>
        <div class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-zinc-500">
          Windows
        </div>
        <div class="space-y-0.5">
          <%= for window <- @tmux_window_tabs do %>
            <div class="flex items-center gap-1">
              <button
                type="button"
                phx-click={
                  JS.push("tmux:select_window", value: %{"window-id" => window.id})
                  |> JS.push("mobile_nav:close")
                }
                class={[mobile_nav_row_class(window.active?), "min-w-0 flex-1"]}
              >
                <span class="font-mono text-[10px] text-zinc-500">{window.index}</span>
                <span class="min-w-0 truncate font-medium">{window.name}</span>
                <span :if={window.command != ""} class="truncate font-mono text-[10px] text-zinc-500">
                  {window.command}
                </span>
              </button>
              <SessionBar.copy_link_button
                url={SessionBar.share_url(@workspace.id, @terminal_sid, window.id)}
                label={window.name}
                kind="window"
                visible?={true}
              />
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

  # Ordered category tabs shown in the palette. `:all` is always first so the
  # user can broaden out of any screen-derived default.
  @palette_categories [:all, :files, :commands, :tmux, :agents, :preview, :actions]

  @doc false
  def palette_categories, do: @palette_categories

  @doc false
  def palette_category_label(:all), do: "all"
  def palette_category_label(:files), do: "files"
  def palette_category_label(:commands), do: "commands"
  def palette_category_label(:tmux), do: "tmux"
  def palette_category_label(:agents), do: "agents"
  def palette_category_label(:preview), do: "preview"
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

  # Subscribe to live preview observations for this workspace so the Agent
  # preview panel follows agent-driven (MCP) browsing in real time, not just on
  # this viewer's own panel actions. See PreviewControl.broadcast_observation/2.
  defp subscribe_agent_activity(socket) do
    if connected?(socket) do
      :ok = Activity.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp subscribe_preview_activity(socket) do
    if connected?(socket) do
      :ok = PreviewActivity.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp workspace_operator_notifications(_workspace_id, _limit), do: []

  defp maybe_push_agent_mcp_error(socket, %{status: :error} = entry) do
    workspace = socket.assigns.workspace
    workspace_name = workspace.name || workspace.id

    push_event(socket, "devide:agent_mcp_error", %{
      tool: entry.tool,
      summary: entry.summary,
      workspace: workspace_name,
      source: Atom.to_string(entry.source)
    })
  end

  defp maybe_push_agent_mcp_error(socket, _entry), do: socket

  def refresh_pending_annotations(socket) do
    assign(socket, :pending_annotations, pending_annotations(socket.assigns.workspace.id))
  end

  defp pending_annotations(workspace_id) when is_binary(workspace_id) do
    Annotations.list_for_workspace(workspace_id, approval_state: :pending, limit: 20)
  end

  defp subscribe_workspace_annotations(socket) do
    if connected?(socket) do
      :ok = Annotations.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp subscribe_pane_labels(socket) do
    if connected?(socket) do
      :ok = Labels.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp maybe_push_annotation_pending(socket, %{approval_state: :pending} = annotation) do
    push_event(socket, "devide:annotation_pending", %{
      id: annotation.id,
      author_type: Atom.to_string(annotation.author_type),
      content: String.slice(annotation.content, 0, 160),
      workspace: socket.assigns.workspace.name || socket.assigns.workspace.id
    })
  end

  defp maybe_push_annotation_pending(socket, _annotation), do: socket

  defp subscribe_previews(socket) do
    if connected?(socket) do
      _ =
        Phoenix.PubSub.subscribe(
          DevIde.PubSub,
          "preview:" <> to_string(socket.assigns.workspace.id)
        )
    end

    socket
  end

  defp subscribe_browser_control(socket) do
    if connected?(socket) do
      _ = BrowserControl.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  defp maybe_select_requested_terminal_session(socket, %{"session" => sid} = params)
       when is_binary(sid) and sid != "" do
    if sid == socket.assigns[:terminal_sid] do
      {DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.clear_view_link_notice(socket), false}
    else
      {socket, _switched?} =
        switch_terminal_session_from_params(socket, sid, Map.get(params, "tmux_session"))

      {maybe_assign_session_view_link_notice(socket, sid), true}
    end
  end

  defp maybe_select_requested_terminal_session(socket, _params) do
    sid = socket.assigns[:default_terminal_sid]

    socket =
      if is_binary(sid) and sid != "" and sid != socket.assigns[:terminal_sid] do
        {switched_socket, _switched?} = switch_terminal_session_from_params(socket, sid)
        switched_socket
      else
        socket
      end

    {DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.clear_view_link_notice(socket), false}
  end

  defp maybe_assign_session_view_link_notice(socket, requested_sid) do
    if socket.assigns[:terminal_sid] == requested_sid do
      DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.clear_view_link_notice(socket)
    else
      DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.assign_view_link_notice(
        socket,
        :session,
        requested_sid
      )
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

        {:error, _reason} ->
          {DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.assign_window_notice(socket, window_id),
           false}
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

  defp template_save_form(params \\ %{}) do
    params =
      %{"name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value} end))

    to_form(params, as: :template)
  end

  defp template_edit_form(params \\ %{}) do
    params =
      %{"id" => "", "name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value || ""} end))

    to_form(params, as: :template)
  end

  defp template_duplicate_form(params \\ %{}) do
    params =
      %{"source_id" => "", "name" => "", "description" => "", "tags" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value || ""} end))

    to_form(params, as: :template)
  end

  defp template_duplicate_form(socket, saved) do
    template_duplicate_form(%{
      "source_id" => saved.id,
      "name" =>
        saved_template_copy_name(socket.assigns[:saved_session_templates] || [], saved.name),
      "description" => saved.description || "",
      "tags" => saved_template_tags_string(saved)
    })
  end

  defp apply_session_template(socket, template_id, opts \\ []) do
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

  defp dry_run_session_template(socket, template_id) do
    opts = [workspace_root: workspace_cwd(socket)]

    case SessionTemplate.dry_run(template_id, opts) do
      {:error, :template_not_found} ->
        dry_run_saved_session_template(socket, template_id, opts)

      result ->
        result
    end
  end

  defp dry_run_saved_session_template(socket, template_id, opts) do
    topology =
      TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: TerminalState.tmux_adapter())

    with {:ok, preview} <- Templates.dry_run(socket.assigns.workspace.id, template_id, opts),
         {:ok, diff} <- Templates.diff(socket.assigns.workspace.id, template_id, topology, opts) do
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

    case SessionTemplate.execute(socket.assigns.tmux_session, template_id, opts) do
      {:error, :template_not_found} ->
        Templates.execute(
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
      TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: TerminalState.tmux_adapter())

    opts = [tmux: TerminalState.tmux_adapter(), workspace_root: workspace_cwd(socket)]

    case Templates.execute_reconcile(
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

  defp save_current_session_template(socket, params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    description = params |> Map.get("description", "") |> to_string() |> String.trim()
    tags = Map.get(params, "tags")

    if name == "" do
      {:noreply,
       socket
       |> assign(:template_library_open, true)
       |> assign(:template_save_form, template_save_form(params))
       |> put_flash(:error, "Template name cannot be blank.")}
    else
      topology =
        TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: TerminalState.tmux_adapter())

      with {:ok, template} <-
             SessionTemplate.export_topology(topology,
               workspace_root: workspace_cwd(socket),
               name: name
             ),
           {:ok, saved} <-
             Templates.save(%{
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
    end
  end

  defp update_saved_session_template(socket, params) do
    workspace_id = socket.assigns.workspace.id
    template_id = Map.get(params, "id") || socket.assigns[:template_edit_id]
    attrs = Map.take(params, ["name", "description", "tags"])

    with template_id when is_binary(template_id) and template_id != "" <- template_id,
         {:ok, saved} <- Templates.get(workspace_id, template_id),
         {:ok, updated} <- Templates.update(workspace_id, template_id, attrs) do
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

  defp duplicate_saved_session_template(socket, params) do
    workspace_id = socket.assigns.workspace.id
    source_id = Map.get(params, "source_id") || socket.assigns[:template_duplicate_id]
    attrs = Map.take(params, ["name", "description", "tags"])

    with source_id when is_binary(source_id) and source_id != "" <- source_id,
         {:ok, duplicated} <- Templates.duplicate(workspace_id, source_id, attrs) do
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

  defp delete_saved_session_template(socket, template_id) do
    workspace_id = socket.assigns.workspace.id

    with {:ok, saved} <- Templates.get(workspace_id, template_id),
         :ok <- Templates.delete(workspace_id, template_id) do
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

  defp refresh_saved_session_templates(socket) do
    tag_filter = socket.assigns[:template_tag_filter]

    socket =
      socket
      |> assign(
        :saved_session_template_tags,
        saved_session_template_tags(socket.assigns.workspace.id)
      )
      |> assign(
        :saved_session_templates,
        Templates.list_for_workspace(socket.assigns.workspace.id, tags: tag_filter)
      )

    if socket.assigns[:palette_open] do
      assign(socket, :palette_items, palette_query(socket, socket.assigns[:palette_query] || ""))
    else
      socket
    end
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
  defdelegate raw_terminal_allowed?(workspace_mode, host_id), to: ModePolicy

  @doc false
  defdelegate raw_default?(workspace_mode, host_id), to: ModePolicy

  defp handle_paste_file(params, socket, kind) do
    socket = refresh_workspace_mode(socket)

    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      paste_file_to_workspace(params, socket, kind)
    else
      {:reply, %{ok: false, reason: "raw terminal access is required to paste files"}, socket}
    end
  end

  defp paste_file_to_workspace(params, socket, kind) do
    with {:ok, root} <- host_path(socket),
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

  defp save_clipboard_file(root, params, :image), do: ClipboardPaste.save_image(root, params)
  defp save_clipboard_file(root, params, _kind), do: ClipboardPaste.save_file(root, params)

  defp paste_file_reason(:too_large),
    do:
      "clipboard file is too large (max #{div(ClipboardPaste.max_file_bytes(), 1024 * 1024)} MB)"

  defp paste_file_reason(:unsupported_type), do: "clipboard image type is not supported"
  defp paste_file_reason(:invalid_base64), do: "clipboard file data was invalid"
  defp paste_file_reason(:invalid_path), do: "clipboard file path was invalid"
  defp paste_file_reason(:write_failed), do: "failed to write clipboard file"
  defp paste_file_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp initial_terminal_mode(mode, host_id) do
    # :raw means Ghostty-based raw terminal (PaneWorker + tmux).
    ModePolicy.initial_mode(mode, host_id)
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

    case DevIDE.Previews.SurfaceResolver.get(workspace, surface) do
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
        cwd: workspace_cwd(socket)
      ]

      case DevIDE.Agents.PreviewTools.split_preview_pane(workspace, url, opts) do
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
    ids = preview_pane_workspace_ids(workspace, workspace_id, path_result)

    ids
    |> Enum.flat_map(&PreviewPanes.list_for_workspace/1)
    |> Enum.map(fn registration ->
      {registration.pane_id, preview_pane_payload(registration)}
    end)
    |> Map.new()
  end

  defp authorize_preview_pane(socket, pane_id) do
    workspace = socket.assigns.workspace
    path_result = socket.assigns[:host_path]
    allowed_ids = preview_pane_workspace_ids(workspace, workspace.id, path_result)

    case PreviewPanes.get_by_pane(pane_id) do
      %{workspace_id: workspace_id} ->
        if workspace_id in allowed_ids, do: :ok, else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp preview_pane_workspace_ids(workspace, workspace_id, path_result) do
    ([workspace_id] ++
       WorkspaceAliases.viewer_ids(workspace_id) ++
       workspace_folder_aliases(workspace, path_result))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
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
      tmux_session: payload_value(payload, :tmux_session)
    }
  end

  # Locates the open preview pane (keyed by its tmux pane_id) whose registration
  # carries the given preview_id, so agent-driven (MCP) observations can be
  # routed to the matching panel. Returns :error when this workspace view isn't
  # currently showing that preview.
  defp find_preview_pane_by_preview_id(socket, preview_id) do
    socket.assigns[:preview_panes]
    |> Kernel.||(%{})
    |> Enum.find(fn {_pane_id, pane} -> preview_value(pane, :preview_id) == preview_id end)
    |> case do
      {pane_id, pane} -> {pane_id, pane}
      nil -> :error
    end
  end

  # Reflects the latest agent observation (url/title) into a preview pane so the
  # open panel follows agent-driven browsing. Only fields present on the
  # observation override the existing pane; missing fields keep prior values.
  defp apply_observation_to_preview_pane(pane, observation) do
    url = observation_field(observation, :url)
    title = observation_field(observation, :title)
    display_url = url || preview_value(pane, :display_url) || preview_value(pane, :url)

    pane
    |> maybe_put_preview_field(:url, url)
    |> maybe_put_preview_field(:display_url, url)
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

  # When the agent navigated the preview to a new URL, reload the iframe so the
  # human's panel reflects it. No-op when the URL is unchanged (e.g. a DOM-only
  # observation) to avoid needless reload churn.
  defp maybe_navigate_preview_pane(socket, pane_id, previous, updated) do
    new_url = preview_value(updated, :url)

    if is_binary(new_url) and new_url != "" and new_url != preview_value(previous, :url) do
      push_event(socket, "devide:reload_preview_iframes", %{"pane_id" => pane_id})
    else
      socket
    end
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
      "delta_y"
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
      "iframe_focus" -> "iframe focused"
      "iframe_blur" -> "iframe blurred"
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
        |> push_event("devide:reload_preview_iframes", %{"pane_id" => pane_id})

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

  defp maybe_clear_entered_preview_pane(socket, pane_id) do
    if socket.assigns[:entered_preview_pane_id] == pane_id do
      assign(socket, :entered_preview_pane_id, nil)
    else
      socket
    end
  end

  defp agents_panel_drawer_classes(_), do: "right-0 w-full sm:w-[440px]"

  defp active_tmux_window_name(assigns) do
    DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
  end

  defp mobile_mode_chip_short(_assigns), do: "raw"

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
      name when is_binary(name) and name != "" -> "Raw shell — window \"#{name}\""
      _ -> "Raw shell"
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

  defp maybe_reset_terminal_mode(socket) do
    DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.strip_disallowed_raw(socket)
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
            Session.send_input(session_pid, command)

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
        TmuxJanitor.subscribe(pane.tmux_session)

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
          GhosttyRawAdapter.ensure_raw_shell(workspace_key, session_sid, loc)

        if match?({:ok, _}, result) do
          tmux_session = Tmux.session_name(workspace_key, session_sid)
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
    case socket.assigns[:host_path] do
      {:ok, path} -> path
      _ -> "."
    end
  end

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
          TmuxJanitor.unsubscribe(pane.tmux_session)
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
      {:ok, loc} -> loc
      _ -> {:local, cwd}
    end
  end
end
