defmodule DevIdeWeb.WorkspaceLive.Show do
  use DevIdeWeb, :live_view

  alias DevIDE.Workspaces
  alias DevIDE.Terminals.SessionTemplate
  alias DevIDE.Terminals.Templates
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Terminals.ClipboardPaste
  alias DevIDE.Terminals
  alias DevIDE.Logs
  alias DevIDE.Files
  alias DevIDE.Commands
  alias DevIDE.Elixir, as: ElixirNav
  alias DevIDE.Search
  alias DevIDE.Palette
  alias DevIDE.Palette.Item, as: PaletteItem
  alias DevIDE.Agents
  alias DevIDE.Export.WorkspaceStatus
  alias DevIDE.Proposals
  alias DevIDE.Policy
  alias DevIDE.Audit
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status
  alias DevIdeWeb.Plugs.AssignCurrentUser
  alias DevIdeWeb.ChannelAuth
  alias DevIdeWeb.TerminalSurface
  alias DevIdeWeb.TerminalSurface.Pane, as: TerminalSurfacePane
  alias DevIdeWeb.WorkspaceLive.PaneLayout

  import DevIdeWeb.WorkspaceLive.Show.UI
  import DevIdeWeb.WorkspaceLive.Show.AuditDrawer
  import DevIdeWeb.WorkspaceLive.Show.LogsPanel
  import DevIdeWeb.WorkspaceLive.Show.RunPanel

  @ghostty_term_id "raw-term-ghostty"
  @preview_candidate_ttl_ms 10 * 60 * 1000

  @template_reconcile_summary_fields [
    {:reuse_windows, "Reuse windows"},
    {:create_windows, "Create windows"},
    {:reuse_panes, "Reuse panes"},
    {:new_panes, "New panes"},
    {:send_commands, "Send commands"},
    {:select_panes, "Focus changes"}
  ]

  @type pane :: %{
          ghostty_term: pid() | nil,
          ghostty_pty: pid() | nil,
          worker: pid() | nil,
          backend: :ghostty_pty | :shared_session | :session_owner | nil,
          session_sid: String.t(),
          tmux_session: String.t(),
          cols: integer(),
          rows: integer(),
          error: term() | nil
        }

  @max_log_lines 500

  @impl true
  def mount(params, session, socket) do
    %{"id" => id} = params
    user = AssignCurrentUser.from_session(session)
    host_id = Map.get(params, "host", "local")

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
      workspace_loc = workspace_loc_for_capability(loc_result)
      # Per-tab session id: each browser tab/window (identified by the tab_id
      # connect param from sessionStorage) gets its own session that survives
      # its own refreshes, so multiple windows stay independent instead of
      # converging on one shared session. Falls back to a plain per-user sid
      # when the param is absent (disconnected mount / non-browser clients).
      tab_id = connect_tab_id(socket)
      sid = if tab_id, do: "u-" <> user.id <> "-" <> tab_id, else: "u-" <> user.id
      tmux_session = Tmux.session_name(ws.name || ws.id, sid)

      workspace_mode =
        if connected?(socket),
          do: Workspaces.State.mode_for(id) |> elem(0),
          else: :normal

      terminal_mode = initial_terminal_mode(workspace_mode, host_id)
      # NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3
      # Re-attach token for governed/raw channel joins after a fresh LiveView
      # auth pass. This is safe to send as a socket dataset attribute and lets
      # TerminalChannel skip workspace manager access checks on
      # reconnect storms.
      workspace_capability =
        ChannelAuth.sign_terminal_capability(
          user.id,
          ws.id || ws[:id] || id,
          workspace_name: ws.name,
          workspace_user: ws.user,
          workspace_path: ws.path,
          workspace_loc: workspace_loc,
          workspace_host_id: host_id,
          raw_terminal_ok: raw_terminal_allowed?(workspace_mode, host_id),
          owner_ok: true,
          terminal_owner_ok: true,
          terminal_sid: sid
        )

      socket_token = ChannelAuth.sign_user_token(user.id, user[:email])
      mount_previews = previews_for_mount(socket, id)
      mount_sessions = Terminals.list_attachable(id)

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:current_user, user)
        |> assign(:workspace, ws)
        |> assign(:host_id, host_id)
        |> assign(:host_path, path_result)
        |> assign(:host_loc, loc_result)
        |> assign(:tmux_session, tmux_session)
        |> assign(:tmux_windows, [])
        |> assign(:tmux_panes, [])
        |> assign(:tmux_active_window_id, nil)
        |> assign(:tmux_active_pane_id, nil)
        |> assign(:tmux_topology_version, 0)
        |> assign(:tmux_rename_window_id, nil)
        |> assign(:terminal_sid, sid)
        |> assign(:default_terminal_sid, sid)
        |> assign(:terminal_mode, terminal_mode)
        |> assign(:ghostty_term_id, @ghostty_term_id)
        # Phase 2: Recursive layout for tmux-style splits
        # Also seed the Tidewave-visible debug form.
        |> put_pane_layout({:pane, "pane-1"})
        # One tmux session per browser pane. The seed pane uses the
        # workspace's primary session name so external subscribers
        # (TmuxJanitor, attachment helpers) keep working unchanged;
        # split panes get a derived session name (see do_split).
        |> assign(:pane_data, %{
          "pane-1" => %{
            ghostty_term: nil,
            ghostty_pty: nil,
            worker: nil,
            backend: nil,
            session_sid: sid,
            tmux_session: tmux_session,
            cols: 120,
            rows: 40,
            error: nil
          }
        })
        |> assign(:pane_refresh_pending, MapSet.new())
        |> assign(:pane_pty_buffer, %{})
        |> assign(:preview_candidates, %{})
        |> assign(:dismissed_preview_candidate_urls, MapSet.new())
        |> assign(:opened_preview_candidate_urls, MapSet.new())
        |> assign(:preview_surfaces, DevIDE.Previews.discover_surfaces(ws))
        |> assign(:active_preview_observation, nil)
        |> assign(:active_preview_control_session, nil)
        |> assign(:focused_pane_id, "pane-1")
        |> assign(:zoomed_pane_id, nil)
        |> assign(:debug_persistence_status, "idle")
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
        |> assign(:agent_review_cmds, [])
        |> assign(:agent_run, nil)
        |> assign(:agent_run_error, nil)
        |> assign(:selected_proposal, nil)
        |> assign(:proposal_analysis, nil)
        |> assign_workspace_mode(ws.id, connected?(socket))
        |> assign(:last_decision, nil)
        |> assign(:audit_drawer_open, false)
        |> assign(:audit_events_count, 0)
        |> assign(:audit_deny_count, 0)
        |> assign(:audit_ledger_count, 0)
        |> assign(:previews_count, 0)
        |> assign(:proposals_count, 0)
        |> assign(:agent_transcripts_count, 0)
        |> assign(:active_executions?, false)
        |> stream(:audit_events, [], reset: true)
        |> stream(:previews, mount_previews, reset: true)
        |> assign(:previews_count, length(mount_previews))
        |> then(fn s ->
          executions = Enum.filter(mount_sessions, &(&1.kind == :execution))

          s
          |> stream(:active_sessions, executions, reset: true)
          |> assign(:active_executions?, executions != [])
        end)
        |> stream(:proposals, [], reset: true)
        |> stream(:agent_transcripts, [], reset: true)
        |> stream(:log_lines, [], reset: true)
        |> assign(:chrome_visible, true)
        |> assign(:equalize_flash, nil)
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
        |> assign(:saved_session_templates, Templates.list_for_workspace(ws.id))
        |> assign(:template_preview, nil)
        |> assign(:template_library_open, false)
        |> assign(:template_save_form, template_save_form())
        |> assign(:template_edit_id, nil)
        |> assign(:template_edit_form, template_edit_form())
        |> assign(:workspace_mode, workspace_mode)
        |> assign(:workspace_mode_source, :default)
        |> assign(:active_preview, nil)
        |> subscribe_tmux_topology()
        |> subscribe_previews()

      # Defer FS walks, git, DB queries and agent loading out of the initial
      # mount so the first HTML render (time-to-first-paint) is as fast as
      # possible. The handle_info fires immediately after, causing a follow-up
      # diff with the populated side panels / state.
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

  defp continue_if_fresh_static(socket, url) do
    if connected?(socket) and Phoenix.LiveView.static_changed?(socket),
      do: {:stale_static, url},
      else: :ok
  end

  defp workspace_external_url(id, host_id, params) do
    path =
      if Map.has_key?(params, "host"),
        do: ~p"/workspaces/#{id}?host=#{host_id}",
        else: ~p"/workspaces/#{id}"

    DevIdeWeb.Endpoint.url() <> path
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if Map.has_key?(socket.assigns, :tmux_session) do
        socket
        |> maybe_select_requested_tmux_window(params["window"])
        |> refresh_tmux_topology()
      else
        socket
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

  def handle_event("tmux:refresh_windows", _params, socket) do
    {:noreply, refresh_tmux_topology(socket)}
  end

  def handle_event("tmux:new_window", _params, socket) do
    socket = ensure_primary_tmux_session(socket)

    case tmux_adapter().new_window(socket.assigns.tmux_session, cwd: workspace_cwd(socket)) do
      {:ok, window_id} ->
        socket =
          socket
          |> refresh_tmux_topology()
          |> push_patch(to: workspace_window_path(socket, window_id))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create tmux window: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:select_window", %{"window-id" => window_id}, socket) do
    case tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
      :ok ->
        {:noreply,
         socket
         |> refresh_tmux_topology()
         |> push_patch(to: workspace_window_path(socket, window_id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not select tmux window: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:select_pane", %{"pane-id" => pane_id}, socket) do
    case tmux_adapter().select_pane(socket.assigns.tmux_session, pane_id) do
      :ok ->
        {:noreply, refresh_tmux_topology(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not select tmux pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:kill_pane", %{"pane-id" => pane_id}, socket) do
    case tmux_adapter().kill_pane(socket.assigns.tmux_session, pane_id) do
      :ok ->
        {:noreply, refresh_tmux_topology(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not close tmux pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:split_pane", %{"pane-id" => pane_id, "direction" => direction}, socket)
      when direction in ["h", "v"] do
    case tmux_adapter().split_pane(socket.assigns.tmux_session, pane_id, direction) do
      {:ok, _pane_id} ->
        {:noreply, refresh_tmux_topology(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not split tmux pane: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "tmux:resize_pane",
        %{"pane-id" => pane_id, "direction" => direction} = params,
        socket
      )
      when direction in ["left", "right", "up", "down"] do
    with {:ok, amount} <- parse_resize_amount(Map.get(params, "amount")),
         :ok <-
           tmux_adapter().resize_pane(socket.assigns.tmux_session, pane_id, direction, amount) do
      {:noreply, refresh_tmux_topology(socket)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not resize tmux pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:rename_start", %{"window-id" => window_id}, socket) do
    {:noreply, assign(socket, :tmux_rename_window_id, window_id)}
  end

  def handle_event("tmux:rename_cancel", _params, socket) do
    {:noreply, assign(socket, :tmux_rename_window_id, nil)}
  end

  def handle_event(
        "tmux:rename_window",
        %{"window" => %{"id" => window_id, "name" => name}},
        socket
      ) do
    rename_tmux_window(socket, window_id, name)
  end

  def handle_event("tmux:rename_window", %{"id" => window_id, "name" => name}, socket) do
    rename_tmux_window(socket, window_id, name)
  end

  def handle_event("tmux:kill_window", %{"window-id" => window_id}, socket) do
    case tmux_adapter().kill_window(socket.assigns.tmux_session, window_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:tmux_rename_window_id, nil)
         |> refresh_tmux_topology()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not close tmux window: #{inspect(reason)}")}
    end
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
     |> assign(:template_edit_form, template_edit_form())}
  end

  def handle_event("tmux:close_template_library", _params, socket) do
    {:noreply,
     socket
     |> assign(:template_library_open, false)
     |> assign(:template_edit_id, nil)
     |> assign(:template_edit_form, template_edit_form())}
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
         |> assign(:template_edit_form, template_edit_form(saved))}

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

  def handle_event("terminal:set_mode", %{"mode" => "governed"}, socket) do
    socket =
      socket
      |> cleanup_ghostty_resources_if_leaving()
      |> audit_terminal_mode_transition(socket.assigns[:terminal_mode], :governed)
      |> assign(:terminal_mode, :governed)
      |> maybe_schedule_raw_prewarm()

    {:noreply, socket}
  end

  # All-in on Ghostty: "raw" now starts the Ghostty component.
  # The old xterm.js raw path is deprecated for raw terminals.
  def handle_event("terminal:set_mode", %{"mode" => "raw"}, socket) do
    socket = refresh_workspace_mode(socket)

    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      socket =
        socket
        |> cleanup_ghostty_resources_if_leaving()
        |> start_ghostty_terminal()
        |> audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
        |> assign(:terminal_mode, :raw)
        # Request persisted split layout from client at a safe point
        # (after the Ghostty components have started mounting).
        |> push_event("request_saved_layout", %{
          "workspace_id" => socket.assigns.workspace.id
        })

      {:noreply, socket}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Raw shell requires manual workspace mode on the local host."
       )}
    end
  end

  # Legacy event name during transition. Still starts Ghostty, but we now normalize to :raw.
  def handle_event("terminal:set_mode", %{"mode" => "raw_ghostty"}, socket) do
    socket = refresh_workspace_mode(socket)

    if raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      {:noreply,
       socket
       |> start_ghostty_terminal()
       |> audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
       |> assign(:terminal_mode, :raw)
       |> push_event("request_saved_layout", %{"workspace_id" => socket.assigns.workspace.id})}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Raw Ghostty requires manual workspace mode on the local host."
       )}
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

  # Phase 2: Real tmux splits (independent panes)
  def handle_event("split_right", _params, socket) do
    do_split(socket, :horizontal)
  end

  def handle_event("split_down", _params, socket) do
    do_split(socket, :vertical)
  end

  # Param-less close for the palette ("Tmux: close focused pane"): the palette
  # resolves to a fixed payload and can't know the focused pane id, so we read
  # it here and delegate to the gated `close_pane` (which still guards the last
  # pane). No-op when there's no focused pane (e.g. non-terminal screens).
  def handle_event("pane:close_focused", _params, socket) do
    case socket.assigns[:focused_pane_id] do
      id when is_binary(id) -> handle_event("close_pane", %{"pane-id" => id}, socket)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pane:close_others", _params, socket) do
    focused_id = socket.assigns[:focused_pane_id]

    if is_binary(focused_id) do
      socket =
        (socket.assigns[:pane_data] || %{})
        |> Map.keys()
        |> Enum.reject(&(&1 == focused_id))
        |> Enum.reduce(socket, fn pane_id, acc ->
          {:noreply, acc} = handle_event("close_pane", %{"pane-id" => pane_id}, acc)
          acc
        end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pane:focus_next", _params, socket) do
    focus_relative_pane(socket, :next)
  end

  def handle_event("pane:focus_previous", _params, socket) do
    focus_relative_pane(socket, :previous)
  end

  def handle_event("pane:zoom_focused", _params, socket) do
    case socket.assigns[:focused_pane_id] do
      id when is_binary(id) -> handle_event("zoom_pane", %{"pane-id" => id}, socket)
      _ -> {:noreply, socket}
    end
  end

  # Pane focus is a UI concept only — each pane is its own tmux
  # session, so there's no `tmux select-pane` to call.
  def handle_event("focus_pane", %{"pane-id" => pane_id}, socket) do
    {:noreply, assign(socket, :focused_pane_id, pane_id)}
  end

  # Toggle "zoom" on a pane: render just that pane full-size (hiding the rest of
  # the split) or restore the full split. Double-tap/click drives this from the
  # client; the zoom button on the focused pane does too. The real @pane_layout
  # is preserved untouched — zoom only swaps what we hand TerminalSurface.
  def handle_event("zoom_pane", %{"pane-id" => pane_id}, socket) do
    new_zoom = if socket.assigns[:zoomed_pane_id] == pane_id, do: nil, else: pane_id

    {:noreply,
     socket
     |> assign(:zoomed_pane_id, new_zoom)
     |> assign(:focused_pane_id, pane_id)}
  end

  # Retry a pane whose Ghostty PTY/tmux startup failed (or that exited).
  # Clears the recorded error and re-invokes the start helper so the
  # user can recover without a full page reload.
  def handle_event("retry_pane", %{"pane-id" => pane_id}, socket) do
    if get_pane_data(socket, pane_id) do
      {:noreply,
       socket
       |> update_pane(pane_id, fn p -> %{p | error: nil} end)
       |> start_ghostty_for_pane(pane_id)}
    else
      {:noreply, socket}
    end
  end

  # Keyboard-driven pane navigation (Ctrl + Arrow keys).
  # Left/Right move horizontally, Up/Down move vertically within the
  # current split axis. Only changes focus within matching split levels.
  # Safe no-op on pages or tabs that do not have a pane layout.
  def handle_event("nav:dir", %{"dir" => dir_str}, socket)
      when dir_str in ["left", "right", "up", "down"] do
    if Map.has_key?(socket.assigns, :pane_layout) and
         Map.has_key?(socket.assigns, :focused_pane_id) do
      dir = String.to_existing_atom(dir_str)
      layout = socket.assigns.pane_layout
      current = socket.assigns.focused_pane_id

      case PaneLayout.neighbor(layout, current, dir) do
        nil ->
          {:noreply, socket}

        new_id when is_binary(new_id) ->
          {:noreply, focus_pane(socket, new_id)}
      end
    else
      {:noreply, socket}
    end
  end

  # Live resize of split ratios coming from the colocated SplitResizer hook.
  # The hook sends the two first-pane ids on either side of the gutter plus the
  # desired left ratio (0.1–0.9). We mutate only the matching split node in the tree.
  def handle_event("resize_split", %{"left" => left, "right" => right, "ratio" => r}, socket)
      when is_binary(left) and is_binary(right) do
    ratio =
      case r do
        n when is_number(n) -> n / 1
        s when is_binary(s) -> Float.parse(s) |> elem(0)
        _ -> 0.5
      end

    new_layout = resize_split(socket.assigns.pane_layout, left, right, ratio)

    {:noreply,
     socket
     |> put_pane_layout(new_layout)
     |> push_event("save_pane_layout", %{
       "workspace_id" => socket.assigns.workspace.id,
       "layout" => PaneLayout.to_json_layout(new_layout)
     })}
  end

  # Low-pri polish: equalize all splits in the tree to uniform ratios at every level.
  def handle_event("equalize_layout", _params, socket) do
    new_layout = equalize_layout(socket.assigns.pane_layout)

    socket =
      socket
      |> put_pane_layout(new_layout)
      |> assign(:equalize_flash, System.monotonic_time())
      |> push_event("save_pane_layout", %{
        "workspace_id" => socket.assigns.workspace.id,
        "layout" => PaneLayout.to_json_layout(new_layout)
      })

    Process.send_after(self(), :clear_equalize_flash, 650)
    {:noreply, socket}
  end

  # Restore a layout tree (from client localStorage on reconnect/remount) only if
  # the set of pane ids exactly matches the live pane_data (defensive against
  # stale browser storage after refresh or pane churn).
  def handle_event("restore_pane_layout", %{"layout" => raw}, socket) do
    case from_json_layout(raw) do
      nil ->
        {:noreply, put_persistence_status(socket, "restore: invalid layout json")}

      candidate ->
        current = Map.keys(socket.assigns.pane_data || %{}) |> MapSet.new()
        from_tree = collect_pane_ids(candidate) |> MapSet.new()

        if MapSet.equal?(current, from_tree) do
          {:noreply,
           socket
           |> put_pane_layout(candidate)
           |> put_persistence_status("restored (pane ids matched)")}
        else
          {:noreply, put_persistence_status(socket, "rejected (pane id set mismatch)")}
        end
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
          DevIDE.Terminals.GhosttySnapshot.capture(term, ws_id)

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
      collect_pane_ids(socket.assigns.pane_layout)
      |> Enum.map(fn id ->
        pane = get_pane_data(socket, id)
        term = pane && pane.ghostty_term
        if is_pid(term) and Process.alive?(term), do: {id, term}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    results =
      for {pane_id, term} <- panes_with_terms do
        %{base: base, files: files, preview: preview} =
          DevIDE.Terminals.GhosttySnapshot.capture(term, ws_id)

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
            (list |> Enum.map(fn {id, b} -> "#{id}→#{b}" end) |> Enum.join(", "))
      end

    {:noreply, put_flash(socket, :info, msg)}
  end

  # Attach to a fleet execution tmux session. The channel resolves the session
  # type from the sid (exec_*) and applies the governed-only policy itself; the
  # LiveView only forwards the sid.
  def handle_event(
        "attach_terminal_session",
        %{"session-id" => sid, "kind" => "execution"},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:terminal_sid, sid)
     |> assign(:terminal_mode, :governed)
     |> stream_active_sessions(socket.assigns.workspace.id)}
  end

  # Switch back to the workspace shell tab. The previous channel terminates
  # automatically when the wrapper id changes (phx-hook destroy → channel.leave
  # → Attachment.close in TerminalChannel.terminate/2).
  def handle_event("terminal:switch_to_shell", _params, socket) do
    sid = socket.assigns[:default_terminal_sid] || socket.assigns.terminal_sid

    {:noreply,
     socket
     |> assign(:terminal_sid, sid)
     |> assign(:terminal_mode, :governed)
     |> stream_active_sessions(socket.assigns.workspace.id)}
  end

  def handle_event("terminal:refresh_sessions", _params, socket) do
    {:noreply, stream_active_sessions(socket, socket.assigns.workspace.id)}
  end

  def handle_event("agents:refresh", _, socket), do: {:noreply, load_agents(socket)}

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

        DevIDE.Audit.emit!(%{
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
         |> maybe_schedule_raw_prewarm()
         |> refresh_audit_stream()}
    end
  end

  def handle_event("proposal:select", %{"path" => path}, socket) do
    {_decision, socket} =
      gate(socket, fn -> Policy.can_view_proposal?(policy_ctx(socket)) end, %{
        action: "proposal.viewed",
        target_type: "proposal",
        target_ref: path
      })

    case host_path(socket) do
      {:ok, root} ->
        case Proposals.parse(root, path) do
          {:ok, p} ->
            analysis = DevIDE.Proposals.ConflictAnalyzer.analyze(root, p)

            Audit.emit!(%{
              action: "proposal.analyzed",
              workspace_id: socket.assigns.workspace.id,
              actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
              target_type: "proposal",
              target_ref: path,
              metadata: %{
                "proposal_path" => path,
                "risk" => Atom.to_string(analysis.risk),
                "files_count" => analysis.files_count,
                "overlapping_files_count" => length(analysis.overlapping_files)
              }
            })

            {:noreply,
             socket
             |> assign(:selected_proposal, p)
             |> assign(:proposal_analysis, analysis)
             |> refresh_audit_stream()}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("proposal:clear", _, socket),
    do: {:noreply, socket |> assign(:selected_proposal, nil) |> assign(:proposal_analysis, nil)}

  def handle_event("agent_run:start", %{"id" => id}, socket) do
    caps = socket.assigns.agent_caps

    {decision, socket} =
      gate(
        socket,
        fn ->
          Policy.can_start_review_agent?(policy_ctx(socket, %{agent_run_id: id, caps: caps}))
        end,
        %{action: "agent.review_started", target_type: "agent_run", target_ref: id}
      )

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         {:ok, pid} <-
           DevIDE.Agents.Run.start(socket.assigns.workspace.id, root, id, caps),
         {:ok, snap} <- DevIDE.Agents.Run.subscribe(pid) do
      {:noreply, socket |> assign(:agent_run, snap) |> assign(:agent_run_error, nil)}
    else
      {:error, :already_running} ->
        {:noreply, attach_existing_agent_run(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :agent_run_error, "Run failed: #{inspect(reason)}")}

      _ ->
        {:noreply, assign(socket, :agent_run_error, "Run not allowed.")}
    end
  end

  def handle_event("agent_run:cancel", _, socket) do
    case DevIDE.Agents.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> DevIDE.Agents.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("run:start", %{"id" => id}, socket) do
    if interactive_agent?(id) do
      launch_interactive_agent(socket, id)
    else
      start_batch_run(socket, id)
    end
  end

  def handle_event("run_ledger:select", %{"id" => id}, socket) do
    {:noreply, refresh_run_ledger(socket, id)}
  end

  def handle_event("run_ledger:open", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:tab, "run")
     |> assign(:audit_drawer_open, false)
     |> attach_existing_run()
     |> refresh_run_ledger(id)}
  end

  def handle_event("palette:open", _, socket) do
    # The active screen picks the default category tab, so opening the palette
    # over the terminal lands on Tmux verbs, over the editor on Files, etc.
    category = default_palette_category(socket.assigns[:tab])
    socket = assign(socket, :palette_category, category)
    items = palette_query(socket, "")

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_query, "")
     |> assign(:palette_items, items)
     |> assign(:palette_selected_idx, 0)}
  end

  # Open the palette scoped to tmux / IDE actions (triggered by a JS hook when
  # the user presses the IDE command keybind inside the governed terminal).
  def handle_event("palette:ide", _, socket) do
    socket = assign(socket, :palette_category, :tmux)
    items = palette_query(socket, "")

    {:noreply,
     socket
     |> assign(:palette_open, true)
     |> assign(:palette_query, "")
     |> assign(:palette_items, items)
     |> assign(:palette_selected_idx, 0)}
  end

  # Cycle the category tab (Tab / Shift+Tab from PaletteHook, or arrow on the
  # tab strip). Re-runs the current query scoped to the new category.
  def handle_event("palette:category", %{"dir" => dir}, socket) when dir in ["next", "prev"] do
    current = socket.assigns[:palette_category] || :all
    next = cycle_palette_category(current, dir)
    {:noreply, apply_palette_category(socket, next)}
  end

  # Direct selection by clicking a tab in the strip.
  def handle_event("palette:category", %{"category" => name}, socket) do
    case parse_palette_category(name) do
      {:ok, cat} -> {:noreply, apply_palette_category(socket, cat)}
      :error -> {:noreply, socket}
    end
  end

  # Arrow-key navigation pushed from PaletteHook while the modal is open.
  # Wraps at both ends so the list feels infinite.
  def handle_event("palette:nav", %{"dir" => dir}, socket) do
    n = length(socket.assigns[:palette_items] || [])

    if n == 0 do
      {:noreply, socket}
    else
      cur = socket.assigns[:palette_selected_idx] || 0

      next =
        case dir do
          "up" -> rem(cur - 1 + n, n)
          "down" -> rem(cur + 1, n)
          _ -> cur
        end

      {:noreply, assign(socket, :palette_selected_idx, next)}
    end
  end

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

  def handle_event("palette:close", _, socket) do
    {:noreply, assign(socket, :palette_open, false)}
  end

  def handle_event("palette:query", %{"query" => q}, socket) do
    {:noreply,
     socket
     |> assign(:palette_query, q)
     |> assign(:palette_items, palette_query(socket, q))
     |> assign(:palette_selected_idx, 0)}
  end

  def handle_event("palette:find_pane", _params, socket) do
    query = "pane"

    socket =
      socket
      |> assign(:palette_open, true)
      |> assign(:palette_category, :tmux)
      |> assign(:palette_query, query)

    {:noreply,
     socket
     |> assign(:palette_items, palette_query(socket, query))
     |> assign(:palette_selected_idx, 0)}
  end

  def handle_event("palette:templates", _params, socket) do
    query = "template"

    socket =
      socket
      |> assign(:palette_open, true)
      |> assign(:palette_category, :tmux)
      |> assign(:palette_query, query)

    {:noreply,
     socket
     |> assign(:palette_items, palette_query(socket, query))
     |> assign(:palette_selected_idx, 0)}
  end

  # Form submit (Enter). Prefer the explicitly-selected id from arrow-nav;
  # fall back to top item for safety. Empty → just close.
  def handle_event("palette:execute", %{"_selected_id" => ""}, socket),
    do: {:noreply, assign(socket, :palette_open, false)}

  def handle_event("palette:execute", %{"_selected_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("palette:execute", %{"_top_id" => id}, socket),
    do: handle_event("palette:execute", %{"id" => id}, socket)

  def handle_event("palette:execute", %{"id" => id}, socket) do
    root =
      case host_path(socket) do
        {:ok, r} -> r
        _ -> nil
      end

    case resolve_palette_item(socket, root, id) do
      {:ok, %{event: event, params: params}} ->
        socket = assign(socket, :palette_open, false)
        __MODULE__.handle_event(event, params, socket)

      :error ->
        {:noreply, assign(socket, :palette_open, false)}
    end
  end

  def handle_event("search:run", %{"query" => query}, socket) do
    case host_loc(socket) do
      {:ok, loc} ->
        case DevIDE.Workspaces.FileAccess.search(loc, String.trim(query), []) do
          {:ok, results} ->
            state = if results == [], do: :empty, else: :ok

            {:noreply,
             socket
             |> assign(:search_query, query)
             |> assign(:search_results, results)
             |> assign(:search_state, state)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:search_query, query)
             |> assign(:search_results, [])
             |> assign(:search_state, {:error, reason})}
        end

      _ ->
        {:noreply, assign(socket, :search_state, {:error, :no_root})}
    end
  end

  def handle_event("annotation:open", %{"path" => path} = params, socket) do
    line = parse_line(params["line"])

    case host_path(socket) do
      {:ok, root} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            payload = %{path: file.path, content: file.content, version: file.version}
            payload = if line, do: Map.put(payload, :line, line), else: payload

            {:noreply,
             socket
             |> assign(:tab, "files")
             |> assign(:open_file, file)
             |> assign(:file_error, nil)
             |> assign(:save_error, nil)
             |> load_diff(file.path)
             |> push_event("file:loaded", payload)}

          {:error, reason} ->
            {:noreply, assign(socket, :file_error, format_file_error(reason))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("preview:dismiss_candidate", %{"url" => url}, socket) do
    key = candidate_url_key(url)

    socket =
      socket
      |> assign(
        :preview_candidates,
        Map.delete(socket.assigns[:preview_candidates] || %{}, url)
      )
      |> assign(
        :dismissed_preview_candidate_urls,
        put_candidate_url(socket.assigns[:dismissed_preview_candidate_urls], key)
      )

    {:noreply, socket}
  end

  def handle_event("preview:dismiss_candidate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("preview:open", %{"source" => "detected"} = params, socket) do
    candidate =
      preview_candidate_for_url(socket, params["url"]) || best_manual_preview_candidate(socket)

    case candidate do
      nil ->
        {:noreply, put_flash(socket, :error, "No dev server URL detected yet")}

      candidate ->
        params =
          params
          |> Map.delete("source")
          |> Map.put("url", candidate.url)
          |> Map.put_new("pane_id", candidate.pane_id)
          |> Map.put_new("session_id", candidate.session_id)

        open_preview(socket, params)
    end
  end

  def handle_event("preview:open", %{"surface" => surface} = params, socket) do
    open_surface_preview(socket, surface, params)
  end

  def handle_event("preview:observe", _params, socket) do
    refresh_preview_observation(socket, :observe)
  end

  def handle_event("preview:screenshot", _params, socket) do
    refresh_preview_observation(socket, :screenshot)
  end

  def handle_event("preview:click", %{"selector" => selector}, socket)
      when is_binary(selector) and selector != "" do
    run_preview_control_action(socket, "click", fn id ->
      DevIDE.PreviewControl.click(id, %{selector: selector})
    end)
  end

  def handle_event("preview:click", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a CSS selector to click")}
  end

  def handle_event("preview:type", %{"selector" => selector, "text" => text}, socket)
      when is_binary(selector) and selector != "" do
    run_preview_control_action(socket, "type", fn id ->
      DevIDE.PreviewControl.type(id, selector, text || "")
    end)
  end

  def handle_event("preview:type", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter a selector and text to type")}
  end

  def handle_event("preview:press", %{"key" => key}, socket)
      when is_binary(key) and key != "" do
    run_preview_control_action(socket, "press", fn id ->
      DevIDE.PreviewControl.press(id, key)
    end)
  end

  def handle_event("preview:open", %{"url" => _url} = params, socket) do
    open_preview(socket, params)
  end

  def handle_event("preview:close", %{"id" => id}, socket) do
    workspace_id = socket.assigns.workspace.id

    case DevIDE.Previews.get_for_workspace(id, workspace_id) do
      %DevIDE.Previews.Preview{} = preview ->
        _ = close_active_preview_control(socket)

        case DevIDE.Previews.close(preview) do
          {:ok, _} ->
            {:noreply,
             socket
             |> stream_previews(workspace_id)
             |> assign(:active_preview, nil)
             |> assign(:active_preview_observation, nil)
             |> assign(:active_preview_control_session, nil)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to close preview")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Preview not found")}
    end
  end

  def handle_event("preview:activate", %{"id" => id}, socket) do
    workspace_id = socket.assigns.workspace.id

    case DevIDE.Previews.get_for_workspace(id, workspace_id) do
      %DevIDE.Previews.Preview{} = preview ->
        socket =
          socket
          |> ensure_preview_control(preview)
          |> assign(
            :active_preview,
            if(preview.mode == :iframe and preview.trusted, do: preview, else: nil)
          )

        if preview.mode == :iframe and preview.trusted do
          {:noreply, socket}
        else
          {:noreply,
           push_event(socket, "open-preview-tab", %{url: preview.url, title: preview.title})}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Preview not found")}
    end
  end

  def handle_event("run:cancel", _, socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> Commands.Run.cancel(pid)
      _ -> :ok
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

  def handle_event("tree:toggle", %{"path" => path}, socket) do
    case Map.get(socket.assigns.tree, path) do
      {:expanded, _} ->
        {:noreply, update(socket, :tree, &Map.put(&1, path, {:collapsed, []}))}

      _ ->
        {:noreply, load_tree(socket, path)}
    end
  end

  def handle_event("tree:select_dir", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_dir, path)}
  end

  def handle_event("tree:new_form", %{"kind" => kind}, socket) when kind in ["file", "dir"] do
    {:noreply,
     assign(socket, :new_input, {String.to_existing_atom(kind), socket.assigns.selected_dir})}
  end

  def handle_event("tree:cancel_new", _, socket), do: {:noreply, assign(socket, :new_input, nil)}

  def handle_event("tree:create", %{"name" => name}, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.create",
        target_type: "tree_node",
        target_ref: String.trim(name)
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {kind, dir} when kind in [:file, :dir] <- socket.assigns.new_input,
         {:ok, root} <- host_path(socket),
         rel = Path.join(dir, String.trim(name)),
         :ok <- do_create(kind, root, rel) do
      {:noreply,
       socket
       |> assign(:new_input, nil)
       |> assign(:tree_error, nil)
       |> refresh_tree()
       |> refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :tree_error, "Create failed: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:refresh", _, socket) do
    {:noreply, socket |> refresh_tree() |> refresh_git_status()}
  end

  def handle_event("file:rename_form", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :rename_input, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:rename_cancel", _, socket),
    do: {:noreply, assign(socket, :rename_input, nil)}

  def handle_event("file:rename_submit", %{"new_path" => new_path}, socket) do
    new_path = String.trim(new_path)

    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.renamed",
        target_type: "file",
        target_ref: new_path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- host_path(socket),
         %{path: from} = _open <- socket.assigns.open_file,
         :ok <- Files.rename(root, from, new_path) do
      case Files.read_text(root, new_path) do
        {:ok, file} ->
          {:noreply,
           socket
           |> assign(:open_file, file)
           |> assign(:rename_input, nil)
           |> refresh_tree()
           |> refresh_git_status()
           |> push_event("file:loaded", %{
             path: file.path,
             content: file.content,
             version: file.version
           })}

        _ ->
          {:noreply,
           socket
           |> assign(:open_file, nil)
           |> assign(:rename_input, nil)
           |> refresh_tree()
           |> push_event("file:cleared", %{})}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("file:delete_request", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :delete_confirm, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:delete_cancel", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("file:delete_confirm", _, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.deleted",
        target_type: "file",
        target_ref: socket.assigns.delete_confirm
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         rel when is_binary(rel) <- socket.assigns.delete_confirm,
         {:ok, root} <- host_path(socket),
         :ok <- Files.delete(root, rel) do
      {:noreply,
       socket
       |> assign(:open_file, nil)
       |> assign(:delete_confirm, nil)
       |> assign(:file_diff, nil)
       |> refresh_tree()
       |> refresh_git_status()
       |> push_event("file:cleared", %{})}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_error, "Delete failed: #{inspect(reason)}")
         |> assign(:delete_confirm, nil)}

      _ ->
        {:noreply, assign(socket, :delete_confirm, nil)}
    end
  end

  def handle_event("file:refresh", _, socket) do
    case {socket.assigns.open_file, host_path(socket)} do
      {%{path: path}, {:ok, root}} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:open", %{"path" => path}, socket) do
    case host_loc(socket) do
      {:ok, loc} ->
        case DevIDE.Workspaces.FileAccess.read_text(loc, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> assign(:file_error, nil)
             |> assign(:save_error, nil)
             |> load_diff(file.path)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> assign(:file_diff, nil)
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "file:save",
        %{"path" => path, "content" => content, "version" => version},
        socket
      ) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.save",
        target_type: "file",
        target_ref: path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, loc} <- host_loc(socket),
         %{path: ^path, version: ^version} = open <- socket.assigns.open_file,
         {:ok, %{version: new_version}} <-
           DevIDE.Workspaces.FileAccess.write_text(loc, path, content, open.version) do
      updated = %{open | content: content, size: byte_size(content), version: new_version}

      {:noreply,
       socket
       |> assign(:open_file, updated)
       |> assign(:save_error, nil)
       |> refresh_git_status()
       |> load_diff(path)
       |> push_event("save:ok", %{version: new_version})}
    else
      {:error, :conflict} ->
        {:noreply,
         assign(socket, :save_error, "Conflict: file changed on disk. Reopen to reload.")}

      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, assign(socket, :save_error, "Save aborted: open file changed.")}
    end
  end

  def handle_event("close_pane", %{"pane-id" => pane_id}, socket) do
    if map_size(socket.assigns.pane_data) <= 1 do
      {:noreply, put_flash(socket, :error, "Cannot close the last pane")}
    else
      pane = get_pane_data(socket, pane_id)

      if pane do
        # Workers are start_link'd from the LV process, so we must unlink
        # before stopping — otherwise :shutdown cascades and kills the LV
        # itself (it doesn't trap exits).
        stop_pane_worker(pane.worker)

        if pane.tmux_session do
          # Kill off the LiveView's reduction budget — a slow/absent tmux must
          # not block the handle_event. unsubscribe is the durable signal; the
          # janitor also reaps idle sessions if this kill is lost.
          session = pane.tmux_session

          Task.start(fn ->
            System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
          end)

          DevIDE.Terminals.TmuxJanitor.unsubscribe(session)
        end

        if is_pid(pane.ghostty_term) and Process.alive?(pane.ghostty_term) do
          Process.unlink(pane.ghostty_term)
          Process.exit(pane.ghostty_term, :shutdown)
        end
      end

      new_layout = remove_pane_from_layout(socket.assigns.pane_layout, pane_id)

      new_focus =
        if socket.assigns.focused_pane_id == pane_id do
          first_pane_id(new_layout)
        else
          socket.assigns.focused_pane_id
        end

      new_zoom =
        if socket.assigns[:zoomed_pane_id] == pane_id,
          do: nil,
          else: socket.assigns[:zoomed_pane_id]

      {:noreply,
       socket
       |> put_pane_layout(new_layout)
       |> assign(:pane_data, Map.delete(socket.assigns.pane_data, pane_id))
       |> put_pane_refresh_pending(MapSet.delete(get_pane_refresh_pending(socket), pane_id))
       |> assign(:pane_pty_buffer, Map.delete(socket.assigns.pane_pty_buffer, pane_id))
       |> assign(:focused_pane_id, new_focus)
       |> assign(:zoomed_pane_id, new_zoom)
       |> push_event("save_pane_layout", %{
         "workspace_id" => socket.assigns.workspace.id,
         "layout" => PaneLayout.to_json_layout(new_layout)
       })}
    end
  end

  # A "split" is purely a UI concept: each browser pane owns its own tmux
  # session (so distinct shells render in distinct boxes), and the layout
  # tree is just our own bookkeeping. We do not call `tmux split-window`
  # — that puts multiple panes inside one tmux client whose focus is
  # session-scoped, which defeats the multi-shell story.
  defp do_split(socket, direction) do
    socket = refresh_workspace_mode(socket)

    if not raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      {:noreply, socket}
    else
      # Defensive guard: if focused_pane_id is stale (after rejected restore or previous crash),
      # fall back to a valid pane so the split always succeeds.
      layout = socket.assigns.pane_layout
      focused_id = socket.assigns.focused_pane_id
      valid_ids = PaneLayout.collect_pane_ids(layout) |> MapSet.new()

      focused_id =
        if focused_id && MapSet.member?(valid_ids, focused_id) do
          focused_id
        else
          PaneLayout.first_pane_id(layout) || "pane-1"
        end

      new_pane_id = "pane-#{System.unique_integer([:positive])}"

      new_pane = %{
        ghostty_term: nil,
        ghostty_pty: nil,
        worker: nil,
        backend: nil,
        session_sid: derived_pane_sid(socket.assigns.terminal_sid, new_pane_id),
        tmux_session: derived_pane_session(socket.assigns.tmux_session, new_pane_id),
        cols: 80,
        rows: 40,
        error: nil
      }

      new_layout =
        split_layout(socket.assigns.pane_layout, focused_id, new_pane_id, direction)

      {:noreply,
       socket
       |> put_pane_layout(new_layout)
       |> add_pane(new_pane_id, new_pane)
       |> focus_pane(new_pane_id)
       |> start_ghostty_for_pane(new_pane_id)
       |> push_event("save_pane_layout", %{
         "workspace_id" => socket.assigns.workspace.id,
         "layout" => PaneLayout.to_json_layout(new_layout)
       })}
    end
  end

  # Deterministic per-pane session name so debug tooling (e.g. tmux ls)
  # makes the relationship obvious. Stays under tmux's name length limits
  # because both halves are short by construction.
  defp derived_pane_session(workspace_session, pane_id),
    do: "#{workspace_session}-#{pane_id}"

  defp derived_pane_sid(base_sid, pane_id),
    do: "#{base_sid}-#{pane_id}"

  @impl true
  def handle_info({:source_log, ref, line}, %{assigns: %{log_ref: ref}} = socket) do
    entry = %{id: "log-#{System.unique_integer([:positive])}", text: line}

    {:noreply, stream_insert(socket, :log_lines, entry, at: -1, limit: -@max_log_lines)}
  end

  def handle_info(:clear_equalize_flash, socket) do
    {:noreply, assign(socket, :equalize_flash, nil)}
  end

  def handle_info({TmuxTopology, {:updated, %{session: session} = topology}}, socket) do
    socket =
      if socket.assigns[:tmux_session] == session do
        assign_tmux_topology(socket, topology)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({TmuxTopology, {:session_terminated, %{session: session}}}, socket) do
    socket =
      if socket.assigns[:tmux_session] == session do
        socket
        |> assign(:tmux_windows, [])
        |> assign(:tmux_panes, [])
        |> assign(:tmux_active_window_id, nil)
        |> assign(:tmux_active_pane_id, nil)
        |> assign(:tmux_topology_version, 0)
      else
        socket
      end

    {:noreply, socket}
  end

  # Ghostty experimental raw terminal (Phase 1 spike).
  # The LiveTerminal component reports its fitted dimensions once the DOM
  # is measured. We use that to spawn tmux under a real PTY so we get the
  # same shell-survives-BEAM-restart property as the existing raw path,
  # but now with a server-authoritative cell grid.
  # The Ghostty component's id is "ghostty-<pane_id>" (see TerminalSurface);
  # strip the prefix, then forward the browser-measured dimensions to the
  # pane's worker so term + PTY stay in sync with what the user sees.
  def handle_info({:terminal_ready, "ghostty-" <> pane_id, cols, rows}, socket) do
    case get_pane_data(socket, pane_id) do
      %{worker: worker, tmux_session: tmux_session} when is_pid(worker) ->
        DevIdeWeb.WorkspaceLive.PaneWorker.resize(worker, cols, rows)
        # PTY-driven resize (SIGWINCH) usually suffices, but with `tmux
        # new-session -A` re-attaching to sessions that survive across BEAM /
        # page-reload cycles, tmux's window-size policy sometimes pins the
        # pane to a prior client's size instead of growing to the new client.
        # Force the window to the fitted size explicitly. Offloaded to a
        # fire-and-forget Task so the LiveView process is not blocked by the
        # System.cmd calls inside resize_window and apply_defaults (~50-200ms
        # of tmux subprocess overhead each).
        Task.start(fn ->
          _ = DevIDE.Terminals.Tmux.resize_window(tmux_session, cols, rows)
          # Apply dev_ide's standard tmux options (mouse, escape-time,
          # history-limit, focus-events, passthrough, clipboard, truecolor,
          # renumber-windows). Idempotent — safe per ready.
          _ = DevIDE.Terminals.Tmux.apply_defaults(tmux_session)
        end)

        socket = update_pane(socket, pane_id, fn p -> %{p | cols: cols, rows: rows} end)

        socket =
          if tmux_session == socket.assigns.tmux_session,
            do: refresh_tmux_topology(socket),
            else: socket

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:terminal_ready, _other_id, _cols, _rows}, socket),
    do: {:noreply, socket}

  # Tagged PTY output from a specific pane's worker. Two layers of
  # coalescing share the same @pane_refresh_interval_ms window:
  #
  #   1. Bytes are appended to a per-pane iolist buffer in :pane_pty_buffer
  #      (no `Ghostty.Terminal.write` GenServer.call yet).
  #   2. At flush time, the buffered iolist is written once and the
  #      LiveComponent is refreshed once.
  #
  # Tmux attach + bursty shell output (e.g. `cat largefile`) used to fire
  # dozens of GenServer.calls + send_updates inside tens of ms, producing
  # the visible "history scrolls up into place" flicker on load AND
  # serialising the LV process on terminal writes. Now both are O(1)
  # per pane per frame.
  @pane_refresh_interval_ms 16

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
        socket =
          socket
          |> push_osc52_clipboard(data)
          |> remember_preview_candidates(pane_id, data)

        reply =
          case get_pane_data(socket, pane_id) do
            %{ghostty_term: term} when is_pid(term) ->
              # Append to the pane's iolist buffer. Iolists are cheap to
              # extend in head position; we reverse on drain.
              buffer = socket.assigns.pane_pty_buffer
              prev = Map.get(buffer, pane_id, [])
              new_buffer = Map.put(buffer, pane_id, [data | prev])
              socket = assign(socket, :pane_pty_buffer, new_buffer)

              pending = get_pane_refresh_pending(socket)

              s =
                if MapSet.member?(pending, pane_id) do
                  socket
                else
                  Process.send_after(self(), {:pty_flush, pane_id}, @pane_refresh_interval_ms)
                  put_pane_refresh_pending(socket, MapSet.put(pending, pane_id))
                end

              {:noreply, s}

            _ ->
              {:noreply, socket}
          end

        {reply, %{}}
      end
    )
  end

  # Coalesced flush — drains the pane's iolist into Ghostty.Terminal in a
  # single GenServer.call, then pushes one component refresh. Fires at
  # most once per pane per frame.
  def handle_info({:pty_flush, pane_id}, socket) do
    :telemetry.span(
      [:dev_ide, :workspace_live, :pty_flush],
      %{pane_id: pane_id},
      fn ->
        pending = get_pane_refresh_pending(socket)
        socket = put_pane_refresh_pending(socket, MapSet.delete(pending, pane_id))

        # Always pop the buffer so a fired timer is fully resolved even
        # if the pane vanished between schedule and flush.
        buffer = socket.assigns.pane_pty_buffer
        {chunks_rev, buffer} = Map.pop(buffer, pane_id, [])
        socket = assign(socket, :pane_pty_buffer, buffer)

        reply =
          case {chunks_rev, get_pane_data(socket, pane_id)} do
            {[], _} ->
              {:noreply, socket}

            {chunks_rev, %{ghostty_term: term}} when is_pid(term) ->
              # iolist write: one GenServer.call regardless of how many
              # {:pty_data, ...} messages were coalesced into this frame.
              Ghostty.Terminal.write(term, Enum.reverse(chunks_rev))

              send_update(Ghostty.LiveTerminal.Component,
                id: "ghostty-" <> pane_id,
                refresh: true
              )

              {:noreply, socket}

            _ ->
              # Pane closed between schedule and flush — buffered bytes
              # are dropped (already popped above).
              {:noreply, socket}
          end

        {reply, %{}}
      end
    )
  end

  # PaneWorker reports its own death (or its PTY's) — clear the pane's pids
  # (and record the exit reason in `error`) so the next render shows a
  # diagnostic error state + Retry button instead of an infinite
  # "starting terminal…" placeholder. This surfaces PTY/tmux launch
  # failures (bad TERM, missing binary, permission issues, etc.) that
  # used to leave the raw Ghostty pane stuck.
  def handle_info({:pty_exit, pane_id, status}, socket) do
    pending = get_pane_refresh_pending(socket)

    # Always clear the pending marker (timer/coalesce invariant) and
    # any buffered bytes — the receiving term is dead, writing them
    # would just error. Only touch pane_data if the pane still exists
    # (prevents update_pane from inserting `pane_id => nil` for a
    # just-closed or unknown pane).
    socket =
      socket
      |> put_pane_refresh_pending(MapSet.delete(pending, pane_id))
      |> assign(:pane_pty_buffer, Map.delete(socket.assigns.pane_pty_buffer, pane_id))

    socket =
      if get_pane_data(socket, pane_id) do
        update_pane(socket, pane_id, fn p ->
          %{p | ghostty_pty: nil, ghostty_term: nil, worker: nil, backend: nil, error: status}
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  # Deferred post-mount work (see mount/3). These were the FS, git, DB and
  # agent loads that used to block the initial render. Running them here means
  # the user sees the (empty) terminal chrome immediately; a follow-up diff
  # populates the side panels a few ms later.
  def handle_info(:after_mount, socket) do
    unless connected?(socket), do: {:noreply, socket}

    socket =
      socket
      |> stream_previews(socket.assigns.workspace.id)
      |> assign_workspace_mode(socket.assigns.workspace.id, true)
      # Ghostty/PTY first — the user is staring at the empty terminal frame
      # and this is the most visible follow-up paint.
      |> maybe_start_raw_ghostty_and_request_restore(
        socket.assigns.terminal_mode,
        socket.assigns.workspace.id
      )
      |> refresh_tmux_topology()
      |> maybe_schedule_raw_prewarm()
      |> load_tree("")
      |> refresh_git_status()
      |> attach_existing_run()
      |> refresh_run_ledger()
      |> load_agents()
      # audit + side-panel population intentionally after first paint (see #3 perf work)
      |> refresh_isolation(audit: true)
      |> load_project_meta()
      |> maybe_auto_open_agent_preview()

    {:noreply, socket}
  end

  def handle_info(:agent_preview_screenshot, socket) do
    {:noreply, capture_agent_preview_screenshot(socket)}
  end

  # Live observation push from PreviewControl (agent-driven MCP browsing, or
  # another viewer acting on the same preview). Update only when it targets the
  # preview this panel is currently showing.
  def handle_info(
        {:preview_observation, %{preview_id: preview_id, observation: observation}},
        socket
      ) do
    case socket.assigns[:active_preview] do
      %{id: ^preview_id} ->
        {:noreply, assign(socket, :active_preview_observation, observation)}

      _ ->
        {:noreply, socket}
    end
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
    updated = Map.update!(run, :buffer, fn b -> cap_buffer(b <> bin) end)
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
    updated = Map.update!(run, :buffer, fn b -> cap_buffer(b <> bin) end)
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
  def terminate(_reason, socket) do
    _ = cleanup_ghostty_resources(socket)
    :ok
  end

  ## Helpers

  # Matches OSC 52 set-clipboard: ESC ] 52 ; <sel> ; <base64> (BEL | ST).
  # A `?` in the data position is a query, not a set — its lack of base64
  # chars means it simply doesn't match (we ignore queries).
  # Base64 payload is length-capped so a program in the user's own shell can't
  # emit a multi-MB OSC52 and force unbounded decode + push_event per frame.
  # 65500 is the PCRE {} quantifier ceiling; ~64 KB base64 ≈ 48 KB of clipboard
  # text — generous for real copies.
  @osc52_re ~r/\x1b\]52;[^;]*;([A-Za-z0-9+\/=]{1,65500})(?:\x07|\x1b\\)/
  @osc52_max_matches 4

  defp push_osc52_clipboard(socket, data) do
    # Fast path: skip the regex on the vast majority of chunks that carry no
    # clipboard escape.
    if :binary.match(data, "\x1b]52;") == :nomatch do
      socket
    else
      do_push_osc52_clipboard(socket, data)
    end
  end

  defp do_push_osc52_clipboard(socket, data) do
    case Regex.scan(@osc52_re, data, capture: :all_but_first) do
      [] ->
        socket

      matches ->
        matches
        |> Enum.take(@osc52_max_matches)
        |> Enum.reduce(socket, fn [b64], s ->
          case Base.decode64(b64) do
            {:ok, text} when text != "" ->
              push_event(s, "clipboard:write", %{"text" => text})

            _ ->
              s
          end
        end)
    end
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

  defp host_path(%{assigns: %{host_path: {:ok, root}}}), do: {:ok, root}
  defp host_path(_), do: :error

  defp host_loc(%{assigns: %{host_loc: {:ok, loc}}}), do: {:ok, loc}
  defp host_loc(_), do: :error

  # Delegates to central implementation in ChannelAuth to avoid duplication
  # of {:ok, _} / legacy result unwrapping for capability claims.
  defp workspace_loc_for_capability(result), do: ChannelAuth.normalize_workspace_loc(result)

  defp assign_workspace_mode(socket, ws_id, connected? \\ true)

  defp assign_workspace_mode(socket, ws_id, true) do
    {mode, source} = DevIDE.Workspaces.State.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign(:workspace_record, load_record(ws_id))
  end

  defp assign_workspace_mode(socket, _ws_id, false) do
    assign(socket, :workspace_record, nil)
  end

  defp previews_for_mount(socket, workspace_id) do
    if connected?(socket), do: DevIDE.Previews.list_for_workspace(workspace_id), else: []
  end

  defp refresh_workspace_mode(%{assigns: %{workspace: %{id: ws_id}}} = socket)
       when is_binary(ws_id) do
    assign_workspace_mode(socket, ws_id)
  end

  defp refresh_workspace_mode(socket), do: socket

  defp load_record(ws_id) do
    case DevIDE.Workspaces.State.get(ws_id) do
      {:ok, r} -> r
      _ -> nil
    end
  end

  defp policy_ctx(socket, extra \\ %{}) do
    user = socket.assigns[:current_user] || %{}
    ws = socket.assigns.workspace

    base = %{
      workspace_id: ws.id,
      workspace_user: Map.get(ws, :user),
      workspace_mode_source: socket.assigns[:workspace_mode_source],
      actor_username: Map.get(user, :username) || Map.get(user, :id),
      actor_id: Map.get(user, :id),
      db_isolation: (socket.assigns[:db_isolation] || %{}) |> Map.get(:isolation)
    }

    Map.merge(base, extra)
  end

  defp refresh_isolation(socket, opts) do
    iso =
      case host_path(socket) do
        {:ok, root} -> DevIDE.Workspaces.Isolation.detect(socket.assigns.workspace, root)
        _ -> %DevIDE.Workspaces.DbIsolation{detected_at: DateTime.utc_now()}
      end

    _ = DevIDE.Workspaces.State.persist_isolation(socket.assigns.workspace.id, iso)

    if Keyword.get(opts, :audit, false) do
      DevIDE.Audit.emit!(%{
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
    |> refresh_audit_stream()
  end

  defp can_set_mode?(:config_override), do: false
  defp can_set_mode?(_), do: true

  defp string_to_mode("manual"), do: :manual
  defp string_to_mode("review"), do: :review
  defp string_to_mode("agent_write_locked"), do: :agent_write_locked
  defp string_to_mode("shared_stage_guarded"), do: :shared_stage_guarded
  defp string_to_mode(_), do: nil

  defp gate(socket, decision_fun, audit_attrs) do
    decision = decision_fun.()
    attrs = Map.put_new(audit_attrs, :workspace_id, socket.assigns.workspace.id)
    event = Audit.emit_decision(decision, attrs)

    {decision, socket |> assign(:last_decision, decision) |> refresh_audit_stream()}
    |> tap(fn _ -> _ = event end)
  end

  defp refreshed_audit(socket) do
    Audit.recent_for(socket.assigns.workspace.id, 50)
  end

  defp refresh_audit_stream(socket) do
    if connected?(socket) do
      events = refreshed_audit(socket)

      socket
      |> stream(:audit_events, events, reset: true)
      |> assign(:audit_events_count, length(events))
      |> assign(:audit_deny_count, deny_count(events))
      |> assign(:audit_ledger_count, ledger_event_count(events))
    else
      socket
    end
  end

  defp stream_previews(socket, workspace_id) do
    previews = DevIDE.Previews.list_for_workspace(workspace_id)

    socket
    |> stream(:previews, previews, reset: true)
    |> assign(:previews_count, length(previews))
  end

  defp stream_active_sessions(socket, workspace_id) do
    sessions = Terminals.list_attachable(workspace_id)
    executions = Enum.filter(sessions, &(&1.kind == :execution))

    socket
    |> stream(:active_sessions, executions, reset: true)
    |> assign(:active_executions?, executions != [])
  end

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

  defp refresh_run_ledger(socket, selected_run_id \\ nil) do
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

  defp ledger_command_decision(decision, socket, command_id, run_id) do
    attrs = %{
      workspace_id: socket.assigns.workspace.id,
      actor_id: current_actor_id(socket),
      command_id: command_id,
      run_id: run_id,
      plane: "safe_action",
      metadata: %{
        source: "ui",
        trigger: "manual",
        protocol: "devide.immediate.v1",
        command_id: command_id,
        safe_action_id: "command:" <> command_id,
        db_isolation: (socket.assigns[:db_isolation] || %{}) |> Map.get(:isolation)
      }
    }

    if DevIDE.Policy.Decision.allow?(decision) do
      Ledger.command_requested(attrs)
    else
      Ledger.command_denied(decision, attrs)
    end
  end

  defp current_actor_id(socket),
    do: (socket.assigns[:current_user] || %{}) |> Map.get(:id)

  defp load_tree(socket, path) do
    case socket.assigns[:host_loc] do
      {:ok, {:remote, _host, _root} = loc} ->
        case DevIDE.Workspaces.FileAccess.ls(loc, path) do
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

  defp format_file_error(:too_large), do: "File too large."
  defp format_file_error(:binary), do: "Binary content — refused."
  defp format_file_error(:not_a_file), do: "Not a regular file."
  defp format_file_error(:outside_root), do: "Path outside workspace root."
  defp format_file_error(:symlink_escape), do: "Symlink escapes workspace root."
  defp format_file_error(:conflict), do: "Conflict: file changed on disk."
  defp format_file_error(other), do: "Error: #{inspect(other)}"

  defp refresh_git_status(socket) do
    case host_loc(socket) do
      {:ok, loc} ->
        case DevIDE.Workspaces.FileAccess.git_status_short(loc) do
          {:ok, entries} -> assign(socket, :git_status, entries)
          _ -> assign(socket, :git_status, [])
        end

      _ ->
        assign(socket, :git_status, [])
    end
  end

  defp do_create(:file, root, rel) do
    case Files.create_file(root, rel) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp do_create(:dir, root, rel), do: Files.create_dir(root, rel)

  defp refresh_tree(socket) do
    expanded =
      socket.assigns.tree
      |> Enum.filter(fn {_, {state, _}} -> state == :expanded end)
      |> Enum.map(fn {p, _} -> p end)

    Enum.reduce(expanded, assign(socket, :tree, %{}), fn p, acc -> load_tree(acc, p) end)
  end

  defp load_agents(socket) do
    case host_path(socket) do
      {:ok, root} ->
        caps = Agents.detect(root, socket.assigns.workspace)

        socket
        |> assign(:agent_caps, caps)
        |> stream_agent_transcripts(Agents.transcripts(root))
        |> assign(:agent_review_cmds, Agents.review_commands(caps))
        |> stream_proposals(Proposals.discover(root))
        |> attach_existing_agent_run()

      _ ->
        socket
        |> assign(:agent_caps, [])
        |> stream_agent_transcripts([])
        |> assign(:agent_review_cmds, [])
        |> stream_proposals([])
    end
  end

  defp attach_existing_agent_run(socket) do
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

  defp attach_existing_run(socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} ->
        case Commands.Run.subscribe(pid) do
          {:ok, snap} -> assign(socket, :active_run, snap)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  @run_buffer_cap 256 * 1024
  defp cap_buffer(b) when byte_size(b) <= @run_buffer_cap, do: b

  defp cap_buffer(b) do
    tail = binary_part(b, byte_size(b) - @run_buffer_cap, @run_buffer_cap)
    "[…truncated]\n" <> tail
  end

  defp load_diff(socket, path) do
    case host_loc(socket) do
      {:ok, loc} ->
        case DevIDE.Workspaces.FileAccess.git_diff(loc, path) do
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
    {render_palette(assigns)}
    {render_template_preview(assigns)}
    {render_template_library(assigns)}
    <div class="flex h-[calc(100vh-1.5rem)] w-full flex-col bg-base-100 text-base-content px-4 pt-2 pb-2 lg:px-6 pointer-coarse:pt-[max(0.5rem,env(safe-area-inset-top))]">
      <%= if @chrome_visible do %>
        <header class="mb-2 flex shrink-0 flex-wrap items-center justify-between gap-x-4 gap-y-2">
          <div class="flex min-w-0 items-center gap-2 text-sm">
            <.link
              navigate={~p"/workspaces"}
              class="text-primary hover:underline shrink-0"
              title="Back to workspaces"
            >
              ←
            </.link>
            <h1 class="truncate text-base font-semibold leading-none">{@workspace.name}</h1>
            <span class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-base-content/70 shrink-0">
              {@workspace.status}
            </span>
            <%= if @workspace.branch do %>
              <span class="font-mono text-xs text-base-content/60 shrink-0">{@workspace.branch}</span>
            <% end %>
            <span
              class="truncate font-mono text-xs text-base-content/50"
              title={render_path(@host_loc, @host_path)}
            >
              {render_path(@host_loc, @host_path)}
            </span>
          </div>
          <nav class="flex flex-wrap items-center justify-end gap-1">
            <%!--
              Primary tabs stay visible; overflow ones live behind a single
              <details> chip so the header collapses to one row at typical
              viewport widths.
            --%>
            <button
              phx-click="switch_tab"
              phx-value-tab="terminal"
              class={tab_class(@tab, "terminal")}
            >
              Terminal
            </button>
            <button phx-click="switch_tab" phx-value-tab="files" class={tab_class(@tab, "files")}>
              Files
            </button>
            <button phx-click="switch_tab" phx-value-tab="run" class={tab_class(@tab, "run")}>
              Run
            </button>
            <button phx-click="switch_tab" phx-value-tab="agents" class={tab_class(@tab, "agents")}>
              Agents
            </button>
            <details class="relative">
              <summary class={[
                "list-none cursor-pointer select-none",
                tab_class(@tab, :__overflow__)
              ]}>
                More ▾
              </summary>
              <div class="absolute right-0 z-10 mt-1 flex w-36 flex-col gap-0.5 rounded border border-base-300 bg-base-100 p-1 shadow-lg">
                <button
                  phx-click="switch_tab"
                  phx-value-tab="search"
                  class={tab_class(@tab, "search") <> " w-full text-left"}
                >
                  Search
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="diff"
                  class={tab_class(@tab, "diff") <> " w-full text-left"}
                >
                  Diff
                </button>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="logs"
                  class={tab_class(@tab, "logs") <> " w-full text-left"}
                >
                  Logs
                </button>
              </div>
            </details>
            <button
              phx-click="audit_drawer:toggle"
              class="ml-2 rounded border border-base-300 px-2 py-1 text-sm text-base-content/80 hover:bg-base-200"
              title="evidence drawer — audit, denials, mode changes"
            >
              Evidence
              <%= if @audit_deny_count > 0 do %>
                <span class="ml-1 text-[10px] font-mono text-error align-middle">
                  ● {@audit_deny_count}
                </span>
              <% end %>
            </button>
            <button
              phx-click="terminal:toggle_chrome"
              class="ml-1 rounded border border-base-300 px-2 py-1 text-sm text-base-content/80 hover:bg-base-200"
              title="Focus mode — hide chrome for a terminal-only view (Ctrl/Cmd+Shift+F)"
              aria-label="Hide header for a terminal-only view"
            >
              <span class="leading-none" aria-hidden="true">▴</span>
            </button>
          </nav>
        </header>
      <% else %>
        <%!-- Thin reveal strip when chrome is hidden (focus mode).
             Click or keyboard shortcut brings the header + utility bar back.
             Only shown in the outer container so it works across all tabs. --%>
        <div
          class="mb-1 h-1.5 pointer-coarse:h-7 w-full cursor-pointer rounded bg-base-300/40 hover:bg-emerald-400/40 active:bg-emerald-400/60 transition-colors flex items-center justify-center"
          style="padding-top: env(safe-area-inset-top);"
          phx-click="terminal:toggle_chrome"
          title="Show chrome (Ctrl/Cmd+Shift+F)"
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

      <div class="min-h-0 flex-1">
        {if @tab == "terminal", do: render_terminal(assigns)}
        {if @tab == "files", do: render_files(assigns)}
        {if @tab == "search", do: render_search(assigns)}
        {if @tab == "diff", do: render_diff(assigns)}
        {if @tab == "run", do: render_run(assigns)}
        {if @tab == "agents", do: render_agents(assigns)}
        {if @tab == "logs", do: render_logs(assigns)}
      </div>
    </div>
    {render_audit_drawer(assigns)}
    """
  end

  # Evidence drawer — product.md §9.4.
  # One time-ordered stream of governed events (allow, deny, mode change,
  # workspace events). Default closed; reachable, not advertised.
  # Markup + audit-stream helpers live in DevIdeWeb.WorkspaceLive.Show.AuditDrawer
  # (imported above); this stays as the call-convention wrapper used by render/1.
  defp render_audit_drawer(assigns) do
    ~H"""
    <.audit_drawer
      audit_drawer_open={@audit_drawer_open}
      audit_events_count={@audit_events_count}
      audit_ledger_count={@audit_ledger_count}
      workspace={@workspace}
      streams={@streams}
    />
    """
  end

  defp active_tmux_window_panes(windows) when is_list(windows) do
    windows
    |> Enum.find(& &1.active)
    |> case do
      %{pane_list: panes} when is_list(panes) -> panes
      _ -> []
    end
  end

  defp active_tmux_window_panes(_), do: []

  defp tmux_geometry_ready?(panes) when is_list(panes) do
    length(panes) > 1 and Enum.any?(panes, & &1.active) and
      Enum.all?(panes, &tmux_pane_geometry_ready?/1)
  end

  defp tmux_pane_geometry_ready?(pane) do
    tmux_dimension(pane.width) > 0 and tmux_dimension(pane.height) > 0
  end

  defp tmux_pane_bounds(panes) do
    Enum.reduce(panes, %{left: 0, top: 0, width: 1, height: 1}, fn pane, bounds ->
      right = tmux_dimension(pane.left) + tmux_dimension(pane.width)
      bottom = tmux_dimension(pane.top) + tmux_dimension(pane.height)

      %{
        left: 0,
        top: 0,
        width: max(bounds.width, right),
        height: max(bounds.height, bottom)
      }
    end)
  end

  defp tmux_pane_style(pane, bounds) do
    left = percentage(tmux_dimension(pane.left), bounds.width)
    top = percentage(tmux_dimension(pane.top), bounds.height)
    width = percentage(tmux_dimension(pane.width), bounds.width)
    height = percentage(tmux_dimension(pane.height), bounds.height)

    "left: #{left}%; top: #{top}%; width: #{width}%; height: #{height}%;"
  end

  defp tmux_dimension(value) when is_integer(value), do: max(value, 0)
  defp tmux_dimension(_), do: 0

  defp percentage(_value, 0), do: 0

  defp percentage(value, total) do
    Float.round(value / total * 100, 4)
  end

  @window_activity_fresh_seconds 30
  @window_activity_recent_seconds 300

  defp window_activity_state(window) do
    case activity_age_seconds(Map.get(window, :activity)) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  defp activity_age_seconds(activity) do
    with {:ok, timestamp} <- parse_activity_timestamp(activity),
         true <- timestamp > 0 do
      {:ok, max(DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(timestamp), 0)}
    else
      _ -> :error
    end
  end

  defp parse_activity_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_activity_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_activity_timestamp(_), do: :error

  defp window_activity_class(:fresh),
    do: "bg-emerald-400 shadow-[0_0_0_3px_rgba(52,211,153,0.18)]"

  defp window_activity_class(:recent), do: "bg-amber-300"
  defp window_activity_class(:idle), do: "bg-base-content/20"

  defp window_activity_label(:fresh), do: "Recent tmux window activity"
  defp window_activity_label(:recent), do: "Tmux window activity in the last five minutes"
  defp window_activity_label(:idle), do: "No recent tmux window activity"

  defp pane_status(pane) do
    activity_state = pane_activity_state(pane)

    cond do
      Map.get(pane, :bell) -> :bell
      pane.active -> :active
      Map.get(pane, :activity_flag) -> :fresh
      activity_state in [:fresh, :recent] -> activity_state
      tmux_pane_geometry_ready?(pane) -> :alive
      true -> :unknown
    end
  end

  defp pane_status_class(:active), do: "bg-primary shadow-[0_0_0_3px_rgba(14,165,233,0.18)]"

  defp pane_status_class(:bell),
    do: "animate-pulse bg-rose-400 shadow-[0_0_0_3px_rgba(251,113,133,0.22)]"

  defp pane_status_class(:fresh), do: "bg-emerald-400 shadow-[0_0_0_3px_rgba(52,211,153,0.18)]"
  defp pane_status_class(:recent), do: "bg-amber-300"
  defp pane_status_class(:alive), do: "bg-emerald-400/80"
  defp pane_status_class(:unknown), do: "bg-amber-300"

  defp pane_status_label(:active), do: "Active tmux pane"
  defp pane_status_label(:bell), do: "Tmux pane bell alert"
  defp pane_status_label(:fresh), do: "Recent tmux pane activity"
  defp pane_status_label(:recent), do: "Tmux pane activity in the last five minutes"
  defp pane_status_label(:alive), do: "Tmux pane ready"
  defp pane_status_label(:unknown), do: "Tmux pane geometry unavailable"

  defp pane_activity_state(pane) do
    case activity_age_seconds(Map.get(pane, :activity)) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  defp pane_activity_value(pane), do: Map.get(pane, :activity, 0) || 0

  defp pane_bell?(pane), do: Map.get(pane, :bell, false) == true

  defp pane_display_title(pane) do
    "#{pane_path_label(pane)} · #{pane_command_label(pane)}"
  end

  defp pane_full_title(pane) do
    path = pane.current_path |> blank_to_nil() || "unknown path"

    "#{path} · #{pane_command_label(pane)}"
  end

  defp window_full_title(window) do
    case Enum.find(Map.get(window, :pane_list, []), & &1.active) do
      nil -> window.name
      pane -> "#{window.name} · #{pane_full_title(pane)}"
    end
  end

  defp pane_path_label(pane) do
    pane.current_path
    |> blank_to_nil()
    |> case do
      nil ->
        "unknown"

      path ->
        blank_to_nil(Path.basename(path)) || "unknown"
    end
  end

  defp pane_command_label(pane) do
    pane.current_command |> blank_to_nil() || "shell"
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp short_path(nil), do: ""
  defp short_path(""), do: ""

  defp short_path(path) when is_binary(path) do
    home = System.get_env("HOME") || ""

    path =
      if home != "" and String.starts_with?(path, home) do
        "~" <> String.replace_prefix(path, home, "")
      else
        path
      end

    parts = String.split(path, "/", trim: true)

    case parts do
      [] -> path
      [only] -> only
      _ -> Enum.take(parts, -2) |> Enum.join("/")
    end
  end

  defp render_terminal(assigns) do
    ~H"""
    <section class="-mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
      <div class={[
        "flex h-full min-h-0 overflow-hidden",
        if(@active_preview, do: "flex-row", else: "flex-col")
      ]}>
        <div class="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
          <%= case @host_loc do %>
            <% {:ok, loc} -> %>
              <%!--
            Utility bar: tiny mode badge + (when raw is active) an
            "exit raw" affordance + contextual meta (cwd · ghostty · panes).
            Mode escalation lives in the command palette
            (`Terminal: enter raw shell`) so chrome stays minimal.

            Session-switch UI (Shell / Exec chips / refresh) only renders
            when there's an attached fleet execution — for typical
            workspaces it's pure noise.
          --%>
              <%= if @chrome_visible do %>
                <div
                  id={"pane-layout-persistence-" <> @workspace.id}
                  class="mb-2 flex shrink-0 flex-wrap items-center gap-x-3 gap-y-1 rounded border border-base-300 bg-base-200 px-2 py-1 text-xs text-base-content/70"
                >
                  <div class="flex shrink-0 items-center gap-1.5">
                    <span class={[
                      "rounded px-1.5 py-0.5 font-mono text-[10px] uppercase tracking-wide",
                      if(@terminal_mode in [:raw, :raw_ghostty],
                        do: "bg-warning/20 text-warning-content border border-warning/40",
                        else: "bg-base-300 text-base-content/70"
                      )
                    ]}>
                      {if @terminal_mode in [:raw, :raw_ghostty], do: "raw", else: "governed"}
                    </span>
                    <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
                      <button
                        id="terminal-mode-governed"
                        type="button"
                        phx-click="terminal:set_mode"
                        phx-value-mode="governed"
                        class="rounded px-1 text-base-content/50 hover:text-base-content"
                        title="Exit raw shell (return to governed)"
                        aria-label="Exit raw shell"
                      >
                        × exit raw
                      </button>
                    <% end %>
                    <%!--
                Hidden programmatic-click target. The governed-mode terminal hook
                (assets/js/ghostty_governed_hook.js) auto-escalates to raw when the
                operator types `claude`/`grok`/`opencode`/etc. at the devide$ prompt
                by clicking #terminal-mode-raw. Visible mode-toggle UI lives in the
                command palette now, but the hook needs a real DOM target.
              --%>
                    <%= if @terminal_mode not in [:raw, :raw_ghostty] and
                       raw_terminal_allowed?(@workspace_mode, @host_id) do %>
                      <button
                        id="terminal-mode-raw"
                        type="button"
                        phx-click="terminal:set_mode"
                        phx-value-mode="raw"
                        class="hidden"
                        aria-hidden="true"
                        tabindex="-1"
                      >
                        enter raw
                      </button>
                    <% end %>
                  </div>

                  <%= if @active_executions? do %>
                    <span class="text-base-content/30">·</span>

                    <div class="flex shrink-0 items-center gap-1">
                      <button
                        type="button"
                        phx-click="terminal:switch_to_shell"
                        class={terminal_tab_class(@terminal_sid == @default_terminal_sid)}
                        title="Workspace shell"
                      >
                        Shell
                      </button>
                      <div id="active-sessions" phx-update="stream" class="contents">
                        <%= for {dom_id, s} <- @streams.active_sessions do %>
                          <button
                            id={dom_id}
                            type="button"
                            phx-click="attach_terminal_session"
                            phx-value-session-id={s.id}
                            phx-value-kind="execution"
                            phx-value-tmux-session={s.tmux_session}
                            class={terminal_tab_class(@terminal_sid == s.id)}
                            title={"Fleet execution " <> (s.execution_id || "")}
                          >
                            Exec
                            <span class="ml-1 font-mono text-primary">
                              {shorten(s.tmux_session)}
                            </span>
                          </button>
                        <% end %>
                      </div>
                      <button
                        type="button"
                        phx-click="terminal:refresh_sessions"
                        class="rounded p-0.5 text-base-content/50 hover:bg-base-300 hover:text-base-content"
                        title="Refresh attachable sessions"
                        aria-label="Refresh attachable sessions"
                      >
                        ↻
                      </button>
                    </div>
                  <% end %>

                  <p class="ml-auto min-w-0 truncate font-mono text-[11px] text-base-content/50">
                    cwd
                    <span class="text-base-content/70">
                      {DevIDE.Workspaces.FileAccess.label(loc)}
                    </span>
                    <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
                      · ghostty <span class="text-base-content/70">{@tmux_session}</span>
                      <button
                        type="button"
                        phx-click="snapshot_all"
                        class="ml-1 rounded px-1 text-[10px] text-base-content/60 hover:text-base-content hover:bg-base-200"
                        title="Snapshot every Ghostty pane in this workspace (server-side)"
                      >
                        snap all
                      </button>
                    <% end %>
                    <%= if @terminal_mode in [:raw, :raw_ghostty] and @pane_count > 1 do %>
                      · <span class="text-base-content/70">{@pane_count} panes</span>
                      <button
                        type="button"
                        phx-click="equalize_layout"
                        class="ml-1 rounded px-1 text-[10px] text-base-content/60 hover:text-base-content hover:bg-base-200"
                        title="Reset all split ratios to equal (50/50 at each level)"
                      >
                        reset
                      </button>
                    <% end %>
                  </p>
                </div>
                {render_tmux_window_tabs(assigns)}
                {render_preview_candidates(assigns)}
              <% end %>

              <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
                <%= cond do %>
                  <% @terminal_mode in [:raw, :raw_ghostty] -> %>
                    <TerminalSurface.pane_layout
                      layout={surface_layout(@pane_layout, @zoomed_pane_id, @pane_data)}
                      panes={terminal_surface_panes(@pane_data)}
                      focused_pane_id={@focused_pane_id}
                      pane_count={@pane_count}
                      zoomed_pane_id={@zoomed_pane_id}
                      host_id={@host_id}
                      workspace_id={@workspace.id}
                      equalize_flash={@equalize_flash}
                    />
                  <% true -> %>
                    {render_governed_terminal(assigns)}
                <% end %>
              </div>
              {render_mobile_key_bar(assigns)}
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

        <%= if @active_preview do %>
          <div
            id="preview-agent-panel"
            class="flex min-h-0 w-72 max-w-[38%] shrink-0 flex-col overflow-hidden border-l border-base-300 bg-base-100 lg:w-80"
          >
            <div
              id="preview-agent-status"
              class="flex shrink-0 items-center gap-2 border-b border-sky-200 bg-sky-50 px-3 py-1.5 text-xs text-sky-950"
            >
              <span class="font-semibold tracking-wide text-sky-800">Agent preview</span>
              <%= if title = preview_observation_title(@active_preview_observation) do %>
                <span class="min-w-0 truncate text-sky-950">{title}</span>
              <% else %>
                <span class="text-sky-600">Observing app…</span>
              <% end %>
              <%= if @active_preview_control_session do %>
                <span class="shrink-0 font-mono text-[10px] text-sky-500">
                  session {@active_preview_control_session.id}
                </span>
              <% end %>
              <button
                type="button"
                phx-click="preview:close"
                phx-value-id={@active_preview.id}
                class="ml-auto shrink-0 rounded p-0.5 text-sky-600 hover:bg-sky-100 hover:text-sky-900"
                title="Close agent preview"
                aria-label="Close agent preview"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <div id="preview-stream" phx-update="stream" class="hidden">
              <%= for {dom_id, preview} <- @streams.previews do %>
                <span id={dom_id}>{preview.id}</span>
              <% end %>
            </div>
            <%= if @active_preview_observation do %>
              <div
                id="preview-observation-panel"
                class="min-h-0 flex-1 overflow-y-auto px-3 py-2 text-xs text-base-content/70"
              >
                <%= if title = @active_preview_observation[:title] || @active_preview_observation["title"] do %>
                  <div class="text-sm font-medium text-base-content truncate">{title}</div>
                <% end %>
                <%= if url = @active_preview_observation[:url] || @active_preview_observation["url"] do %>
                  <div class="truncate font-mono text-[10px] text-base-content/50">{url}</div>
                <% end %>
                <%= if summary = @active_preview_observation[:dom_summary] || @active_preview_observation["dom_summary"] do %>
                  <%= if headings = Map.get(summary, :headings) || Map.get(summary, "headings") do %>
                    <%= if headings != [] do %>
                      <div class="mt-2 text-[11px] text-base-content/70">
                        {Enum.join(headings, " · ")}
                      </div>
                    <% end %>
                  <% end %>
                  <%= if links = Map.get(summary, :links) || Map.get(summary, "links") do %>
                    <%= if links != [] do %>
                      <div class="mt-2 space-y-0.5 text-[10px] text-base-content/60">
                        <%= for link <- Enum.take(links, 6) do %>
                          <div class="truncate">
                            {Map.get(link, :text) || Map.get(link, "text") || "link"}
                            <span class="font-mono text-base-content/40">
                              {Map.get(link, :href) || Map.get(link, "href")}
                            </span>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  <% end %>
                <% end %>
                <%= if shot = observation_screenshot(@active_preview_observation) do %>
                  <img
                    src={shot}
                    alt="Agent preview screenshot"
                    class="mt-3 max-h-56 w-full rounded border border-base-300 object-contain"
                  />
                <% end %>
              </div>
            <% else %>
              <div class="flex flex-1 items-center justify-center p-6 text-sm text-base-content/50">
                Agent is opening the app preview…
              </div>
            <% end %>

            <%= if @active_preview.mode == :iframe and @active_preview.trusted do %>
              <details class="shrink-0 border-t border-base-300 text-xs">
                <summary class="cursor-pointer px-3 py-1.5 text-base-content/60 hover:bg-base-200">
                  Live view
                </summary>
                <iframe
                  src={@active_preview.url}
                  class="h-40 w-full border-0"
                  sandbox="allow-scripts allow-same-origin allow-forms"
                  referrerpolicy="no-referrer"
                >
                </iframe>
              </details>
            <% end %>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  # Mobile-only accessory key row. Soft keyboards have no Ctrl/Alt/Esc/Tab/
  # arrows; this bar synthesizes those keydowns onto the active terminal input
  # (see assets/js/mobile_key_bar.js). Hidden at lg+ where physical keys exist.
  defp render_mobile_key_bar(assigns) do
    ~H"""
    <div
      id={"mobile-key-bar-" <> @workspace.id}
      phx-hook="MobileKeyBar"
      phx-update="ignore"
      class="hidden pointer-coarse:flex fixed inset-x-0 bottom-0 z-30 items-center gap-1 overflow-x-auto border-t border-zinc-700 bg-zinc-900/95 px-1.5 py-1 text-zinc-200 backdrop-blur supports-[backdrop-filter]:bg-zinc-900/80"
      style="padding-bottom: max(0.25rem, env(safe-area-inset-bottom));"
      role="toolbar"
      aria-label="Terminal modifier keys"
    >
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
      <button type="button" data-keybar-key="ArrowLeft" class={mobile_key_class()} aria-label="Left">
        ←
      </button>
      <button type="button" data-keybar-key="ArrowDown" class={mobile_key_class()} aria-label="Down">
        ↓
      </button>
      <button type="button" data-keybar-key="ArrowUp" class={mobile_key_class()} aria-label="Up">
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
    """
  end

  defp render_governed_terminal(assigns) do
    panes = active_tmux_window_panes(assigns.tmux_windows)

    assigns =
      assigns
      |> assign(:active_tmux_window_panes, panes)
      |> assign(:tmux_geometry_ready?, tmux_geometry_ready?(panes))

    ~H"""
    <%= if @tmux_geometry_ready? do %>
      {render_tmux_pane_geometry(assigns)}
    <% else %>
      {render_governed_terminal_surface(assigns)}
    <% end %>
    """
  end

  defp render_governed_terminal_surface(assigns) do
    ~H"""
    <div
      id={"terminal-" <> @workspace.id <> "-" <> @terminal_sid <> "-governed"}
      phx-hook="GhosttyGovernedTerminal"
      phx-update="ignore"
      data-workspace-id={@workspace.id}
      data-sid={@terminal_sid}
      data-raw-session-sid={focused_pane_session_sid(@pane_data, @focused_pane_id, @terminal_sid)}
      data-host-id={@host_id}
      data-socket-token={@socket_token}
      data-terminal-capability={@terminal_workspace_capability}
      class="h-full min-h-0 w-full flex-1"
    >
    </div>
    """
  end

  defp render_tmux_pane_geometry(assigns) do
    bounds = tmux_pane_bounds(assigns.active_tmux_window_panes)

    assigns =
      assigns
      |> assign(:tmux_pane_bounds, bounds)
      |> assign(
        :active_tmux_window_panes,
        Enum.sort_by(assigns.active_tmux_window_panes, & &1.index)
      )

    ~H"""
    <div
      id={"tmux-pane-layout-" <> @workspace.id}
      data-active-pane-id={@tmux_active_pane_id}
      data-bounds-cols={@tmux_pane_bounds.width}
      data-bounds-rows={@tmux_pane_bounds.height}
      data-resize-max={Tmux.resize_amount_max()}
      phx-hook="TmuxPaneResize"
      class="relative min-h-0 flex-1 overflow-hidden rounded border border-base-300 bg-zinc-950"
    >
      <%= for pane <- @active_tmux_window_panes do %>
        <section
          id={"tmux-pane-" <> dom_fragment(pane.id)}
          data-pane-id={pane.id}
          data-window-id={pane.window_id}
          data-pane-active={to_string(pane.active)}
          phx-click={if(pane.active, do: nil, else: "tmux:select_pane")}
          phx-value-pane-id={pane.id}
          title={pane_full_title(pane)}
          class={[
            "absolute overflow-hidden border border-zinc-800 bg-zinc-950 transition-colors",
            if(pane.active,
              do: "z-10 border-primary/70 shadow-[inset_0_0_0_1px_rgba(14,165,233,0.55)]",
              else: "z-0 cursor-pointer hover:border-zinc-600"
            )
          ]}
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <div class="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-6 items-center gap-1 border-b border-zinc-800 bg-zinc-900/95 px-2 text-[10px] text-zinc-400">
            <span class="font-mono text-zinc-500">{pane.index}</span>
            <span
              id={"tmux-pane-status-" <> dom_fragment(pane.id)}
              data-pane-status={pane_status(pane)}
              data-pane-activity={pane_activity_value(pane)}
              data-pane-bell={to_string(pane_bell?(pane))}
              class={[
                "size-1.5 shrink-0 rounded-full",
                pane_status_class(pane_status(pane))
              ]}
              title={pane_status_label(pane_status(pane))}
              aria-label={pane_status_label(pane_status(pane))}
            >
            </span>
            <span
              id={"tmux-pane-title-" <> dom_fragment(pane.id)}
              class="min-w-0 truncate font-mono text-zinc-200"
            >
              {pane_display_title(pane)}
            </span>
            <span class="ml-auto min-w-0 truncate font-mono text-zinc-500">
              {short_path(pane.current_path)}
            </span>
          </div>
          <%= if pane.active do %>
            <div class="absolute inset-0 pt-6">
              {render_governed_terminal_surface(assigns)}
            </div>
          <% else %>
            <div
              id={"tmux-pane-drag-left-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="x"
              class="absolute inset-y-6 left-0 z-20 w-1 cursor-col-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-right-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="x"
              class="absolute inset-y-6 right-0 z-20 w-1 cursor-col-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-up-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="y"
              class="absolute inset-x-0 top-6 z-20 h-1 cursor-row-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-down-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="y"
              class="absolute inset-x-0 bottom-0 z-20 h-1 cursor-row-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <button
              type="button"
              id={"tmux-pane-kill-" <> dom_fragment(pane.id)}
              phx-click="tmux:kill_pane"
              phx-value-pane-id={pane.id}
              class="absolute right-1 top-1 z-30 rounded p-1 text-zinc-500 transition hover:bg-red-500/15 hover:text-red-300"
              title="Close tmux pane"
              aria-label="Close tmux pane"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
            <div class="absolute left-1 top-7 z-30 grid grid-cols-3 gap-0.5">
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-up-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="up"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane up"
                aria-label="Resize pane up"
              >
                <.icon name="hero-arrow-up" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-left-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="left"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane left"
                aria-label="Resize pane left"
              >
                <.icon name="hero-arrow-left" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-right-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="right"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane right"
                aria-label="Resize pane right"
              >
                <.icon name="hero-arrow-right" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-down-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="down"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane down"
                aria-label="Resize pane down"
              >
                <.icon name="hero-arrow-down" class="size-3" />
              </button>
              <span></span>
            </div>
            <div class="absolute right-1 top-7 z-30 flex flex-col gap-1">
              <button
                type="button"
                id={"tmux-pane-split-h-" <> dom_fragment(pane.id)}
                phx-click="tmux:split_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="h"
                class="rounded p-1 text-zinc-500 transition hover:bg-sky-500/15 hover:text-sky-300"
                title="Split pane left/right"
                aria-label="Split pane left/right"
              >
                <.icon name="hero-bars-3-bottom-left" class="size-3.5 rotate-90" />
              </button>
              <button
                type="button"
                id={"tmux-pane-split-v-" <> dom_fragment(pane.id)}
                phx-click="tmux:split_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="v"
                class="rounded p-1 text-zinc-500 transition hover:bg-sky-500/15 hover:text-sky-300"
                title="Split pane top/bottom"
                aria-label="Split pane top/bottom"
              >
                <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
              </button>
            </div>
            <div class="flex h-full items-center justify-center px-3 pt-6 text-center text-xs text-zinc-500">
              <div class="min-w-0">
                <div class="truncate font-mono text-zinc-300">{pane_display_title(pane)}</div>
                <div class="mt-1 truncate font-mono text-[10px]">{short_path(pane.current_path)}</div>
              </div>
            </div>
          <% end %>
        </section>
      <% end %>
    </div>
    """
  end

  defp render_tmux_window_tabs(assigns) do
    ~H"""
    <div
      :if={@tmux_windows != []}
      id={"tmux-window-tabs-" <> @workspace.id}
      data-version={@tmux_topology_version}
      class="mb-2 flex shrink-0 items-center gap-1 overflow-x-auto border-b border-base-300 pb-1"
    >
      <div class="flex min-w-0 flex-1 items-center gap-1">
        <%= for window <- @tmux_windows do %>
          <div
            id={"tmux-window-" <> dom_fragment(window.id)}
            class={[
              "group flex max-w-64 shrink-0 items-center gap-1 rounded-t border border-b-0 px-2 py-1 text-xs transition-colors",
              if(window.active,
                do: "border-primary bg-base-100 text-base-content shadow-sm",
                else:
                  "border-base-300 bg-base-200/70 text-base-content/65 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <button
              type="button"
              phx-click="tmux:select_window"
              phx-value-window-id={window.id}
              class="flex min-w-0 items-center gap-1"
              title={"Select tmux window " <> window_full_title(window)}
            >
              <span class="font-mono text-[10px] text-base-content/45">{window.index}</span>
              <span class="max-w-36 truncate font-medium">{window.name}</span>
              <span
                id={"tmux-window-activity-" <> dom_fragment(window.id)}
                data-activity-state={window_activity_state(window)}
                class={[
                  "size-1.5 shrink-0 rounded-full",
                  window_activity_class(window_activity_state(window))
                ]}
                title={window_activity_label(window_activity_state(window))}
                aria-label={window_activity_label(window_activity_state(window))}
              >
              </span>
              <span class="font-mono text-[10px] text-base-content/45">{window.current_command}</span>
            </button>
            <%= if @tmux_rename_window_id == window.id do %>
              <.form
                for={to_form(%{"id" => window.id, "name" => window.name}, as: :window)}
                id={"tmux-rename-form-" <> dom_fragment(window.id)}
                phx-submit="tmux:rename_window"
                class="ml-1 flex items-center gap-1"
              >
                <input type="hidden" name="window[id]" value={window.id} />
                <.input
                  field={to_form(%{"name" => window.name}, as: :window)[:name]}
                  type="text"
                  value={window.name}
                  class="h-6 w-28 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                />
                <button
                  type="submit"
                  class="rounded p-1 text-primary hover:bg-primary/10"
                  title="Save window name"
                  aria-label="Save window name"
                >
                  <.icon name="hero-check" class="size-3.5" />
                </button>
                <button
                  type="button"
                  phx-click="tmux:rename_cancel"
                  class="rounded p-1 text-base-content/45 hover:bg-base-200 hover:text-base-content"
                  title="Cancel rename"
                  aria-label="Cancel rename"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </.form>
            <% else %>
              <button
                type="button"
                phx-click="tmux:rename_start"
                phx-value-window-id={window.id}
                class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-base-300 hover:text-base-content"
                title="Rename tmux window"
                aria-label="Rename tmux window"
              >
                <.icon name="hero-pencil-square" class="size-3.5" />
              </button>
            <% end %>
            <button
              type="button"
              phx-click="tmux:kill_window"
              phx-value-window-id={window.id}
              class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
              title="Close tmux window"
              aria-label="Close tmux window"
              disabled={length(@tmux_windows) <= 1}
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>
        <% end %>
      </div>
      <button
        id={"tmux-template-palette-" <> @workspace.id}
        type="button"
        phx-click="palette:templates"
        class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
        title="Apply session template"
        aria-label="Apply session template"
      >
        <.icon name="hero-bars-3-bottom-left" class="size-4" />
      </button>
      <button
        id={"tmux-template-library-" <> @workspace.id}
        type="button"
        phx-click="tmux:open_template_library"
        class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
        title="Session template library"
        aria-label="Session template library"
      >
        <.icon name="hero-book-open" class="size-4" />
      </button>
      <button
        type="button"
        phx-click="tmux:new_window"
        class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
        title="New tmux window"
        aria-label="New tmux window"
      >
        <.icon name="hero-plus" class="size-4" />
      </button>
      <button
        type="button"
        phx-click="tmux:refresh_windows"
        class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
        title="Refresh tmux windows"
        aria-label="Refresh tmux windows"
      >
        <.icon name="hero-arrow-path" class="size-4" />
      </button>
    </div>
    """
  end

  defp render_preview_candidates(assigns) do
    assigns =
      assign(assigns, :visible_preview_candidates, visible_preview_candidate_list(assigns))

    ~H"""
    <div
      :if={@visible_preview_candidates != []}
      id={"preview-candidates-" <> @workspace.id}
      class="mb-2 flex shrink-0 items-center gap-2 overflow-x-auto rounded border border-emerald-200 bg-emerald-50 px-2 py-1 text-xs text-emerald-950"
    >
      <span class="shrink-0 font-semibold text-emerald-800">Detected preview</span>
      <%= for candidate <- @visible_preview_candidates do %>
        <span class="inline-flex shrink-0 overflow-hidden rounded border border-emerald-200 bg-white">
          <button
            id={"preview-candidate-" <> to_string(candidate.port || dom_fragment(candidate.url))}
            type="button"
            phx-click="preview:open"
            phx-value-source="detected"
            phx-value-url={candidate.url}
            phx-value-mode="iframe"
            class="px-2 py-0.5 font-mono text-[11px] text-emerald-900 transition hover:bg-emerald-100"
            title={"Open " <> candidate.url}
          >
            {DevIDE.Previews.extract_title_from_url(candidate.url)}
          </button>
          <button
            id={"preview-candidate-dismiss-" <> to_string(candidate.port || dom_fragment(candidate.url))}
            type="button"
            phx-click="preview:dismiss_candidate"
            phx-value-url={candidate.url}
            class="border-l border-emerald-200 px-1.5 text-emerald-700 transition hover:bg-emerald-100 hover:text-emerald-950"
            title={"Dismiss " <> candidate.url}
            aria-label={"Dismiss preview candidate " <> candidate.url}
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </span>
      <% end %>
    </div>
    """
  end

  defp mobile_key_class do
    "flex-none rounded border border-zinc-700 bg-zinc-800 px-2 py-0.5 font-mono text-xs leading-tight " <>
      "active:bg-zinc-700 hover:bg-zinc-700 transition-colors min-w-[2rem] text-center"
  end

  # Sticky-modifier styling driven by the data-mod-state the JS hook maintains
  # (off | armed | locked). Arbitrary variants key off the data attribute so the
  # JS only has to flip one attribute, no class juggling.
  defp mobile_mod_class do
    "flex-none rounded border px-2 py-0.5 font-mono text-xs leading-tight transition-colors min-w-[2.25rem] text-center " <>
      "border-zinc-700 bg-zinc-800 " <>
      "data-[mod-state=armed]:border-emerald-400 data-[mod-state=armed]:bg-emerald-500/20 data-[mod-state=armed]:text-emerald-300 " <>
      "data-[mod-state=locked]:border-amber-400 data-[mod-state=locked]:bg-amber-500/30 data-[mod-state=locked]:text-amber-200"
  end

  defp render_files(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3 lg:flex-row lg:gap-4">
      <div class="border rounded p-2 overflow-auto bg-zinc-50 space-y-2 max-h-56 lg:max-h-none lg:w-72 lg:flex-none 2xl:w-80">
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="flex flex-wrap gap-1 text-xs">
              <span class="px-1 text-zinc-500">in:</span>
              <span class="font-mono text-zinc-700">
                {if @selected_dir == "", do: "/", else: @selected_dir}
              </span>
              <button
                phx-click="tree:new_form"
                phx-value-kind="file"
                class="ml-auto rounded border px-1.5"
              >
                +File
              </button>
              <button phx-click="tree:new_form" phx-value-kind="dir" class="rounded border px-1.5">
                +Dir
              </button>
              <button phx-click="tree:refresh" class="rounded border px-1.5">↻</button>
            </div>
            <%= if @new_input do %>
              <.form for={%{}} phx-submit="tree:create" class="flex gap-1 text-xs">
                <input
                  name="name"
                  autofocus
                  placeholder={if elem(@new_input, 0) == :file, do: "filename", else: "dir name"}
                  class="flex-1 border rounded px-1 py-0.5 font-mono"
                />
                <button class="rounded bg-zinc-900 text-white px-2 py-0.5">create</button>
                <button type="button" phx-click="tree:cancel_new" class="rounded border px-2 py-0.5">
                  x
                </button>
              </.form>
            <% end %>
            <%= if @tree_error do %>
              <p class="text-xs text-red-700">{@tree_error}</p>
            <% end %>
            {render_tree_node(assigns, "")}
            {render_project_card(assigns)}
            {render_symbols_panel(assigns)}
          <% _ -> %>
            <p class="text-xs text-red-700">No host path; cannot list files.</p>
        <% end %>
      </div>
      <div class="border rounded flex flex-col flex-1 min-w-0 min-h-0">
        <%= if @open_file do %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs font-mono flex flex-wrap justify-between items-center gap-2">
            <%= if @rename_input do %>
              <.form for={%{}} phx-submit="file:rename_submit" class="flex gap-1 flex-1">
                <input name="new_path" value={@rename_input} class="flex-1 border rounded px-1" />
                <button class="rounded bg-zinc-900 text-white px-2">rename</button>
                <button type="button" phx-click="file:rename_cancel" class="rounded border px-2">
                  x
                </button>
              </.form>
            <% else %>
              <span class="truncate">{@open_file.path}</span>
            <% end %>
            <span class="flex items-center gap-2 text-zinc-500">
              <span id="dirty-indicator" data-dirty="false" class="text-amber-700"></span>
              <span>{@open_file.size}b</span>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.dispatch("devide:save", to: "#file-viewer")}
                class="rounded bg-zinc-900 text-white px-2 py-0.5"
              >
                Save
              </button>
              <button type="button" phx-click="file:refresh" class="rounded border px-2 py-0.5">
                Refresh
              </button>
              <button type="button" phx-click="file:rename_form" class="rounded border px-2 py-0.5">
                Rename
              </button>
              <button
                type="button"
                phx-click="file:delete_request"
                class="rounded border px-2 py-0.5 text-red-700"
              >
                Delete
              </button>
            </span>
          </div>
          <%= if @delete_confirm do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs flex justify-between items-center">
              <span>Delete <span class="font-mono">{@delete_confirm}</span>?</span>
              <span class="flex gap-1">
                <button
                  phx-click="file:delete_confirm"
                  class="rounded bg-red-700 text-white px-2 py-0.5"
                >
                  confirm
                </button>
                <button phx-click="file:delete_cancel" class="rounded border px-2 py-0.5">
                  cancel
                </button>
              </span>
            </div>
          <% end %>
          <%= if @save_error do %>
            <div class="px-3 py-1 border-b bg-red-50 text-xs text-red-800">{@save_error}</div>
          <% end %>
        <% else %>
          <div class="px-3 py-1.5 border-b bg-zinc-50 text-xs text-zinc-500">
            {@file_error || "Select a file to view."}
          </div>
        <% end %>
        <div
          id="file-viewer"
          phx-hook="FileViewerHook"
          phx-update="ignore"
          class="flex-1 overflow-auto"
        >
        </div>
      </div>
    </section>
    """
  end

  defp render_tree_node(assigns, path) do
    state = Map.get(assigns.tree, path, {:collapsed, []})
    assigns = Map.put(assigns, :node, %{path: path, state: state})

    ~H"""
    <%= case @node.state do %>
      <% {:expanded, entries} -> %>
        <ul class="text-sm">
          <%= for e <- entries do %>
            <li class="pl-3">
              <%= case e.kind do %>
                <% :dir -> %>
                  <div class="flex items-center group">
                    <button
                      phx-click="tree:toggle"
                      phx-value-path={e.rel_path}
                      class="hover:underline text-left flex-1"
                    >
                      <span class="font-mono text-amber-700">▸</span> {e.name}/
                    </button>
                    <button
                      phx-click="tree:select_dir"
                      phx-value-path={e.rel_path}
                      title="select for new file/dir"
                      class={"text-[10px] px-1 opacity-0 group-hover:opacity-100 " <> if @selected_dir == e.rel_path, do: "opacity-100 text-blue-700", else: ""}
                    >
                      sel
                    </button>
                  </div>
                  <%= if match?({:expanded, _}, Map.get(@tree, e.rel_path)) do %>
                    {render_tree_node(assigns, e.rel_path)}
                  <% end %>
                <% _ -> %>
                  <button
                    phx-click="tree:open"
                    phx-value-path={e.rel_path}
                    class="hover:underline text-left w-full"
                  >
                    <span class="font-mono text-zinc-400">·</span> {e.name}
                  </button>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% _ -> %>
        <p class="text-xs text-zinc-400">(loading…)</p>
    <% end %>
    """
  end

  defp render_search(assigns) do
    grouped =
      assigns.search_results
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {p, _} -> p end)

    assigns = Map.put(assigns, :grouped_results, grouped)

    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3">
      <.form for={%{}} phx-submit="search:run" class="flex flex-wrap gap-2 items-center flex-none">
        <input
          name="query"
          value={@search_query}
          placeholder="search workspace…"
          autocomplete="off"
          class="flex-1 min-w-[12rem] border rounded px-2 py-1 text-sm font-mono"
        />
        <button class="rounded bg-zinc-900 text-white px-3 py-1 text-sm">Search</button>
        <span class="text-xs text-zinc-500">
          rg: {if Search.available?(), do: "available", else: "missing"}
        </span>
      </.form>
      <div class="flex-1 min-h-0 overflow-auto pr-1">
        {render_search_state(assigns)}
      </div>
    </section>
    """
  end

  defp render_search_state(assigns) do
    case assigns.search_state do
      :idle ->
        ~H"""
        <p class="text-xs text-zinc-500">
          Type {Search.min_query()}+ chars and press Enter. Searches the workspace via <code>rg</code>; results are PathSafety-checked.
        </p>
        """

      :empty ->
        ~H"""
        <p class="text-xs text-zinc-500">No matches.</p>
        """

      :ok ->
        ~H"""
        <p class="text-xs text-zinc-500">
          {length(@search_results)} match(es) in {length(@grouped_results)} file(s)
          (cap {Search.result_cap()}).
        </p>
        <ul class="text-xs space-y-2">
          <%= for {path, items} <- @grouped_results do %>
            <li>
              <div class="font-mono text-zinc-700">{path} ({length(items)})</div>
              <ul class="ml-3 space-y-0.5">
                <%= for r <- items do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={r.path}
                      phx-value-line={r.line}
                      class="font-mono hover:underline text-left"
                    >
                      :{r.line}{if r.column, do: ":" <> Integer.to_string(r.column)}
                    </button>
                    <span class="text-zinc-600 font-mono">— {r.preview}</span>
                  </li>
                <% end %>
              </ul>
            </li>
          <% end %>
        </ul>
        """

      {:error, reason} ->
        assigns = Map.put(assigns, :reason, reason)

        ~H"""
        <p class="text-xs text-red-700">{search_error_text(@reason)}</p>
        """
    end
  end

  defp search_error_text(:rg_missing),
    do: "ripgrep (rg) is not installed on the host; install it to enable search."

  defp search_error_text(:timeout), do: "search timed out; try a more specific query."

  defp search_error_text(:too_short),
    do: "query must be at least #{DevIDE.Search.min_query()} characters."

  defp search_error_text(:too_long),
    do: "query must be at most #{DevIDE.Search.max_query()} characters."

  defp search_error_text(:no_root), do: "workspace path unavailable."
  defp search_error_text(other), do: "search failed: #{inspect(other)}"

  defp render_diff(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 min-h-0 lg:flex-row lg:h-[calc(100dvh-14rem)] lg:min-h-[20rem]">
      <aside class="flex flex-col min-h-0 lg:w-72 lg:flex-none 2xl:w-80">
        <h3 class="text-xs font-medium text-zinc-700 mb-2 flex-none">
          Changes <span class="ml-1 text-[10px] font-mono text-zinc-400">{length(@git_status)}</span>
        </h3>
        <%= if @git_status == [] do %>
          <p class="text-sm text-zinc-500">No changes.</p>
        <% else %>
          <ul class="text-xs space-y-0.5 overflow-auto pr-1 max-h-48 lg:max-h-none lg:flex-1 lg:min-h-0">
            <%= for e <- @git_status do %>
              <li>
                <button
                  type="button"
                  phx-click="annotation:open"
                  phx-value-path={e.path}
                  class={[
                    "w-full rounded px-2 py-1 text-left font-mono transition hover:bg-zinc-100 flex items-center gap-2",
                    @open_file && @open_file.path == e.path && "bg-zinc-100 border border-zinc-300"
                  ]}
                >
                  <span class={git_status_badge_class(e.x, e.y)}>{e.x}{e.y}</span>
                  <span class="truncate">{e.path}</span>
                </button>
              </li>
            <% end %>
          </ul>
        <% end %>
      </aside>

      <div class="flex flex-col min-w-0 min-h-0 flex-1">
        <%= cond do %>
          <% is_nil(@open_file) -> %>
            <p class="text-sm text-zinc-500">Select a file to view its diff.</p>
          <% is_nil(@file_diff) -> %>
            <p class="text-sm text-zinc-500">
              No diff for <span class="font-mono">{@open_file.path}</span> (no working-tree changes).
            </p>
          <% true -> %>
            <div class="flex items-center justify-between mb-2 flex-none">
              <span class="font-mono text-xs text-zinc-700 truncate">{@open_file.path}</span>
              <span class="text-[10px] font-mono text-zinc-400 flex-none ml-2">
                {diff_stat_label(@file_diff)}
              </span>
            </div>
            <pre class="bg-zinc-950 text-zinc-100 text-xs rounded overflow-auto leading-relaxed flex-1 min-h-[12rem] max-h-[60dvh] lg:max-h-none"><%= for {line, idx} <- diff_lines(@file_diff) do %><code class={diff_line_class(line)} id={"diff-line-#{idx}"}><%= line %><br/></code><% end %></pre>
        <% end %>
      </div>
    </section>
    """
  end

  defp diff_lines(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.with_index()
  end

  defp diff_lines(_), do: []

  defp diff_line_class(line) do
    base = "block px-3 font-mono whitespace-pre"

    cond do
      String.starts_with?(line, "+++") or String.starts_with?(line, "---") ->
        base <> " text-zinc-400"

      String.starts_with?(line, "@@") ->
        base <> " text-cyan-300 bg-zinc-900"

      String.starts_with?(line, "+") ->
        base <> " text-emerald-300 bg-emerald-950/40"

      String.starts_with?(line, "-") ->
        base <> " text-rose-300 bg-rose-950/40"

      String.starts_with?(line, "diff ") or String.starts_with?(line, "index ") ->
        base <> " text-zinc-500"

      true ->
        base <> " text-zinc-300"
    end
  end

  defp diff_stat_label(diff) when is_binary(diff) do
    lines = String.split(diff, "\n")

    adds =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "+") and not String.starts_with?(l, "+++")
      end)

    dels =
      Enum.count(lines, fn l ->
        String.starts_with?(l, "-") and not String.starts_with?(l, "---")
      end)

    "+#{adds} −#{dels}"
  end

  defp diff_stat_label(_), do: ""

  defp git_status_badge_class(x, y) do
    color =
      cond do
        x == "?" or y == "?" -> "text-violet-700"
        x == "A" or y == "A" -> "text-emerald-700"
        x == "D" or y == "D" -> "text-rose-700"
        x == "M" or y == "M" -> "text-amber-700"
        true -> "text-zinc-600"
      end

    "inline-block w-6 text-center #{color}"
  end

  defp render_run(assigns) do
    ~H"""
    <.run_panel
      host_loc={@host_loc}
      active_run={@active_run}
      run_ledger={@run_ledger}
      selected_run_id={@selected_run_id}
      selected_run_timeline={@selected_run_timeline}
      selected_run_summary={@selected_run_summary}
      selected_run_failure_reason={@selected_run_failure_reason}
      selected_run_can_retry={@selected_run_can_retry}
      selected_run_artifacts={@selected_run_artifacts}
    />
    """
  end

  defp render_project_card(assigns) do
    ~H"""
    <%= if @project_meta do %>
      <details class="border-t pt-1 mt-2 text-[11px]">
        <summary class="cursor-pointer text-zinc-700">Project</summary>
        <ul class="mt-1 space-y-0.5">
          <li>Mix: {yes_no(@project_meta.mix?)}</li>
          <li>Umbrella: {yes_no(@project_meta.umbrella?)}</li>
          <li>Phoenix: {yes_no(@project_meta.phoenix?)}</li>
          <li>LiveView: {yes_no(@project_meta.live_view?)}</li>
          <li>Ecto: {yes_no(@project_meta.ecto?)}</li>
          <li>Formatter: {yes_no(@project_meta.formatter?)}</li>
          <%= if @tooling do %>
            <li>
              Lexical: {detected_or_missing(@tooling.lexical? or @tooling.mix_lock_lexical?)}
            </li>
            <li>
              ElixirLS: {detected_or_missing(@tooling.elixir_ls? or @tooling.mix_lock_elixir_ls?)}
            </li>
          <% end %>
        </ul>
      </details>
    <% end %>
    """
  end

  defp render_symbols_panel(assigns) do
    case assigns.open_file do
      %{path: path, content: content} ->
        symbols = ElixirNav.symbols(content, path)
        assigns = Map.put(assigns, :file_symbols, symbols) |> Map.put(:file_path, path)

        ~H"""
        <details class="border-t pt-1 mt-2 text-[11px]" open>
          <summary class="cursor-pointer text-zinc-700">
            Symbols ({length(@file_symbols)})
          </summary>
          <%= cond do %>
            <% String.ends_with?(@file_path, ".heex") -> %>
              <p class="text-zinc-500">HEEx symbols not supported yet.</p>
            <% @file_symbols == [] -> %>
              <p class="text-zinc-500">No symbols.</p>
            <% true -> %>
              <ul class="font-mono space-y-0.5 mt-1">
                <%= for s <- @file_symbols do %>
                  <li>
                    <button
                      phx-click="annotation:open"
                      phx-value-path={@file_path}
                      phx-value-line={s.line}
                      class={"hover:underline text-left " <> symbol_color(s)}
                    >
                      <span class="text-zinc-400">{symbol_glyph(s.kind)}</span>
                      {s.name}
                      <%= if s.visibility == :private do %>
                        <span class="text-zinc-400">priv</span>
                      <% end %>
                      <span class="text-zinc-400">:{s.line}</span>
                    </button>
                  </li>
                <% end %>
              </ul>
          <% end %>
        </details>
        """

      _ ->
        ~H""
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"
  defp detected_or_missing(true), do: "detected"
  defp detected_or_missing(_), do: "missing"

  defp symbol_glyph(:module), do: "M"
  defp symbol_glyph(:function), do: "f"
  defp symbol_glyph(:macro), do: "ƒ"
  defp symbol_glyph(:guard), do: "g"
  defp symbol_glyph(:delegate), do: "→"
  defp symbol_glyph(:test), do: "t"
  defp symbol_glyph(:describe), do: "d"
  defp symbol_glyph(_), do: "?"

  defp symbol_color(%{kind: :module}), do: "text-blue-700"
  defp symbol_color(%{visibility: :private}), do: "text-zinc-500"
  defp symbol_color(%{kind: :test}), do: "text-purple-700"
  defp symbol_color(%{kind: :describe}), do: "text-purple-700"
  defp symbol_color(_), do: "text-zinc-800"

  defp parse_line(nil), do: nil
  defp parse_line(""), do: nil

  defp parse_line(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_line(_), do: nil

  defp parse_resize_amount(nil), do: {:ok, Tmux.resize_amount_default()}

  defp parse_resize_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> validate_resize_amount(integer)
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_resize_amount(value) when is_integer(value) and value > 0 do
    validate_resize_amount(value)
  end

  defp parse_resize_amount(_), do: {:error, :invalid_amount}

  defp validate_resize_amount(value) do
    if value <= Tmux.resize_amount_max() do
      {:ok, value}
    else
      {:error, :invalid_amount}
    end
  end

  defp palette_query(socket, q) do
    root =
      case host_path(socket) do
        {:ok, r} -> r
        _ -> nil
      end

    category = socket.assigns[:palette_category] || :all

    static_items =
      root
      |> Palette.query(q, category: category)
      |> filter_palette_items_by_mode(socket.assigns[:terminal_mode])

    (static_items ++
       template_palette_items(socket, q, category) ++
       pane_palette_items(socket, q, category))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(50)
  end

  defp template_palette_items(_socket, _q, category) when category not in [:all, :tmux], do: []

  defp template_palette_items(socket, q, _category) do
    socket
    |> palette_session_templates()
    |> Enum.flat_map(fn template ->
      searchable =
        Enum.join(
          [
            "Template",
            "Session Template",
            template.source_label,
            template.name,
            template.description,
            template.id
          ],
          " "
        )

      case DevIDE.Palette.Fuzzy.score(searchable, q || "") do
        nil ->
          []

        score ->
          [
            %PaletteItem{
              id: "template:preview:" <> template.id,
              kind: :action,
              category: :tmux,
              label: template.palette_label,
              detail: template.description,
              score: score,
              payload: %{
                event: "tmux:preview_template",
                params: %{"template-id" => template.id}
              }
            }
          ]
      end
    end)
  end

  defp palette_session_templates(socket) do
    built_in =
      socket.assigns[:session_templates]
      |> Kernel.||(SessionTemplate.list())
      |> Enum.map(fn template ->
        %{
          id: template.id,
          name: template.name,
          description: template.description,
          source_label: "Built-in",
          palette_label: "Preview template: " <> template.name
        }
      end)

    saved =
      socket.assigns[:saved_session_templates]
      |> Kernel.||([])
      |> Enum.filter(&Templates.apply_supported?/1)
      |> Enum.map(fn template ->
        %{
          id: template.id,
          name: template.name,
          description: saved_template_description(template),
          source_label: "Saved",
          palette_label: "Preview saved template: " <> template.name
        }
      end)

    built_in ++ saved
  end

  defp pane_palette_items(_socket, _q, category) when category not in [:all, :tmux], do: []

  defp pane_palette_items(socket, q, _category) do
    pane_ids =
      socket.assigns[:pane_layout]
      |> PaneLayout.collect_pane_ids()
      |> Enum.filter(&Map.has_key?(socket.assigns[:pane_data] || %{}, &1))

    Enum.flat_map(pane_ids, fn pane_id ->
      pane = Map.get(socket.assigns[:pane_data] || %{}, pane_id)
      label = "Pane #{pane_id}"
      detail = pane_palette_detail(socket, pane_id, pane)
      searchable = Enum.join([label, detail, "Find Pane"], " ")

      case DevIDE.Palette.Fuzzy.score(searchable, q || "") do
        nil ->
          []

        score ->
          [
            %PaletteItem{
              id: "pane:focus:" <> pane_id,
              kind: :action,
              category: :tmux,
              label: label,
              detail: detail,
              score: score,
              payload: %{event: "focus_pane", params: %{"pane-id" => pane_id}}
            }
          ]
      end
    end)
  end

  defp pane_palette_detail(socket, pane_id, pane) do
    flags =
      []
      |> maybe_add_flag(socket.assigns[:focused_pane_id] == pane_id, "focused")
      |> maybe_add_flag(socket.assigns[:zoomed_pane_id] == pane_id, "zoomed")

    session =
      case pane do
        %{tmux_session: s} when is_binary(s) -> s
        _ -> nil
      end

    [Enum.reverse(flags), session]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp maybe_add_flag(flags, true, flag), do: [flag | flags]
  defp maybe_add_flag(flags, false, _flag), do: flags

  defp resolve_palette_item(socket, _root, "pane:focus:" <> pane_id) do
    if Map.has_key?(socket.assigns[:pane_data] || %{}, pane_id) do
      {:ok, %{event: "focus_pane", params: %{"pane-id" => pane_id}}}
    else
      :error
    end
  end

  defp resolve_palette_item(socket, _root, "template:preview:" <> template_id) do
    case get_session_template(socket, template_id) do
      {:ok, _template} ->
        {:ok, %{event: "tmux:preview_template", params: %{"template-id" => template_id}}}

      {:error, _reason} ->
        :error
    end
  end

  defp resolve_palette_item(_socket, root, id), do: Palette.resolve(root, id)

  # Ordered category tabs shown in the palette. `:all` is always first so the
  # user can broaden out of any screen-derived default.
  @palette_categories [:all, :files, :commands, :tmux, :preview, :actions]

  @doc false
  def palette_categories, do: @palette_categories

  @doc false
  def palette_category_label(:all), do: "all"
  def palette_category_label(:files), do: "files"
  def palette_category_label(:commands), do: "commands"
  def palette_category_label(:tmux), do: "tmux"
  def palette_category_label(:preview), do: "preview"
  def palette_category_label(:actions), do: "actions"

  defp default_palette_category(tab) do
    case tab do
      "terminal" -> :tmux
      "files" -> :files
      "search" -> :files
      "diff" -> :files
      "run" -> :commands
      _ -> :all
    end
  end

  defp cycle_palette_category(current, dir) do
    cats = @palette_categories
    idx = Enum.find_index(cats, &(&1 == current)) || 0
    n = length(cats)
    next_idx = if dir == "next", do: rem(idx + 1, n), else: rem(idx - 1 + n, n)
    Enum.at(cats, next_idx)
  end

  defp parse_palette_category(name) do
    Enum.find(@palette_categories, &(Atom.to_string(&1) == name))
    |> case do
      nil -> :error
      cat -> {:ok, cat}
    end
  end

  # Re-query under the new category and reset selection to the top.
  defp apply_palette_category(socket, category) do
    socket = assign(socket, :palette_category, category)

    socket
    |> assign(:palette_items, palette_query(socket, socket.assigns[:palette_query] || ""))
    |> assign(:palette_selected_idx, 0)
  end

  # Drop the action that would no-op given the current terminal mode, so
  # the palette never offers "Enter raw shell" while you're already in raw
  # (and vice versa). `Palette.resolve/2` still honours the id if it's
  # somehow dispatched anyway — the LV's `terminal:set_mode` handler is
  # idempotent.
  defp filter_palette_items_by_mode(items, terminal_mode) do
    drop_id =
      case terminal_mode do
        m when m in [:raw, :raw_ghostty] -> "action:terminal:raw"
        :governed -> "action:terminal:governed"
        _ -> nil
      end

    if drop_id, do: Enum.reject(items, &(&1.id == drop_id)), else: items
  end

  defp render_template_preview(assigns) do
    ~H"""
    <%= if @template_preview do %>
      <div
        id="template-preview-modal"
        class="fixed inset-0 z-[60] flex items-start justify-center bg-black/55 px-4 pt-20 text-base-content"
      >
        <section
          id="template-preview-card"
          class="flex max-h-[78vh] w-[720px] max-w-[94vw] flex-col overflow-hidden rounded border border-base-300 bg-base-100 shadow-2xl"
        >
          <header class="flex items-start justify-between gap-4 border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-primary">
                Session template preview
              </div>
              <h2 id="template-preview-title" class="truncate text-sm font-semibold">
                {@template_preview.template.name}
              </h2>
              <p class="mt-1 text-xs text-base-content/65">
                {@template_preview.template.description}
              </p>
              <%= if template_preview_reconcile?(@template_preview) do %>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <span class="rounded border border-primary/25 bg-primary/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-primary">
                    Smart reconcile
                  </span>
                  <span
                    id="template-reconcile-disruption"
                    data-disruption={@template_preview.diff.estimated_disruption}
                    class={template_disruption_class(@template_preview.diff.estimated_disruption)}
                  >
                    {template_disruption_label(@template_preview.diff.estimated_disruption)}
                  </span>
                </div>
              <% end %>
            </div>
            <button
              id="template-preview-close"
              type="button"
              phx-click="tmux:cancel_template_preview"
              class="rounded p-1 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
              title="Close template preview"
              aria-label="Close template preview"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div id="template-preview-steps" class="min-h-0 flex-1 overflow-auto px-4 py-3">
            <%= if template_preview_reconcile?(@template_preview) do %>
              <div
                id="template-reconcile-summary"
                class="mb-3 rounded border border-primary/20 bg-primary/5 px-3 py-3"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h3 class="text-xs font-semibold text-base-content">
                      Reconciliation preview
                    </h3>
                    <p class="mt-1 text-[11px] text-base-content/60">
                      {template_reconcile_summary_sentence(@template_preview.diff.summary)}
                    </p>
                  </div>
                  <span class="rounded bg-base-100 px-2 py-1 font-mono text-[10px] text-base-content/55">
                    {@template_preview.diff.strategy}
                  </span>
                </div>

                <div class="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
                  <%= for item <- template_reconcile_summary_items(@template_preview.diff.summary) do %>
                    <div
                      id={"template-reconcile-summary-" <> item.key}
                      class="rounded border border-base-300 bg-base-100 px-2 py-1.5"
                    >
                      <div class="text-[10px] uppercase tracking-wide text-base-content/45">
                        {item.label}
                      </div>
                      <div class="font-mono text-sm font-semibold text-base-content">
                        {item.value}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <div id="template-reconcile-changes" class="space-y-2">
                <%= for change <- @template_preview.diff.changes do %>
                  <article
                    id={"template-reconcile-change-" <> Integer.to_string(change.index)}
                    data-action={change.action}
                    class={template_change_class(change.action)}
                  >
                    <div class="flex items-start gap-3">
                      <span class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 font-mono text-[10px] text-base-content/60">
                        {change.index}
                      </span>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span class="font-medium">{template_change_title(change)}</span>
                          <span class="rounded bg-base-100 px-1.5 py-0.5 font-mono text-[10px] text-base-content/60">
                            {change.action}
                          </span>
                        </div>
                        <%= if template_change_detail(change) != "" do %>
                          <p class="mt-1 truncate font-mono text-[10px] text-base-content/60">
                            {template_change_detail(change)}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  </article>
                <% end %>
              </div>

              <div
                id="template-exact-plan-note"
                class="mt-3 rounded border border-dashed border-base-300 px-3 py-2 text-[11px] text-base-content/55"
              >
                Exact replay would run {@template_preview.step_count} planned tmux operation(s)
                without trying to reuse the current layout.
              </div>
            <% else %>
              <div class="space-y-2">
                <%= for step <- @template_preview.steps do %>
                  <article
                    id={"template-preview-step-" <> Integer.to_string(step.index)}
                    data-action={step.action}
                    class="rounded border border-base-300 bg-base-200/35 px-3 py-2 text-xs"
                  >
                    <div class="flex items-start gap-3">
                      <span class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 font-mono text-[10px] text-base-content/60">
                        {step.index}
                      </span>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span class="font-medium">{template_step_title(step)}</span>
                          <span class="rounded bg-base-300 px-1.5 py-0.5 font-mono text-[10px] text-base-content/60">
                            {step.action}
                          </span>
                        </div>
                        <%= if template_step_detail(step) != "" do %>
                          <p class="mt-1 truncate font-mono text-[10px] text-base-content/60">
                            {template_step_detail(step)}
                          </p>
                        <% end %>
                      </div>
                    </div>
                  </article>
                <% end %>
              </div>
            <% end %>
          </div>

          <footer class="flex items-center justify-between gap-3 border-t border-base-300 px-4 py-3 text-xs">
            <span class="text-base-content/55">
              {template_preview_footer(@template_preview)}
            </span>
            <div class="flex items-center gap-2">
              <button
                id="template-preview-cancel"
                type="button"
                phx-click="tmux:cancel_template_preview"
                class="rounded border border-base-300 px-3 py-1.5 text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
              >
                Cancel
              </button>
              <%= if template_preview_reconcile?(@template_preview) do %>
                <button
                  id="template-preview-apply-exact"
                  type="button"
                  phx-click="tmux:apply_previewed_template"
                  phx-value-mode="exact"
                  class="rounded border border-base-300 px-3 py-1.5 font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
                >
                  Exact replay
                </button>
              <% end %>
              <button
                id="template-preview-apply"
                type="button"
                phx-click="tmux:apply_previewed_template"
                phx-value-mode={template_preview_default_apply_mode(@template_preview)}
                class="rounded border border-primary bg-primary/10 px-3 py-1.5 font-medium text-primary transition hover:bg-primary/15"
              >
                {template_preview_apply_label(@template_preview)}
              </button>
            </div>
          </footer>
        </section>
      </div>
    <% else %>
      <div id="template-preview-empty" class="hidden"></div>
    <% end %>
    """
  end

  defp template_preview_reconcile?(%{diff: diff}) when is_map(diff), do: true
  defp template_preview_reconcile?(_preview), do: false

  defp template_preview_default_apply_mode(preview) do
    if template_preview_reconcile?(preview), do: "reconcile", else: "exact"
  end

  defp template_preview_apply_label(preview) do
    if template_preview_reconcile?(preview), do: "Apply reconcile", else: "Apply template"
  end

  defp template_preview_footer(%{diff: diff}) when is_map(diff) do
    changes = diff |> Map.get(:changes, []) |> length()
    "#{changes} reconciliation change(s)"
  end

  defp template_preview_footer(%{step_count: step_count}) do
    "#{step_count} planned tmux operation(s)"
  end

  defp template_reconcile_summary_items(summary) do
    Enum.map(@template_reconcile_summary_fields, fn {key, label} ->
      %{
        key: key |> Atom.to_string() |> String.replace("_", "-"),
        label: label,
        value: Map.get(summary || %{}, key, 0)
      }
    end)
  end

  defp template_reconcile_summary_sentence(summary) do
    summary = summary || %{}

    [
      summary_fragment(summary, :reuse_windows, "window to reuse", "windows to reuse"),
      summary_fragment(summary, :create_windows, "window to create", "windows to create"),
      summary_fragment(summary, :reuse_panes, "pane to reuse", "panes to reuse"),
      summary_fragment(summary, :new_panes, "pane to create", "panes to create"),
      summary_fragment(summary, :send_commands, "command to send", "commands to send")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "No tmux changes are needed."
      fragments -> "Would " <> Enum.join(fragments, ", ") <> "."
    end
  end

  defp summary_fragment(summary, key, singular, plural) do
    case Map.get(summary, key, 0) do
      0 -> nil
      1 -> "1 " <> singular
      count -> "#{count} #{plural}"
    end
  end

  defp template_disruption_label(disruption) do
    "Disruption: " <> template_value(disruption, "unknown")
  end

  defp template_disruption_class("low"),
    do:
      "rounded bg-success/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"

  defp template_disruption_class("medium"),
    do:
      "rounded bg-warning/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"

  defp template_disruption_class("high"),
    do:
      "rounded bg-error/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-error"

  defp template_disruption_class(_),
    do:
      "rounded bg-base-200 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-base-content/55"

  defp template_change_title(%{action: "reuse_window"} = change) do
    "Reuse window " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "create_window"} = change) do
    "Create window " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "reuse_pane"} = change) do
    "Reuse pane " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "split_pane"} = change) do
    "Split pane " <> template_value(template_ref_name(change), template_ref_value(change))
  end

  defp template_change_title(%{action: "send_command", command: command}) do
    "Run " <> template_value(command, "command")
  end

  defp template_change_title(%{action: "select_pane"} = change) do
    "Focus " <> template_value(template_ref_value(change), "pane")
  end

  defp template_change_title(%{action: action}), do: action

  defp template_change_detail(change) do
    [
      {"target", Map.get(change, :target_id)},
      {"ref", template_ref_value(change)},
      {"reason", Map.get(change, :reason)},
      {"direction", Map.get(change, :direction)},
      {"cwd", Map.get(change, :cwd)},
      {"command", Map.get(change, :command)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" · ")
  end

  defp template_change_class(action) when action in ["reuse_window", "reuse_pane"] do
    "rounded border border-success/25 bg-success/5 px-3 py-2 text-xs"
  end

  defp template_change_class(action) when action in ["create_window", "split_pane"] do
    "rounded border border-primary/25 bg-primary/5 px-3 py-2 text-xs"
  end

  defp template_change_class("send_command") do
    "rounded border border-info/25 bg-info/5 px-3 py-2 text-xs"
  end

  defp template_change_class(_action) do
    "rounded border border-base-300 bg-base-200/35 px-3 py-2 text-xs"
  end

  defp template_ref_name(change) do
    change
    |> Map.get(:template_ref, %{})
    |> Map.get(:name)
  end

  defp template_ref_value(change) do
    change
    |> Map.get(:template_ref, %{})
    |> Map.get(:ref)
  end

  defp render_template_library(assigns) do
    ~H"""
    <%= if @template_library_open do %>
      <div
        id="template-library-modal"
        class="fixed inset-0 z-[60] flex items-start justify-center bg-black/55 px-4 pt-16 text-base-content"
      >
        <section
          id="template-library-card"
          class="flex max-h-[82vh] w-[780px] max-w-[96vw] flex-col overflow-hidden rounded border border-base-300 bg-base-100 shadow-2xl"
        >
          <header class="flex items-start justify-between gap-4 border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <div class="text-[10px] font-semibold uppercase tracking-wide text-primary">
                Session templates
              </div>
              <h2 id="template-library-title" class="truncate text-sm font-semibold">
                {@workspace.name || @workspace.id}
              </h2>
              <p class="mt-1 text-xs text-base-content/60">
                {length(@saved_session_templates || [])} saved
              </p>
            </div>
            <button
              id="template-library-close"
              type="button"
              phx-click="tmux:close_template_library"
              class="rounded p-1 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
              title="Close template library"
              aria-label="Close template library"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div class="min-h-0 flex-1 overflow-auto px-4 py-4">
            <.form
              for={@template_save_form}
              id="template-save-form"
              phx-submit="tmux:save_template"
              class="mb-4 grid gap-3 rounded border border-base-300 bg-base-200/30 p-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)_auto]"
            >
              <.input
                field={@template_save_form[:name]}
                type="text"
                label="Name"
                placeholder="daily_layout"
                class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
              />
              <.input
                field={@template_save_form[:description]}
                type="text"
                label="Description"
                placeholder="Daily dev stack"
                class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
              />
              <div class="flex items-end">
                <button
                  id="template-save-submit"
                  type="submit"
                  class="inline-flex h-9 items-center gap-1.5 rounded border border-primary bg-primary/10 px-3 text-sm font-medium text-primary transition hover:bg-primary/15"
                  title="Save current layout"
                  aria-label="Save current layout"
                >
                  <.icon name="hero-bookmark-square" class="size-4" /> Save
                </button>
              </div>
            </.form>

            <div id="saved-template-list" class="space-y-2">
              <div
                :if={(@saved_session_templates || []) == []}
                id="template-library-empty"
                class="rounded border border-dashed border-base-300 px-3 py-6 text-center text-xs text-base-content/55"
              >
                No saved templates
              </div>
              <%= for saved <- @saved_session_templates || [] do %>
                <article
                  id={"saved-template-row-" <> saved.id}
                  class="rounded border border-base-300 bg-base-100 px-3 py-3 transition hover:border-primary/35 hover:bg-base-200/25"
                >
                  <%= if @template_edit_id == saved.id do %>
                    <.form
                      for={@template_edit_form}
                      id={"saved-template-edit-form-" <> saved.id}
                      phx-submit="tmux:update_saved_template"
                      class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.35fr)_auto]"
                    >
                      <input type="hidden" name="template[id]" value={saved.id} />
                      <.input
                        field={@template_edit_form[:name]}
                        id={"saved-template-edit-name-" <> saved.id}
                        type="text"
                        label="Name"
                        class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                      />
                      <.input
                        field={@template_edit_form[:description]}
                        id={"saved-template-edit-description-" <> saved.id}
                        type="text"
                        label="Description"
                        class="h-9 rounded border border-base-300 bg-base-100 px-3 text-sm text-base-content outline-none transition focus:border-primary focus:ring-1 focus:ring-primary"
                      />
                      <div class="flex items-end gap-1">
                        <button
                          id={"saved-template-edit-save-" <> saved.id}
                          type="submit"
                          class="inline-flex h-9 items-center gap-1.5 rounded border border-primary bg-primary/10 px-3 text-sm font-medium text-primary transition hover:bg-primary/15"
                          title="Save template metadata"
                          aria-label="Save template metadata"
                        >
                          <.icon name="hero-check" class="size-4" /> Save
                        </button>
                        <button
                          id={"saved-template-edit-cancel-" <> saved.id}
                          type="button"
                          phx-click="tmux:cancel_saved_template_edit"
                          class="inline-flex h-9 items-center rounded border border-base-300 px-2 text-sm text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
                          title="Cancel metadata edit"
                          aria-label="Cancel metadata edit"
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </button>
                      </div>
                    </.form>
                  <% else %>
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="flex flex-wrap items-center gap-2">
                          <h3 class="truncate text-sm font-medium">{saved.name}</h3>
                          <span class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-base-content/55">
                            v{saved.schema_version}
                          </span>
                          <%= unless Templates.apply_supported?(saved) do %>
                            <span class="rounded bg-warning/10 px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-warning">
                              unsupported
                            </span>
                          <% end %>
                        </div>
                        <p class="mt-1 line-clamp-2 text-xs text-base-content/60">
                          {saved_template_description(saved)}
                        </p>
                        <p class="mt-2 text-[10px] text-base-content/45">
                          {saved_template_window_count(saved)} window(s) · {saved_template_pane_count(
                            saved
                          )} pane(s) · {saved_template_timestamp(saved)}
                        </p>
                      </div>
                      <div class="flex shrink-0 items-center gap-1">
                        <button
                          id={"saved-template-edit-" <> saved.id}
                          type="button"
                          phx-click="tmux:edit_saved_template"
                          phx-value-template-id={saved.id}
                          class="rounded p-1.5 text-base-content/45 transition hover:bg-base-200 hover:text-base-content"
                          title="Edit saved template metadata"
                          aria-label="Edit saved template metadata"
                        >
                          <.icon name="hero-pencil-square" class="size-4" />
                        </button>
                        <button
                          id={"saved-template-preview-" <> saved.id}
                          type="button"
                          phx-click="tmux:preview_template"
                          phx-value-template-id={saved.id}
                          disabled={!Templates.apply_supported?(saved)}
                          class="rounded p-1.5 text-base-content/55 transition hover:bg-primary/10 hover:text-primary disabled:cursor-not-allowed disabled:opacity-35"
                          title="Preview saved template"
                          aria-label="Preview saved template"
                        >
                          <.icon name="hero-eye" class="size-4" />
                        </button>
                        <button
                          id={"saved-template-apply-" <> saved.id}
                          type="button"
                          phx-click="tmux:preview_template"
                          phx-value-template-id={saved.id}
                          disabled={!Templates.apply_supported?(saved)}
                          class="rounded p-1.5 text-base-content/55 transition hover:bg-primary/10 hover:text-primary disabled:cursor-not-allowed disabled:opacity-35"
                          title="Preview and apply saved template"
                          aria-label="Preview and apply saved template"
                        >
                          <.icon name="hero-play" class="size-4" />
                        </button>
                        <button
                          id={"saved-template-delete-" <> saved.id}
                          type="button"
                          phx-click="tmux:delete_saved_template"
                          phx-value-template-id={saved.id}
                          class="rounded p-1.5 text-base-content/45 transition hover:bg-error/10 hover:text-error"
                          title="Delete saved template"
                          aria-label="Delete saved template"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </button>
                      </div>
                    </div>
                  <% end %>
                </article>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    <% else %>
      <div id="template-library-empty-state" class="hidden"></div>
    <% end %>
    """
  end

  defp template_step_title(%{action: "new_window", params: params}) do
    "New window " <> template_value(Map.get(params, :name), "window")
  end

  defp template_step_title(%{action: "split_pane", ref: ref}) do
    "Split pane " <> template_value(ref, "pane")
  end

  defp template_step_title(%{action: "send_command", params: params}) do
    "Run " <> template_value(Map.get(params, :command), "command")
  end

  defp template_step_title(%{action: "select_pane", target_ref: target_ref}) do
    "Focus " <> template_value(target_ref, "pane")
  end

  defp template_step_title(%{action: action}), do: action

  defp template_step_detail(step) do
    params = Map.get(step, :params, %{})

    [
      {"ref", Map.get(step, :ref)},
      {"target", Map.get(step, :target_ref)},
      {"cwd", Map.get(params, :cwd)},
      {"direction", Map.get(params, :direction)},
      {"size", Map.get(params, :size_percent)},
      {"command", Map.get(params, :command)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" · ")
  end

  defp template_value(nil, fallback), do: fallback
  defp template_value("", fallback), do: fallback
  defp template_value(value, _fallback), do: to_string(value)

  defp saved_template_description(%{description: description})
       when is_binary(description) and description != "",
       do: description

  defp saved_template_description(%{source_session: session})
       when is_binary(session) and session != "",
       do: "Exported from " <> session

  defp saved_template_description(_saved), do: "Exported tmux layout"

  defp saved_template_window_count(saved) do
    saved
    |> saved_template_windows()
    |> length()
  end

  defp saved_template_pane_count(saved) do
    saved
    |> saved_template_windows()
    |> Enum.map(&saved_template_layout_pane_count(Map.get(&1, "layout", %{})))
    |> Enum.sum()
  end

  defp saved_template_windows(%{body: %{"windows" => windows}}) when is_list(windows), do: windows
  defp saved_template_windows(_saved), do: []

  defp saved_template_layout_pane_count(%{"panes" => panes}) when is_list(panes) do
    case panes do
      [] -> 1
      _ -> panes |> Enum.map(&saved_template_layout_pane_count/1) |> Enum.sum()
    end
  end

  defp saved_template_layout_pane_count(_layout), do: 1

  defp saved_template_timestamp(%{inserted_at: %DateTime{} = inserted_at}) do
    Calendar.strftime(inserted_at, "%Y-%m-%d %H:%M UTC")
  end

  defp saved_template_timestamp(_saved), do: "saved"

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
              placeholder="Type to search files / actions…"
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

  defp load_project_meta(socket) do
    case host_path(socket) do
      {:ok, root} ->
        socket
        |> assign(:project_meta, ElixirNav.project(root))
        |> assign(:tooling, ElixirNav.tooling(root))

      _ ->
        socket
    end
  end

  defp render_agents(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-3 overflow-auto pr-1">
      {render_safety_card(assigns)}
      <div class="rounded border border-amber-300 bg-amber-50 p-3 text-xs text-amber-900">
        <strong>Write mode: disabled.</strong>
        Agent attach is read-only. Phoenix does not start agents, send prompts, or grant write access.
      </div>
      <div class="flex justify-end">
        <button phx-click="agents:refresh" class="text-xs rounded border px-2 py-1">↻ refresh</button>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-2 2xl:grid-cols-3 gap-3">
        <%= for cap <- @agent_caps do %>
          <div class="border rounded p-3">
            <div class="flex justify-between items-baseline">
              <h3 class="font-medium">{cap_label(cap.kind)}</h3>
              <span class={cap_status_class(cap.status)}>{cap.status}</span>
            </div>
            <%= if cap.status == :detected do %>
              <dl class="text-xs text-zinc-600 space-y-0.5 mt-1">
                <div>source: {cap.source}</div>
                <%= if cap.path do %>
                  <div class="font-mono">path: {cap.path}</div>
                <% end %>
                <%= if cap.url do %>
                  <div class="font-mono">url: {cap.url}</div>
                  <%= if cap.kind == :tidewave do %>
                    <a
                      id="agent-cap-tidewave-open"
                      href={cap.url}
                      target="_blank"
                      rel="noopener"
                      class="inline-flex items-center rounded border border-blue-200 bg-blue-50 px-2 py-1 font-sans text-[11px] font-medium text-blue-700 transition hover:border-blue-300 hover:bg-blue-100"
                    >
                      Open Tidewave
                    </a>
                  <% end %>
                <% end %>
                <%= if cap.mtime do %>
                  <div>updated: {NaiveDateTime.to_string(cap.mtime)}</div>
                <% end %>
                <%= if cap.details != %{} do %>
                  <div class="font-mono text-zinc-400">{inspect(cap.details)}</div>
                <% end %>
              </dl>
            <% else %>
              <p class="text-xs text-zinc-500 mt-1">not detected</p>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="border rounded p-3 space-y-2">
        <h3 class="font-medium">Agent Runs (review mode)</h3>
        <p class="text-xs text-zinc-500">
          Phoenix may start an allowlisted, write-free command and observe its output.
          No prompts, no patches, no Apply path.
        </p>
        <%= if @agent_run_error do %>
          <p class="text-xs text-red-700">{@agent_run_error}</p>
        <% end %>
        <%= if @agent_review_cmds == [] do %>
          <p class="text-xs text-zinc-500">
            No review commands available — required capabilities not detected.
          </p>
        <% else %>
          <div class="flex flex-wrap gap-2">
            <%= for cmd <- @agent_review_cmds do %>
              <button
                phx-click="agent_run:start"
                phx-value-id={cmd.id}
                disabled={@agent_run && @agent_run.status == :running}
                title={cmd.description}
                class="text-xs rounded border px-2 py-1 disabled:opacity-50"
              >
                ▶ {cmd.id}
              </button>
            <% end %>
            <%= if @agent_run && @agent_run.status == :running do %>
              <button
                phx-click="agent_run:cancel"
                class="text-xs rounded border px-2 py-1 text-red-700"
              >
                cancel
              </button>
            <% end %>
          </div>
        <% end %>
        <%= if @agent_run do %>
          <div class="text-xs font-mono text-zinc-500 flex flex-wrap gap-3">
            <span>{Enum.join(@agent_run.argv, " ")}</span>
            <span class={cap_status_class(@agent_run.status)}>{@agent_run.status}</span>
            <%= if @agent_run.exit_code != nil do %>
              <span>exit={inspect(@agent_run.exit_code)}</span>
            <% end %>
            <%= if @agent_run.started_at do %>
              <span>started {DateTime.to_string(@agent_run.started_at)}</span>
            <% end %>
            <%= if @agent_run.finished_at do %>
              <span>finished {DateTime.to_string(@agent_run.finished_at)}</span>
            <% end %>
          </div>
          <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded max-h-72 overflow-auto whitespace-pre-wrap">{@agent_run.buffer}</pre>
        <% end %>
      </div>

      {render_proposals(assigns)}

      <div class="border rounded p-3">
        <h3 class="font-medium mb-2">Recent agent transcripts (read-only)</h3>
        <ul id="agent-transcripts" phx-update="stream" class="text-xs space-y-1">
          <li id="agent-transcripts-empty" class="hidden only:block text-zinc-500">
            No transcripts found.
          </li>
          <%= for {dom_id, a} <- @streams.agent_transcripts do %>
            <li id={dom_id} class="font-mono flex justify-between">
              <button
                phx-click="tree:open"
                phx-value-path={a.rel_path}
                class="hover:underline text-left flex-1 truncate"
              >
                {a.rel_path}
              </button>
              <span class="text-zinc-500 ml-2">
                {a.size}b {if a.mtime, do: "· " <> NaiveDateTime.to_string(a.mtime)}
              </span>
            </li>
          <% end %>
        </ul>
      </div>
    </section>
    """
  end

  defp render_proposals(assigns) do
    ~H"""
    <div class="border rounded p-3 space-y-2">
      <h3 class="font-medium">Proposal Review</h3>
      <p class="text-xs text-zinc-500">
        Review only. To apply a proposal, copy it or use terminal/git manually.
      </p>
      <%= if @proposals_count == 0 do %>
        <p class="text-xs text-zinc-500">No proposals discovered.</p>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-[260px_1fr] gap-3">
          <ul id="proposals" phx-update="stream" class="text-xs space-y-1 max-h-72 overflow-auto">
            <%= for {dom_id, p} <- @streams.proposals do %>
              <li id={dom_id}>
                <button
                  phx-click="proposal:select"
                  phx-value-path={p.rel_path}
                  class={"w-full text-left rounded px-1 py-0.5 hover:bg-zinc-100 " <> if @selected_proposal && @selected_proposal.rel_path == p.rel_path, do: "bg-zinc-200", else: ""}
                >
                  <span class="font-mono truncate block">{p.rel_path}</span>
                  <span class="text-zinc-500">
                    {p.size}b {if p.mtime, do: "· " <> NaiveDateTime.to_string(p.mtime)}
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
          <div class="border rounded p-2 min-h-[12rem]">
            <%= if @selected_proposal do %>
              {render_proposal_detail(assigns, @selected_proposal)}
            <% else %>
              <p class="text-xs text-zinc-500">Select a proposal to preview.</p>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_proposal_detail(assigns, proposal) do
    _ = assigns.proposal_analysis
    git_paths = MapSet.new(assigns.git_status, & &1.path)
    proposal_paths = MapSet.new(proposal.changes, & &1.path)

    in_both = MapSet.intersection(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    only_proposal =
      MapSet.difference(proposal_paths, git_paths) |> MapSet.to_list() |> Enum.sort()

    only_workspace =
      MapSet.difference(git_paths, proposal_paths) |> MapSet.to_list() |> Enum.sort()

    assigns =
      assigns
      |> Map.put(:p, proposal)
      |> Map.put(:in_both, in_both)
      |> Map.put(:only_proposal, only_proposal)
      |> Map.put(:only_workspace, only_workspace)

    ~H"""
    <div class="space-y-2 text-xs">
      <div class="flex justify-between font-mono">
        <span class="truncate">{@p.rel_path}</span>
        <button phx-click="proposal:clear" class="rounded border px-1.5">close</button>
      </div>
      <dl class="text-zinc-600 space-y-0.5">
        <div>parser: {@p.parser}</div>
        <div>
          status: <span class={proposal_status_class(@p.status)}>{@p.status}</span>
          <%= if @p.truncated do %>
            · (preview truncated)
          <% end %>
        </div>
        <%= if @p.size > 0 do %>
          <div>size: {@p.size}b</div>
        <% end %>
        <%= if @p.mtime do %>
          <div>mtime: {NaiveDateTime.to_string(@p.mtime)}</div>
        <% end %>
        <%= if @p.error do %>
          <div class="text-red-700">error: {@p.error}</div>
        <% end %>
      </dl>

      <%= if @proposal_analysis do %>
        <div class="border rounded p-2 bg-zinc-50 space-y-1">
          <div class="flex items-center gap-2">
            <strong>Conflict analysis:</strong>
            <span class={analysis_class(@proposal_analysis.risk)}>
              {@proposal_analysis.risk}
            </span>
            <span class="text-zinc-500">— {@proposal_analysis.reason}</span>
          </div>
          <%= if @proposal_analysis.overlapping_files != [] do %>
            <div>
              <span class="text-zinc-500">overlapping files:</span>
              <ul class="font-mono ml-3 list-disc">
                <%= for f <- @proposal_analysis.files,
                        f.status in [:overlap, :conflict] do %>
                  <li>
                    {f.status} · {f.path}
                    <%= if f.hunks != [] do %>
                      <ul class="text-zinc-500 ml-3 list-square">
                        <%= for o <- f.hunks do %>
                          <li>
                            proposal hunk @{elem(o.proposal.old_range, 0)},{elem(
                              o.proposal.old_range,
                              1
                            )} ↔ workspace @{elem(o.workspace.old_range, 0)},{elem(
                              o.workspace.old_range,
                              1
                            )}
                          </li>
                        <% end %>
                      </ul>
                    <% end %>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @p.status == :parsed do %>
        <div>
          <strong>Changed files in proposal:</strong>
          <ul class="font-mono ml-3 list-disc">
            <%= for c <- @p.changes do %>
              <li>{c.kind} · {c.path}</li>
            <% end %>
          </ul>
        </div>

        <div class="grid grid-cols-3 gap-2">
          <div>
            <strong class="block">In both</strong>
            <%= if @in_both == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @in_both do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Proposal only</strong>
            <%= if @only_proposal == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_proposal do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
          <div>
            <strong class="block">Workspace only</strong>
            <%= if @only_workspace == [] do %>
              <p class="text-zinc-400">—</p>
            <% else %>
              <ul class="font-mono">
                <%= for p <- @only_workspace do %>
                  <li class="truncate">{p}</li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </div>

        <%= if @p.diff do %>
          <details>
            <summary class="cursor-pointer">unified diff preview</summary>
            <pre class="bg-zinc-950 text-zinc-100 p-2 rounded mt-1 overflow-auto max-h-72 whitespace-pre-wrap">{@p.diff}</pre>
          </details>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp analysis_class(:clean), do: "text-green-700"
  defp analysis_class(:overlap), do: "text-amber-700"
  defp analysis_class(:conflict), do: "text-red-700"
  defp analysis_class(_), do: "text-zinc-500"

  defp proposal_status_class(:parsed), do: "text-green-700"
  defp proposal_status_class(:invalid), do: "text-red-700"
  defp proposal_status_class(:too_large), do: "text-amber-700"
  defp proposal_status_class(_), do: "text-zinc-500"

  defp render_safety_card(assigns) do
    ~H"""
    <div class="border rounded p-3 bg-zinc-50">
      <h3 class="font-medium mb-2">Workspace safety</h3>
      <dl class="grid grid-cols-2 gap-y-1 text-xs">
        <dt class="text-zinc-500">mode</dt>
        <dd class="flex items-center gap-2">
          <span class="font-mono">{@workspace_mode}</span>
          <span class="text-zinc-500">({@workspace_mode_source})</span>
          <%= if can_set_mode?(@workspace_mode_source) do %>
            <.form for={%{}} phx-change="workspace:set_mode" class="inline-flex">
              <select name="mode" class="border rounded px-1 py-0 text-xs">
                <%= for m <- DevIDE.Policy.WorkspaceMode.valid_modes() do %>
                  <option value={Atom.to_string(m)} selected={m == @workspace_mode}>
                    {m}
                  </option>
                <% end %>
              </select>
            </.form>
          <% end %>
        </dd>
        <%= if @workspace_record && @workspace_record.last_seen_at do %>
          <dt class="text-zinc-500">last sync</dt>
          <dd class="font-mono text-[10px]">{DateTime.to_iso8601(@workspace_record.last_seen_at)}</dd>
        <% end %>
        <dt class="text-zinc-500">db isolation</dt>
        <dd>
          <span class={isolation_class(@db_isolation.isolation)}>{@db_isolation.isolation}</span>
          <%= if @db_isolation.source != :none do %>
            <span class="text-zinc-500">· {@db_isolation.source}</span>
          <% end %>
          <%= if @db_isolation.summary do %>
            <span class="font-mono text-zinc-700">· {@db_isolation.summary}</span>
          <% end %>
          <button phx-click="isolation:refresh" class="text-[10px] rounded border px-1 ml-1">
            ↻
          </button>
          <%= if @db_isolation.detected_at do %>
            <div class="text-[10px] text-zinc-400">
              at {DateTime.to_iso8601(@db_isolation.detected_at)}
            </div>
          <% end %>
        </dd>
        <dt class="text-zinc-500">agent write</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">
            — {agent_write_reason_full(@workspace_mode, @db_isolation.isolation)}
          </span>
        </dd>
        <dt class="text-zinc-500">proposal apply</dt>
        <dd>
          <span class="text-red-700">disabled</span>
          <span class="text-zinc-500">— not implemented</span>
        </dd>
        <%= if @last_decision do %>
          <dt class="text-zinc-500">last decision</dt>
          <dd class="font-mono text-zinc-700">
            {@last_decision.action} · {@last_decision.verdict}
            {if @last_decision.reason, do: "· " <> Atom.to_string(@last_decision.reason)}
          </dd>
        <% end %>
      </dl>
      <%= if @audit_events_count > 0 do %>
        <p class="text-[11px] text-zinc-500 mt-2">
          {@audit_events_count} audit events ·
          <button phx-click="audit_drawer:toggle" class="underline hover:text-zinc-800">
            open evidence
          </button>
        </p>
      <% end %>
    </div>
    """
  end

  defp agent_write_reason_full(_mode, :shared_stage), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_mode, :unsafe), do: "DB target looks unsafe; refused by policy"
  defp agent_write_reason_full(:shared_stage_guarded, _), do: "shared Stage DB; refused by policy"
  defp agent_write_reason_full(_, _), do: "agent write locked"

  defp isolation_class(:shared_stage), do: "text-red-700 font-mono"
  defp isolation_class(:unsafe), do: "text-red-700 font-mono"
  defp isolation_class(:ephemeral), do: "text-green-700 font-mono"
  defp isolation_class(:local), do: "text-amber-700 font-mono"
  defp isolation_class(_), do: "text-zinc-500 font-mono"

  defp cap_label(:opencode), do: "OpenCode"
  defp cap_label(:tidewave), do: "Tidewave MCP"
  defp cap_label(:preview_mcp), do: "Preview MCP"
  defp cap_label(:fff), do: "FFF MCP"
  defp cap_label(:browser_artifacts), do: "Browser artifacts"
  defp cap_label(:transcripts), do: "Transcripts"
  defp cap_label(other), do: to_string(other)

  defp cap_status_class(:detected), do: "text-green-700 text-xs"
  defp cap_status_class(:missing), do: "text-zinc-400 text-xs"

  # Markup lives in DevIdeWeb.WorkspaceLive.Show.LogsPanel (imported above);
  # this stays as the call-convention wrapper used by render/1.
  defp render_logs(assigns) do
    ~H"""
    <.logs_panel log_service={@log_service} log_ref={@log_ref} streams={@streams} />
    """
  end

  # render_path/2 and tab_class/2 now live in DevIdeWeb.WorkspaceLive.Show.UI
  # (imported above).

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  defp refresh_tmux_topology(socket) do
    topology = TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: tmux_adapter())

    assign_tmux_topology(socket, topology)
  end

  defp assign_tmux_topology(socket, topology) do
    socket
    |> assign(:tmux_windows, topology.windows)
    |> assign(:tmux_panes, topology.panes)
    |> assign(:tmux_active_window_id, topology.active_window_id)
    |> assign(:tmux_active_pane_id, topology.active_pane_id)
    |> assign(:tmux_topology_version, topology.version)
  end

  defp subscribe_tmux_topology(socket) do
    if connected?(socket) do
      _ =
        TmuxTopology.ensure_started(socket.assigns.tmux_session,
          workspace_id: socket.assigns.workspace.id
        )

      _ = TmuxTopology.subscribe(socket.assigns.tmux_session)
    end

    socket
  end

  # Subscribe to live preview observations for this workspace so the Agent
  # preview panel follows agent-driven (MCP) browsing in real time, not just on
  # this viewer's own panel actions. See PreviewControl.broadcast_observation/2.
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

  defp maybe_select_requested_tmux_window(socket, nil), do: socket
  defp maybe_select_requested_tmux_window(socket, ""), do: socket

  defp maybe_select_requested_tmux_window(socket, window_id) when is_binary(window_id) do
    case tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
      :ok -> socket
      {:error, _reason} -> socket
    end
  end

  defp ensure_primary_tmux_session(socket) do
    case tmux_adapter().ensure_session(socket.assigns.tmux_session, workspace_cwd(socket)) do
      :ok -> socket
      {:error, _reason} -> socket
    end
  end

  defp template_save_form(params \\ %{}) do
    params =
      %{"name" => "", "description" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value} end))

    to_form(params, as: :template)
  end

  defp template_edit_form(params \\ %{}) do
    params =
      %{"id" => "", "name" => "", "description" => ""}
      |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value || ""} end))

    to_form(params, as: :template)
  end

  defp rename_tmux_window(socket, window_id, name) do
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

  defp apply_session_template(socket, template_id, opts \\ []) do
    socket =
      socket
      |> assign(:template_preview, nil)
      |> assign(:template_library_open, false)
      |> ensure_primary_tmux_session()

    case execute_session_template(socket, template_id, opts) do
      {:ok, result} ->
        socket = refresh_tmux_topology(socket)
        emit_tmux_template_audit(socket, template_id, result)

        socket =
          case socket.assigns.tmux_active_window_id do
            nil -> socket
            window_id -> push_patch(socket, to: workspace_window_path(socket, window_id))
          end

        {:noreply,
         put_flash(socket, :info, "Applied session template: #{template_result_name(result)}")}

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
    topology = TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: tmux_adapter())

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
    opts = [tmux: tmux_adapter(), workspace_root: workspace_cwd(socket)]

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
    topology = TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: tmux_adapter())
    opts = [tmux: tmux_adapter(), workspace_root: workspace_cwd(socket)]

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

  defp get_session_template(socket, template_id) do
    case SessionTemplate.get(template_id) do
      {:ok, template} ->
        {:ok, template}

      {:error, :template_not_found} ->
        case Templates.get(socket.assigns.workspace.id, template_id) do
          {:ok, saved} ->
            if Templates.apply_supported?(saved),
              do: {:ok, saved},
              else: {:error, :unsupported_template}

          {:error, :not_found} ->
            {:error, :template_not_found}
        end
    end
  end

  defp save_current_session_template(socket, params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    description = params |> Map.get("description", "") |> to_string() |> String.trim()

    if name == "" do
      {:noreply,
       socket
       |> assign(:template_library_open, true)
       |> assign(:template_save_form, template_save_form(params))
       |> put_flash(:error, "Template name cannot be blank.")}
    else
      topology = TmuxTopology.snapshot(socket.assigns.tmux_session, tmux: tmux_adapter())

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
               schema_version: Map.get(template, "version", 2)
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
    attrs = Map.take(params, ["name", "description"])

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
       |> put_flash(:info, "Deleted saved template: #{saved.name}")}
    else
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

  defp refresh_saved_session_templates(socket) do
    socket =
      assign(
        socket,
        :saved_session_templates,
        Templates.list_for_workspace(socket.assigns.workspace.id)
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

  defp template_update_changes(before, after_update) do
    [:name, :description]
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

  defp workspace_window_path(socket, window_id) do
    base = ~p"/workspaces/#{socket.assigns.workspace.id}"

    query =
      %{"host" => socket.assigns.host_id, "window" => window_id}
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  defp terminal_tab_class(true),
    do:
      "text-xs rounded border border-primary bg-primary/10 px-2.5 py-0.5 text-primary font-medium"

  defp terminal_tab_class(false),
    do:
      "text-xs rounded border border-base-300 px-2.5 py-0.5 text-base-content/70 hover:bg-base-200"

  defp shorten(nil), do: ""

  defp shorten(s) when is_binary(s) do
    if String.length(s) > 18, do: String.slice(s, 0, 15) <> "…", else: s
  end

  # Audit raw-shell mode transitions. Entering :raw opens an unconstrained
  # PTY against the workspace; leaving it tears that PTY down. Both are
  # security-interesting boundary crossings — the snapshot button already
  # audits, this fills the gap for the surface itself.
  defp audit_terminal_mode_transition(socket, from, to) when from == to, do: socket

  defp audit_terminal_mode_transition(socket, from, to)
       when to in [:raw, :raw_ghostty, :governed] do
    action =
      case to do
        :raw -> "terminal.raw_entered"
        :raw_ghostty -> "ghostty.raw_terminal_entered"
        :governed -> "ghostty.raw_terminal_exited"
      end

    DevIDE.Audit.emit!(%{
      action: action,
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
      target_type: "terminal",
      target_ref: @ghostty_term_id,
      metadata: %{
        "from" => to_string(from),
        "to" => to_string(to),
        "host_id" => socket.assigns[:host_id],
        "workspace_mode" => to_string(socket.assigns[:workspace_mode])
      }
    })

    socket
  end

  defp raw_terminal_allowed?(:manual, host_id), do: host_id in ["local", "localhost"]

  defp raw_terminal_allowed?(_mode, host_id) do
    # Dev override: in `config :dev_ide, :allow_local_raw_terminal, true`,
    # local hosts can open the raw shell even when the workspace is not in
    # :manual mode. Off by default so the production boundary (and
    # `TerminalBoundaryLiveTest`) stays tight.
    host_id in ["local", "localhost"] and
      Application.get_env(:dev_ide, :allow_local_raw_terminal, false)
  end

  defp handle_paste_file(params, socket, kind) do
    socket = refresh_workspace_mode(socket)

    cond do
      not raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) ->
        {:reply, %{ok: false, reason: "raw terminal access is required to paste files"}, socket}

      true ->
        case host_path(socket) do
          {:ok, root} ->
            case save_clipboard_file(root, params, kind) do
              {:ok, result} ->
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

                {:reply,
                 %{
                   ok: true,
                   path: result.path,
                   relative_path: result.relative_path,
                   bytes: result.bytes,
                   content_type: result.content_type
                 }, socket}

              {:error, reason} ->
                {:reply, %{ok: false, reason: paste_file_reason(reason)}, socket}
            end

          _ ->
            {:reply, %{ok: false, reason: "workspace path is not available"}, socket}
        end
    end
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
    # All-in on Ghostty: :raw now means Ghostty-based raw terminal.
    # The old xterm.js raw path is deprecated for raw shells.
    if raw_terminal_allowed?(mode, host_id), do: :raw, else: :governed
  end

  # --- Layout helpers (Phase 2) ---

  defp get_pane_data(socket, pane_id) do
    Map.get(socket.assigns.pane_data, pane_id)
  end

  # When a pane is zoomed, render just that pane full-size by handing
  # TerminalSurface a single-pane layout. The real @pane_layout (the split
  # tree) is untouched, so unzoom restores it. Falls back to the full layout if
  # the zoomed pane no longer exists.
  defp surface_layout(layout, nil, _pane_data), do: layout

  defp surface_layout(layout, zoomed_id, pane_data) do
    if is_map(pane_data) and Map.has_key?(pane_data, zoomed_id) do
      {:pane, zoomed_id}
    else
      layout
    end
  end

  defp terminal_surface_panes(pane_data) when is_map(pane_data) do
    Map.new(pane_data, fn {pane_id, pane} ->
      {pane_id,
       %TerminalSurfacePane{
         term: Map.get(pane, :ghostty_term),
         pty: Map.get(pane, :ghostty_pty),
         error: Map.get(pane, :error),
         session_sid: Map.get(pane, :session_sid)
       }}
    end)
  end

  defp focused_pane_session_sid(pane_data, focused_pane_id, fallback_sid)
       when is_map(pane_data) do
    case Map.get(pane_data, focused_pane_id) do
      %{session_sid: sid} when is_binary(sid) and sid != "" -> sid
      _ -> fallback_sid
    end
  end

  defp focused_pane_session_sid(_pane_data, _focused_pane_id, fallback_sid), do: fallback_sid

  defp remember_preview_candidates(socket, pane_id, data) do
    candidates = DevIDE.Previews.discover_candidates(data)

    if candidates == [] do
      socket
    else
      pane = get_pane_data(socket, pane_id) || %{}
      now = System.system_time(:millisecond)

      next =
        Enum.reduce(candidates, socket.assigns.preview_candidates || %{}, fn candidate, acc ->
          candidate =
            candidate
            |> Map.put(:pane_id, pane_id)
            |> Map.put(:session_id, Map.get(pane, :session_sid, socket.assigns.terminal_sid))
            |> Map.put(:detected_at, now)

          Map.put(acc, candidate.url, candidate)
        end)

      socket
      |> assign(:preview_candidates, next)
      |> maybe_auto_open_detected_preview()
    end
  end

  defp preview_candidate_list(candidates) when is_map(candidates) do
    now = System.system_time(:millisecond)

    candidates
    |> Map.values()
    |> Enum.reject(&(Map.get(&1, :port) == dev_ide_listen_port()))
    |> Enum.reject(&preview_candidate_expired?(&1, now))
    |> Enum.sort_by(& &1.detected_at, :desc)
    |> Enum.take(6)
  end

  defp preview_candidate_list(_), do: []

  defp visible_preview_candidate_list(assigns) when is_map(assigns) do
    dismissed = candidate_url_set(assigns[:dismissed_preview_candidate_urls])
    opened = candidate_url_set(assigns[:opened_preview_candidate_urls])
    active_url = active_preview_url(assigns)

    assigns[:preview_candidates]
    |> preview_candidate_list()
    |> Enum.reject(fn candidate ->
      key = candidate_url_key(candidate.url)

      is_nil(key) or key == active_url or MapSet.member?(dismissed, key) or
        MapSet.member?(opened, key)
    end)
  end

  defp visible_preview_candidate_list(_), do: []

  defp manual_preview_candidate_list(socket) do
    dismissed = candidate_url_set(socket.assigns[:dismissed_preview_candidate_urls])

    socket.assigns[:preview_candidates]
    |> preview_candidate_list()
    |> Enum.reject(fn candidate ->
      key = candidate_url_key(candidate.url)
      is_nil(key) or MapSet.member?(dismissed, key)
    end)
  end

  defp best_manual_preview_candidate(socket) do
    socket
    |> manual_preview_candidate_list()
    |> List.first()
  end

  defp preview_candidate_for_url(_socket, nil), do: nil
  defp preview_candidate_for_url(_socket, ""), do: nil

  defp preview_candidate_for_url(socket, url) do
    key = candidate_url_key(url)
    candidates = manual_preview_candidate_list(socket)

    Enum.find(candidates, &(&1.url == url)) ||
      Enum.find(candidates, &(candidate_url_key(&1.url) == key))
  end

  defp best_auto_preview_candidate(socket) do
    socket.assigns
    |> visible_preview_candidate_list()
    |> List.first()
  end

  defp preview_candidate_expired?(%{detected_at: detected_at}, now)
       when is_integer(detected_at) do
    detected_at < now - @preview_candidate_ttl_ms
  end

  defp preview_candidate_expired?(_, _), do: false

  defp active_preview_url(%{active_preview: %{url: url}}), do: candidate_url_key(url)
  defp active_preview_url(_), do: nil

  defp candidate_url_key(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      key -> key
    end
  end

  defp candidate_url_key(nil), do: nil
  defp candidate_url_key(url), do: url |> to_string() |> candidate_url_key()

  defp candidate_url_set(%MapSet{} = set), do: set
  defp candidate_url_set(_), do: MapSet.new()

  defp put_candidate_url(urls, nil), do: candidate_url_set(urls)

  defp put_candidate_url(urls, url) do
    urls
    |> candidate_url_set()
    |> MapSet.put(url)
  end

  defp open_preview(socket, %{"url" => url} = params) do
    workspace = socket.assigns.workspace
    mode = params["mode"] || "tab"

    mode =
      if DevIDE.Previews.is_trusted_url?(url, workspace) do
        preview_mode(mode)
      else
        :tab
      end

    attrs = %{
      url: url,
      title: DevIDE.Previews.extract_title_from_url(url),
      mode: mode,
      session_id: preview_session_id(socket, params),
      pane_id: preview_pane_id(socket, params),
      actor_id: current_actor_id(socket)
    }

    case find_open_preview_for_url(workspace.id, url) do
      %DevIDE.Previews.Preview{} = preview ->
        open_preview_result(socket, preview)

      nil ->
        case DevIDE.Previews.open(workspace, attrs) do
          {:ok, preview} ->
            open_preview_result(socket, preview)

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to open preview")}
        end
    end
  end

  defp open_surface_preview(socket, surface, params) do
    case open_agent_surface(socket, surface, preview_mode(params["mode"] || "iframe")) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, :surface_not_found, socket} ->
        {:noreply, put_flash(socket, :error, "Preview surface not found: #{surface}")}

      {:error, reason, socket} ->
        {:noreply, put_flash(socket, :error, "Failed to open preview: #{inspect(reason)}")}
    end
  end

  defp open_preview_result(socket, preview) do
    socket = finish_agent_preview_open(socket, preview)

    if preview.mode == :tab do
      {:noreply,
       push_event(socket, "open-preview-tab", %{url: preview.url, title: preview.title})}
    else
      {:noreply, socket}
    end
  end

  defp maybe_auto_open_agent_preview(socket) do
    workspace = socket.assigns.workspace

    cond do
      socket.assigns[:active_preview] ->
        socket

      DevIDE.Previews.primary_surface(workspace) ->
        start_agent_preview(socket)

      true ->
        maybe_auto_open_detected_preview(socket)
    end
  end

  defp maybe_auto_open_detected_preview(socket) do
    cond do
      socket.assigns[:active_preview] ->
        socket

      DevIDE.Previews.primary_surface(socket.assigns.workspace) ->
        socket

      true ->
        case best_auto_preview_candidate(socket) do
          nil -> socket
          candidate -> auto_open_detected_preview(socket, candidate)
        end
    end
  end

  defp start_agent_preview(socket) do
    workspace = socket.assigns.workspace

    case DevIDE.Previews.primary_surface(workspace) do
      nil ->
        socket

      %{name: name} ->
        _ = DevIDE.Previews.close_all_open(workspace.id)

        socket =
          socket
          |> close_stale_open_previews(name)

        case find_open_preview_for_surface(workspace.id, name) do
          %DevIDE.Previews.Preview{} = preview ->
            activate_agent_preview(socket, preview)

          nil ->
            case open_agent_surface(socket, name, :iframe) do
              {:ok, socket} -> socket
              _ -> socket
            end
        end
    end
  end

  defp open_agent_surface(socket, surface_name, mode) do
    workspace = socket.assigns.workspace

    case DevIDE.PreviewControl.open_session(workspace, surface_name,
           actor_id: current_actor_id(socket),
           mode: mode
         ) do
      {:ok, control_session} ->
        preview = DevIDE.Previews.get_for_workspace!(control_session.preview_id, workspace.id)

        socket =
          socket
          |> assign(:active_preview_control_session, control_session)
          |> observe_preview_control(control_session.id)
          |> finish_agent_preview_open(preview)

        send(self(), :agent_preview_screenshot)
        {:ok, socket}

      {:error, :surface_not_found} ->
        {:error, :surface_not_found, socket}

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  defp auto_open_detected_preview(socket, candidate) do
    workspace = socket.assigns.workspace
    url = candidate.url

    mode =
      if DevIDE.Previews.is_trusted_url?(url, workspace), do: :iframe, else: :tab

    attrs = %{
      url: url,
      title: DevIDE.Previews.extract_title_from_url(url),
      mode: mode,
      session_id: candidate.session_id,
      pane_id: candidate.pane_id,
      actor_id: current_actor_id(socket)
    }

    case find_open_preview_for_url(workspace.id, url) do
      %DevIDE.Previews.Preview{} = preview ->
        socket
        |> finish_agent_preview_open(preview)
        |> then(fn s ->
          send(self(), :agent_preview_screenshot)
          s
        end)

      nil ->
        case DevIDE.Previews.open(workspace, attrs) do
          {:ok, preview} ->
            socket
            |> finish_agent_preview_open(preview)
            |> then(fn s ->
              send(self(), :agent_preview_screenshot)
              s
            end)

          _ ->
            socket
        end
    end
  end

  defp activate_agent_preview(socket, preview) do
    socket
    |> assign(:active_preview_control_session, nil)
    |> ensure_preview_control(preview)
    |> finish_agent_preview_open(preview)
    |> then(fn s ->
      send(self(), :agent_preview_screenshot)
      s
    end)
  end

  defp finish_agent_preview_open(socket, preview) do
    workspace = socket.assigns.workspace

    socket
    |> stream_previews(workspace.id)
    |> ensure_preview_control(preview)
    |> suppress_preview_candidate_url(preview.url)
    |> assign(
      :active_preview_observation,
      socket.assigns[:active_preview_observation] || latest_preview_observation(preview)
    )
    |> assign(
      :active_preview,
      if(preview.mode == :iframe and preview.trusted, do: preview, else: nil)
    )
  end

  defp suppress_preview_candidate_url(socket, url) do
    assign(
      socket,
      :opened_preview_candidate_urls,
      put_candidate_url(socket.assigns[:opened_preview_candidate_urls], candidate_url_key(url))
    )
  end

  defp capture_agent_preview_screenshot(socket) do
    case socket.assigns[:active_preview_control_session] do
      %{id: session_id} ->
        case DevIDE.PreviewControl.screenshot(session_id) do
          {:ok, observation} -> assign(socket, :active_preview_observation, observation)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp close_stale_open_previews(socket, keep_surface) do
    workspace_id = socket.assigns.workspace.id
    previews = DevIDE.Previews.list_for_workspace(workspace_id)

    {matching, others} =
      Enum.split_with(previews, &(Map.get(&1.metadata, "surface") == keep_surface))

    extras =
      matching
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.drop(1)

    _ = close_active_preview_control(socket)

    for preview <- others ++ extras do
      _ = DevIDE.Previews.close(preview)
    end

    stream_previews(socket, workspace_id)
  end

  defp find_open_preview_for_surface(workspace_id, surface_name) do
    DevIDE.Previews.list_for_workspace(workspace_id)
    |> Enum.find(&(Map.get(&1.metadata, "surface") == surface_name))
  end

  defp find_open_preview_for_url(workspace_id, url) do
    DevIDE.Previews.list_for_workspace(workspace_id)
    |> Enum.find(&(&1.url == url))
  end

  defp dev_ide_listen_port do
    endpoint = Application.get_env(:dev_ide, DevIdeWeb.Endpoint, [])
    http = Keyword.get(endpoint, :http, [])
    Keyword.get(http, :port) || String.to_integer(System.get_env("PORT") || "4000")
  end

  defp refresh_preview_observation(socket, action) do
    case socket.assigns[:active_preview_control_session] do
      %{id: session_id} ->
        result =
          case action do
            :screenshot -> DevIDE.PreviewControl.screenshot(session_id)
            _ -> DevIDE.PreviewControl.observe(session_id)
          end

        case result do
          {:ok, observation} ->
            {:noreply, assign(socket, :active_preview_observation, observation)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Preview #{action} failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No active preview control session")}
    end
  end

  # Runs an interactive control action (click/type/press) against the active
  # session, then refreshes the observation panel. Click returns a fresh
  # observation directly; type/press echo their input, so we re-observe.
  defp run_preview_control_action(socket, label, fun) do
    case socket.assigns[:active_preview_control_session] do
      %{id: session_id} ->
        case fun.(session_id) do
          {:ok, result} ->
            {:noreply, apply_control_result(socket, session_id, result)}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Preview #{label} failed: #{control_error(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No active preview control session")}
    end
  end

  defp apply_control_result(socket, session_id, result) do
    if is_map(result) and (Map.has_key?(result, :url) or Map.has_key?(result, :dom_summary)) do
      assign(socket, :active_preview_observation, result)
    else
      observe_preview_control(socket, session_id)
    end
  end

  defp control_error(:playwright_unavailable),
    do: "browser control unavailable — install Playwright to enable click/type/press"

  defp control_error(reason), do: inspect(reason)

  defp ensure_preview_control(socket, preview) do
    if socket.assigns[:active_preview_control_session] do
      socket
    else
      case DevIDE.PreviewControl.open_for_preview(socket.assigns.workspace, preview,
             actor_id: current_actor_id(socket)
           ) do
        {:ok, control_session} ->
          socket
          |> assign(:active_preview_control_session, control_session)
          |> observe_preview_control(control_session.id)

        _ ->
          socket
      end
    end
  end

  defp observe_preview_control(socket, session_id) do
    case DevIDE.PreviewControl.observe(session_id) do
      {:ok, observation} -> assign(socket, :active_preview_observation, observation)
      _ -> socket
    end
  end

  defp close_active_preview_control(socket) do
    case socket.assigns[:active_preview_control_session] do
      %{id: id} -> DevIDE.PreviewControl.close_session(id)
      _ -> :ok
    end
  end

  defp latest_preview_observation(preview) do
    case DevIDE.PreviewControl.latest_observation_for_preview(preview.id) do
      %DevIDE.Previews.ControlObservation{} = obs -> observation_payload(obs)
      nil -> nil
    end
  end

  defp observation_payload(%DevIDE.Previews.ControlObservation{} = obs) do
    Map.merge(obs.data, %{title: obs.data["title"] || obs.data[:title]})
  end

  defp preview_observation_title(nil), do: nil

  defp preview_observation_title(observation) when is_map(observation) do
    observation[:title] || observation["title"]
  end

  defp observation_screenshot(observation) when is_map(observation) do
    cond do
      shot = observation[:screenshot] || observation["screenshot"] ->
        servable_image_src(
          is_map(shot) && (Map.get(shot, :artifact) || Map.get(shot, "artifact"))
        )

      path = observation[:artifact_path] || observation["artifact_path"] ->
        servable_image_src(path)

      true ->
        nil
    end
  end

  defp observation_screenshot(_), do: nil

  # Only values the browser can actually load belong in an <img src>. Screenshot
  # artifacts are stored as filesystem paths (Playwright) or memory:// URIs (test
  # adapter); neither is servable, so we render the panel without a broken image
  # until artifacts are exposed through a controller/route.
  defp servable_image_src(src) when is_binary(src) do
    cond do
      String.starts_with?(src, ["http://", "https://", "data:"]) -> src
      String.starts_with?(src, "/preview-artifacts/") -> src
      true -> nil
    end
  end

  defp servable_image_src(_), do: nil

  defp preview_mode("iframe"), do: :iframe
  defp preview_mode(:iframe), do: :iframe
  defp preview_mode(_), do: :tab

  defp preview_pane_id(_socket, %{"pane-id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp preview_pane_id(_socket, %{"pane_id" => pane_id}) when is_binary(pane_id), do: pane_id
  defp preview_pane_id(socket, _params), do: socket.assigns[:focused_pane_id]

  defp preview_session_id(_socket, %{"session-id" => session_id}) when is_binary(session_id),
    do: session_id

  defp preview_session_id(_socket, %{"session_id" => session_id}) when is_binary(session_id),
    do: session_id

  defp preview_session_id(socket, params) do
    pane_id = preview_pane_id(socket, params)

    focused_pane_session_sid(
      socket.assigns[:pane_data] || %{},
      pane_id,
      socket.assigns[:terminal_sid]
    )
  end

  # Replace a {:pane, id} node in the layout with a split containing the old pane + new pane
  defp split_layout(layout, target_pane_id, new_pane_id, direction),
    do: PaneLayout.split_layout(layout, target_pane_id, new_pane_id, direction)

  defp remove_pane_from_layout(layout, pane_id),
    do: PaneLayout.remove_pane_from_layout(layout, pane_id)

  defp collect_pane_ids(node), do: PaneLayout.collect_pane_ids(node)
  defp from_json_layout(raw), do: PaneLayout.from_json_layout(raw)

  defp first_pane_id(node), do: PaneLayout.first_pane_id(node)

  defp equalize_layout(node), do: PaneLayout.equalize_layout(node)

  # Update the ratios for the split node whose two adjacent direct children
  # have the given "left" and "right" first-pane ids (used by the drag resizer).
  # Clamps the ratio to keep panes usable (10%–90%).
  defp resize_split(layout, left_id, right_id, new_left_ratio),
    do: PaneLayout.resize_split(layout, left_id, right_id, new_left_ratio)

  # Centralize pane_layout + its Tidewave-friendly debug sibling so every
  # mutation site stays in sync and we never forget the observable form.
  defp put_pane_layout(socket, layout) do
    socket
    |> assign(:pane_layout, layout)
    |> assign(:debug_pane_layout, PaneLayout.to_debug(layout))
    |> assign(:pane_count, PaneLayout.count_panes(layout))
  end

  # Tiny centralizer for the Tidewave-visible persistence status string so that
  # future paths (new rejection reasons etc.) cannot accidentally forget to keep
  # the debug assign in sync with the human message.
  defp put_persistence_status(socket, status) do
    assign(socket, :debug_persistence_status, status)
  end

  # Centralizer for the refresh-pending set (MapSet of pane_ids). Kept *outside*
  # :pane_data so that the frequent true→false flips are invisible to the HEEx
  # diff engine (the set is never referenced from any template). This makes the
  # 16 ms coalescing completely free for change-tracking purposes.
  defp get_pane_refresh_pending(socket) do
    Map.get(socket.assigns, :pane_refresh_pending, MapSet.new())
  end

  defp put_pane_refresh_pending(socket, set) do
    assign(socket, :pane_refresh_pending, set)
  end

  # Called from mount (for the default-raw case) and from the explicit
  # "enter raw" transition. Starts the PTY worker(s) for the current
  # focused (or all) pane(s) and requests any saved layout ratios at a
  # point where the Ghostty hooks will have had a chance to mount.
  defp maybe_start_raw_ghostty_and_request_restore(socket, mode, ws_id)
       when mode in [:raw, :raw_ghostty] do
    s = start_ghostty_terminal(socket)

    # For the *default* raw mount path (exercised by the non-@tmux UI chrome test)
    # we intentionally swallow any "Failed to start" flash. The test profile has no
    # tmux, so PaneWorker fails, but the raw layout chrome + split buttons must still
    # render cleanly (the test asserts exactly that). Explicit user "enter raw" via
    # palette/set_mode still gets the error message from the shared start helper.
    flash = Map.get(s.assigns, :flash, %{})

    s =
      if is_map(flash) and Map.has_key?(flash, :error) and
           is_binary(flash[:error]) and
           String.contains?(flash[:error], "Failed to start Ghostty pane") do
        assign(s, :flash, Map.delete(flash, :error))
      else
        s
      end

    s
    |> push_event("request_saved_layout", %{"workspace_id" => ws_id})
  end

  defp maybe_start_raw_ghostty_and_request_restore(socket, _mode, _ws_id), do: socket

  defp cleanup_ghostty_resources_if_leaving(socket) do
    # Ghostty is now the :raw path. Clean up when leaving any Ghostty-based raw terminal.
    if socket.assigns[:terminal_mode] in [:raw, :raw_ghostty] do
      cleanup_ghostty_resources(socket)
    else
      socket
    end
  end

  defp maybe_reset_terminal_mode(
         %{assigns: %{terminal_mode: mode_name, workspace_mode: mode, host_id: host_id}} = socket
       ) do
    # :raw now means Ghostty. We still support the old :raw_ghostty token during transition.
    if mode_name in [:raw, :raw_ghostty] and raw_terminal_allowed?(mode, host_id),
      do: socket,
      else: assign(socket, :terminal_mode, :governed)
  end

  defp maybe_reset_terminal_mode(socket), do: socket

  defp decision_for_command(socket, command_id) do
    ctx = policy_ctx(socket, %{command_id: command_id})
    Policy.can_run_command?(ctx)
  end

  # Allowlist of commands that are interactive TUIs — they need a real PTY
  # in a terminal pane, not the Run tab's stdout-capture flow.
  defp interactive_agent?(id),
    do: id in ~w(agent claude clauded codex grok opencode)

  # Interactive coding-agent launchers (agent / claude / grok / opencode /
  # codex / clauded) bridge from governed → raw: rather than running as a one-shot
  # Commands.Run (which captures stdout to the Run tab — wrong shape for a
  # full-screen TUI), we ensure the canonical raw session exists, write the
  # command through that PTY, and flip the operator to the Terminal tab in raw
  # mode. The raw Ghostty pane attaches to the same session, so the operator
  # sees the agent already running when the mode change settles.
  defp launch_interactive_agent(socket, id) do
    socket = refresh_workspace_mode(socket)
    decision = Policy.can_run_command?(policy_ctx(socket, %{command_id: id}))
    _ = ledger_command_decision(decision, socket, id, Ledger.new_run_id())
    socket = assign(socket, last_decision: decision, audit_events: refreshed_audit(socket))

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
            DevIDE.Terminals.Session.send_input(session_pid, id <> "\r")

            socket =
              socket
              |> assign(:tab, "terminal")
              |> start_ghostty_terminal()
              |> audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
              |> assign(:terminal_mode, :raw)
              |> push_event("request_saved_layout", %{
                "workspace_id" => socket.assigns.workspace.id
              })
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

  defp start_batch_run(socket, id) do
    decision = Policy.can_run_command?(policy_ctx(socket, %{command_id: id}))
    run_id = Ledger.new_run_id()
    _ = ledger_command_decision(decision, socket, id, run_id)

    socket =
      assign(socket, last_decision: decision, audit_events: refreshed_audit(socket))
      |> refresh_run_ledger(run_id)

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, loc} <- host_loc(socket),
         {:ok, pid} <-
           Commands.Run.start(socket.assigns.workspace.id, loc, id,
             run_id: run_id,
             actor_id: current_actor_id(socket),
             metadata: %{source: "ui", trigger: "manual"}
           ),
         {:ok, snap} <- Commands.Run.subscribe(pid) do
      {:noreply, assign(socket, :active_run, snap)}
    else
      {:error, :already_running} ->
        {:noreply, attach_existing_run(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Run failed: #{inspect(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Run not allowed.")}
    end
  end

  defp start_ghostty_terminal(socket) do
    start_ghostty_for_pane(socket, socket.assigns.focused_pane_id)
  end

  defp add_pane(socket, pane_id, pane) when is_binary(pane_id) and is_map(pane) do
    assign(socket, :pane_data, Map.put(socket.assigns.pane_data, pane_id, pane))
  end

  defp focus_pane(socket, pane_id) do
    assign(socket, :focused_pane_id, pane_id)
  end

  defp focus_relative_pane(socket, direction) when direction in [:next, :previous] do
    layout = socket.assigns[:pane_layout]
    current_id = socket.assigns[:focused_pane_id]

    next_id =
      case direction do
        :next -> PaneLayout.next_pane_id(layout, current_id)
        :previous -> PaneLayout.previous_pane_id(layout, current_id)
      end

    case next_id do
      id when is_binary(id) -> {:noreply, focus_pane(socket, id)}
      _ -> {:noreply, socket}
    end
  end

  defp update_pane(socket, pane_id, fun) do
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
      fn ->
        pane = get_pane_data(socket, pane_id)

        result =
          cond do
            is_nil(pane) ->
              socket

            pane_worker_alive?(pane) ->
              socket

            true ->
              # cwd is required for the WorkspaceSource argv wrap (docker compose
              # exec runs from the workspace's compose project root) and for the
              # container_has_tmux? probe to key its cache.
              cwd = workspace_cwd(socket)
              backend = ghostty_pane_backend()
              session_sid = pane[:session_sid] || socket.assigns.terminal_sid
              workspace_key = terminal_workspace_key(socket)
              loc = terminal_loc(socket, cwd)

              case DevIdeWeb.WorkspaceLive.PaneWorker.start_link(
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
                     rows: 40
                   ) do
                {:ok, worker} ->
                  {term, pty} = DevIdeWeb.WorkspaceLive.PaneWorker.get_handles(worker)
                  DevIDE.Terminals.TmuxJanitor.subscribe(pane.tmux_session)

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
                  end)

                {:error, reason} ->
                  # The per-pane error state (set here and rendered in TerminalSurface)
                  # is now the primary, non-duplicative way failures are surfaced.
                  # We no longer emit a global flash for this path (it duplicated the
                  # inline inspect(error) and produced banner + box on every retry).
                  update_pane(socket, pane_id, fn p -> %{p | error: reason} end)
              end
          end

        metadata =
          case {pane, result} do
            {nil, _} -> %{status: :missing_pane}
            {%{worker: worker}, _} when is_pid(worker) -> %{status: :already_started}
            _ -> %{}
          end

        {result, metadata}
      end
    )
  end

  defp pane_worker_alive?(%{worker: worker, ghostty_term: term})
       when is_pid(worker) and is_pid(term) do
    Process.alive?(worker) and Process.alive?(term)
  end

  defp pane_worker_alive?(_), do: false

  defp maybe_schedule_raw_prewarm(socket) do
    if socket.assigns[:terminal_mode] == :governed and
         raw_terminal_allowed?(socket.assigns[:workspace_mode], socket.assigns[:host_id]) do
      Process.send_after(self(), :prewarm_raw_session, 0)
    end

    socket
  end

  defp maybe_prewarm_raw_session(socket) do
    if socket.assigns[:terminal_mode] == :governed and
         raw_terminal_allowed?(socket.assigns[:workspace_mode], socket.assigns[:host_id]) do
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
          DevIDE.Terminals.GhosttyRawAdapter.ensure_raw_shell(workspace_key, session_sid, loc)

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

  defp workspace_cwd(socket) do
    case socket.assigns[:host_path] do
      {:ok, path} -> path
      _ -> "."
    end
  end

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
          DevIDE.Terminals.TmuxJanitor.unsubscribe(pane.tmux_session)
        end

        if is_pid(pane.ghostty_term) and Process.alive?(pane.ghostty_term) do
          Process.unlink(pane.ghostty_term)
          Process.exit(pane.ghostty_term, :shutdown)
        end

        {id, %{pane | ghostty_pty: nil, ghostty_term: nil, worker: nil, backend: nil, error: nil}}
      end)

    socket
    |> assign(:pane_data, cleared)
    |> assign(:pane_refresh_pending, MapSet.new())
    |> assign(:pane_pty_buffer, %{})
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

  # Default to the known-good legacy backend until the SessionOwner path is
  # debugged on devbox — its child PTY exits with status 1 immediately,
  # leaving panes showing "Terminal exited {:exit_status, 256}" + a Retry
  # button. Operators can flip to :session_owner via
  #   config :dev_ide, :ghostty_pane_backend, :session_owner
  # once that's traced.
  defp ghostty_pane_backend do
    Application.get_env(:dev_ide, :ghostty_pane_backend, :ghostty_pty)
  end

  defp terminal_workspace_key(socket) do
    workspace = socket.assigns.workspace
    workspace.name || workspace.id
  end

  defp terminal_loc(socket, cwd) do
    case socket.assigns[:host_loc] do
      {:ok, loc} -> loc
      _ -> {:local, cwd}
    end
  end
end
