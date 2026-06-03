defmodule DevIdeWeb.WorkspaceLive.Show do
  use DevIdeWeb, :live_view

  alias DevIDE.Workspaces
  alias DevIDE.Terminals.Tmux
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
  alias DevIdeWeb.Plugs.{AssignCurrentUser, ForwardAuth}
  alias DevIdeWeb.ChannelAuth
  alias DevIdeWeb.TerminalSurface
  alias DevIdeWeb.TerminalSurface.Pane, as: TerminalSurfacePane
  alias DevIdeWeb.WorkspaceLive.PaneLayout

  @ghostty_term_id "raw-term-ghostty"

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
    with :ok <- ensure_local_host(host_id),
         {:ok, ws} <- Workspaces.get(id, user[:email]),
         :ok <- authorize_owner(ws, user) do
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
      workspace_mode = Workspaces.State.mode_for(id) |> elem(0)
      terminal_mode = initial_terminal_mode(workspace_mode, host_id)
      # NOTE: in-flight refactor adds ChannelAuth.sign_terminal_capability/3
      # Re-attach token for governed/raw channel joins after a fresh LiveView
      # auth pass. This is safe to send as a socket dataset attribute and lets
      # TerminalChannel skip workspace manager and owner-policy checks on
      # reconnect storms.
      workspace_capability =
        ChannelAuth.sign_terminal_capability(
          user.id,
          ws.id || ws[:id] || id,
          workspace_name: ws.name,
          workspace_user: ws.user,
          workspace_path: ws.path,
          workspace_loc: loc_result,
          workspace_host_id: host_id,
          raw_terminal_ok: raw_terminal_allowed?(workspace_mode, host_id),
          owner_ok: true,
          terminal_owner_ok: true,
          terminal_sid: sid
        )

      socket_token = ChannelAuth.sign_user_token(user.id, user[:email])

      socket =
        socket
        |> assign(:page_title, ws.name)
        |> assign(:current_user, user)
        |> assign(:workspace, ws)
        |> assign(:host_id, host_id)
        |> assign(:host_path, path_result)
        |> assign(:host_loc, loc_result)
        |> assign(:tmux_session, tmux_session)
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
        |> assign(:focused_pane_id, "pane-1")
        |> assign(:zoomed_pane_id, nil)
        |> assign(:debug_persistence_status, "idle")
        |> assign(:terminal_workspace_capability, workspace_capability)
        # PaneWorker startup (Ghostty.Terminal + Ghostty.PTY + `tmux new-session`)
        # is ~50-200ms — deferring it to :after_mount lets the empty pane
        # chrome render first and the prompt arrive a frame later.
        |> assign(:socket_token, socket_token)
        |> assign(:active_sessions, Terminals.list_attachable(id))
        |> assign(:tab, "terminal")
        |> assign(:log_service, DevIDE.WorkspaceSource.default_log_service(ws))
        |> assign(:log_lines, [])
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
        |> assign(:agent_transcripts, [])
        |> assign(:agent_review_cmds, [])
        |> assign(:agent_run, nil)
        |> assign(:agent_run_error, nil)
        |> assign(:proposals, [])
        |> assign(:selected_proposal, nil)
        |> assign(:proposal_analysis, nil)
        |> assign_workspace_mode(ws.id)
        |> assign(:last_decision, nil)
        |> assign(:audit_events, [])
        |> assign(:audit_drawer_open, false)
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

      # Defer FS walks, git, DB queries and agent loading out of the initial
      # mount so the first HTML render (time-to-first-paint) is as fast as
      # possible. The handle_info fires immediately after, causing a follow-up
      # diff with the populated side panels / state.
      send(self(), :after_mount)

      {:ok, socket}
    else
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
         |> put_flash(:error, "That workspace belongs to another user.")
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

  # Workspace ownership gate. Only enforced under forward-auth (a shared
  # multi-user deployment); in local single-user dev every workspace is the
  # one user's, so the static identity wouldn't match the manager's real
  # usernames and we skip the check.
  defp authorize_owner(ws, user) do
    if not ForwardAuth.enabled?() or Workspaces.owns?(ws, user[:username]),
      do: :ok,
      else: {:error, :forbidden}
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

  def handle_event("terminal:set_mode", %{"mode" => "governed"}, socket) do
    socket =
      socket
      |> cleanup_ghostty_resources_if_leaving()
      |> audit_terminal_mode_transition(socket.assigns[:terminal_mode], :governed)

    {:noreply, assign(socket, :terminal_mode, :governed)}
  end

  # All-in on Ghostty: "raw" now starts the Ghostty component.
  # The old xterm.js raw path is deprecated for raw terminals.
  def handle_event("terminal:set_mode", %{"mode" => "raw"}, socket) do
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
     |> assign(:active_sessions, Terminals.list_attachable(socket.assigns.workspace.id))}
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
     |> assign(:active_sessions, Terminals.list_attachable(socket.assigns.workspace.id))}
  end

  def handle_event("terminal:refresh_sessions", _params, socket) do
    {:noreply,
     assign(socket, :active_sessions, Terminals.list_attachable(socket.assigns.workspace.id))}
  end

  def handle_event("agents:refresh", _, socket), do: {:noreply, load_agents(socket)}

  def handle_event("isolation:refresh", _, socket),
    do: {:noreply, refresh_isolation(socket, audit: true)}

  def handle_event("workspace:set_mode", %{"mode" => mode_str}, socket) do
    mode = string_to_mode(mode_str)
    ws_id = socket.assigns.workspace.id

    cond do
      not can_set_mode?(socket.assigns.workspace_mode_source) ->
        {:noreply,
         put_flash(socket, :error, "Mode is set via config override and cannot be changed in UI.")}

      mode == nil ->
        {:noreply, socket}

      true ->
        {_, _} = DevIDE.Workspaces.State.set_mode(ws_id, mode)

        DevIDE.Audit.emit!(%{
          action: "workspace.mode_changed",
          workspace_id: ws_id,
          actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
          target_type: "workspace",
          target_ref: ws_id,
          metadata: %{"mode" => Atom.to_string(mode)}
        })

        {:noreply,
         socket
         |> assign_workspace_mode(ws_id)
         |> maybe_reset_terminal_mode()
         |> assign(:audit_events, refreshed_audit(socket))}
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
             |> assign(:audit_events, refreshed_audit(socket))}

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
      |> then(fn s -> if open?, do: assign(s, :audit_events, refreshed_audit(s)), else: s end)

    {:noreply, socket}
  end

  def handle_event("audit_drawer:close", _, socket),
    do: {:noreply, assign(socket, :audit_drawer_open, false)}

  def handle_event("audit_drawer:refresh", _, socket),
    do: {:noreply, assign(socket, :audit_events, refreshed_audit(socket))}

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

  def handle_event("run:cancel", _, socket) do
    case Commands.Run.whereis(socket.assigns.workspace.id) do
      {:ok, pid} -> Commands.Run.cancel(pid)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("set_log_service", %{"service" => service}, socket) do
    socket = socket |> assign(:log_service, service) |> assign(:log_lines, [])
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
    lines = [line | socket.assigns.log_lines] |> Enum.take(@max_log_lines)
    {:noreply, assign(socket, :log_lines, lines)}
  end

  def handle_info(:clear_equalize_flash, socket) do
    {:noreply, assign(socket, :equalize_flash, nil)}
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
        # Force the window to the fitted size explicitly.
        _ = DevIDE.Terminals.Tmux.resize_window(tmux_session, cols, rows)
        # Apply dev_ide's standard tmux options (mouse, escape-time,
        # history-limit, focus-events, passthrough, clipboard, truecolor,
        # renumber-windows). Idempotent — safe per ready.
        _ = DevIDE.Terminals.Tmux.apply_defaults(tmux_session)
        {:noreply, update_pane(socket, pane_id, fn p -> %{p | cols: cols, rows: rows} end)}

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
        socket = push_osc52_clipboard(socket, data)

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
    {:noreply,
     socket
     # Ghostty/PTY first — the user is staring at the empty terminal frame
     # and this is the most visible follow-up paint.
     |> maybe_start_raw_ghostty_and_request_restore(
       socket.assigns.terminal_mode,
       socket.assigns.workspace.id
     )
     |> load_tree("")
     |> refresh_git_status()
     |> attach_existing_run()
     |> refresh_run_ledger()
     |> load_agents()
     # audit + side-panel population intentionally after first paint (see #3 perf work)
     |> refresh_isolation(audit: true)
     |> load_project_meta()}
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

  defp assign_workspace_mode(socket, ws_id) do
    {mode, source} = DevIDE.Workspaces.State.mode_for(ws_id)

    socket
    |> assign(:workspace_mode, mode)
    |> assign(:workspace_mode_source, source)
    |> assign(:workspace_record, load_record(ws_id))
  end

  defp load_record(ws_id) do
    case DevIDE.Workspaces.State.get(ws_id) do
      {:ok, r} -> r
      _ -> nil
    end
  end

  defp policy_ctx(socket, extra \\ %{}) do
    base = %{
      workspace_id: socket.assigns.workspace.id,
      actor_id: (socket.assigns[:current_user] || %{}) |> Map.get(:id),
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
    |> assign(:audit_events, refreshed_audit(socket))
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

    {decision, assign(socket, last_decision: decision, audit_events: refreshed_audit(socket))}
    |> tap(fn _ -> _ = event end)
  end

  defp refreshed_audit(socket) do
    Audit.recent_for(socket.assigns.workspace.id, 50)
  end

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
        |> assign(:agent_transcripts, Agents.transcripts(root))
        |> assign(:agent_review_cmds, Agents.review_commands(caps))
        |> assign(:proposals, Proposals.discover(root))
        |> attach_existing_agent_run()

      _ ->
        socket
        |> assign(:agent_caps, [])
        |> assign(:agent_transcripts, [])
        |> assign(:agent_review_cmds, [])
        |> assign(:proposals, [])
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
    drop = byte_size(b) - @run_buffer_cap
    <<_::binary-size(drop), tail::binary>> = b
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
              <%= if (denies = deny_count(@audit_events)) > 0 do %>
                <span class="ml-1 text-[10px] font-mono text-error align-middle">
                  ● {denies}
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
  defp render_audit_drawer(assigns) do
    ~H"""
    <div
      :if={@audit_drawer_open}
      class="fixed inset-0 z-40 pointer-events-none"
      aria-hidden={if @audit_drawer_open, do: "false", else: "true"}
    >
      <div
        class="absolute inset-0 bg-black/20 pointer-events-auto"
        phx-click="audit_drawer:close"
      >
      </div>
      <aside
        class="absolute right-0 top-0 bottom-0 w-[380px] bg-white border-l shadow-xl pointer-events-auto flex flex-col"
        role="complementary"
        aria-label="Evidence drawer"
      >
        <header class="flex items-center justify-between px-4 py-3 border-b">
          <div>
            <h2 class="text-sm font-semibold tracking-tight">Evidence</h2>
            <p class="text-[11px] text-zinc-500 font-mono">
              {length(@audit_events)} events · {ledger_event_count(@audit_events)} ledger · workspace {@workspace.name}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <button
              phx-click="audit_drawer:refresh"
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
              title="refresh audit"
            >
              ↻
            </button>
            <button
              phx-click="audit_drawer:close"
              class="text-[11px] border rounded px-2 py-0.5 hover:bg-zinc-50"
              title="close (esc)"
            >
              ×
            </button>
          </div>
        </header>
        <div class="flex-1 overflow-auto px-3 py-2 font-mono text-[11px] leading-relaxed">
          <%= if @audit_events == [] do %>
            <p class="text-zinc-400 italic">no events recorded yet</p>
          <% else %>
            <ol class="space-y-1.5">
              <%= for e <- @audit_events do %>
                <li class="flex gap-2 items-baseline">
                  <span class={"inline-block w-1.5 h-1.5 rounded-full mt-1.5 shrink-0 " <> audit_dot_class(e)}>
                  </span>
                  <span class="text-zinc-400 shrink-0">
                    {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                  </span>
                  <span class={"shrink-0 font-medium " <> audit_verb_class(e)}>
                    {audit_verb(e)}
                  </span>
                  <span class="text-zinc-700 break-all">
                    {audit_detail(e)}
                  </span>
                  <%= if run_id = audit_run_id(e) do %>
                    <button
                      id={"audit-open-run-#{dom_fragment(run_id)}-#{dom_fragment(e.id)}"}
                      phx-click="run_ledger:open"
                      phx-value-id={run_id}
                      class="ml-auto shrink-0 rounded border px-1 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50"
                      title="open run timeline"
                    >
                      run
                    </button>
                  <% end %>
                </li>
              <% end %>
            </ol>
          <% end %>
        </div>
        <footer class="px-3 py-2 border-t text-[10px] text-zinc-500 font-mono">
          newest first · capped at 50 · time-ordered stream (product.md §9.4)
        </footer>
      </aside>
    </div>
    """
  end

  defp deny_count(events) when is_list(events),
    do: Enum.count(events, fn e -> e.decision == :deny end)

  defp deny_count(_), do: 0

  defp ledger_event_count(events) when is_list(events),
    do: Enum.count(events, &Ledger.ledger_event?/1)

  defp ledger_event_count(_), do: 0

  defp audit_dot_class(%{decision: :deny}), do: "bg-red-600"
  defp audit_dot_class(%{decision: :allow}), do: "bg-green-600"
  defp audit_dot_class(%{action: "workspace.mode_set"}), do: "bg-amber-500"
  defp audit_dot_class(_), do: "bg-zinc-400"

  defp audit_verb_class(%{decision: :deny}), do: "text-red-700"
  defp audit_verb_class(%{decision: :allow}), do: "text-green-700"
  defp audit_verb_class(%{action: "workspace.mode_set"}), do: "text-amber-700"
  defp audit_verb_class(_), do: "text-zinc-600"

  defp audit_verb(%{decision: :deny}), do: "deny"
  defp audit_verb(%{decision: :allow}), do: "allow"
  defp audit_verb(%{action: "workspace.mode_set"}), do: "mode"
  defp audit_verb(%{action: action}), do: action |> String.split(".") |> List.last()

  defp audit_detail(%{action: action, target_ref: ref, reason: reason}) do
    base = action

    base =
      cond do
        ref && ref != "" -> "#{base} · #{ref}"
        true -> base
      end

    cond do
      reason -> "#{base} · #{Atom.to_string(reason)}"
      true -> base
    end
  end

  defp ledger_event_noun(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "noun") || "event"
  end

  defp ledger_event_noun(_), do: "event"

  defp audit_run_id(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "run_id") || Map.get(metadata, :run_id)
  end

  defp audit_run_id(_), do: nil

  defp artifact_events(artifact) do
    artifact
    |> Map.get(:report_events, [])
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp artifact_report_refs(artifact) do
    artifact
    |> Map.get(:report_ids, [])
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      value -> value
    end
  end

  defp dom_fragment(value) when is_binary(value),
    do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "-")

  defp dom_fragment(value), do: value |> to_string() |> dom_fragment()

  defp render_terminal(assigns) do
    ~H"""
    <section class="-mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
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

              <%= if has_active_executions?(assigns[:active_sessions]) do %>
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
                  <%= for s <- @active_sessions, s.kind == :execution do %>
                    <button
                      type="button"
                      phx-click="attach_terminal_session"
                      phx-value-session-id={s.id}
                      phx-value-kind="execution"
                      phx-value-tmux-session={s.tmux_session}
                      class={terminal_tab_class(@terminal_sid == s.id)}
                      title={"Fleet execution " <> (s.execution_id || "")}
                    >
                      Exec <span class="ml-1 font-mono text-primary">{shorten(s.tmux_session)}</span>
                    </button>
                  <% end %>
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
                <span class="text-base-content/70">{DevIDE.Workspaces.FileAccess.label(loc)}</span>
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
          <% end %>

          <%= cond do %>
            <% @terminal_mode in [:raw, :raw_ghostty] -> %>
              <TerminalSurface.pane_layout
                layout={surface_layout(@pane_layout, @zoomed_pane_id, @pane_data)}
                panes={terminal_surface_panes(@pane_data)}
                focused_pane_id={@focused_pane_id}
                pane_count={@pane_count}
                zoomed_pane_id={@zoomed_pane_id}
                host_id={@host_id}
                equalize_flash={@equalize_flash}
              />
            <% true -> %>
              <div
                id={"terminal-" <> @workspace.id <> "-" <> @terminal_sid <> "-governed"}
                phx-hook="GhosttyGovernedTerminal"
                phx-update="ignore"
                data-workspace-id={@workspace.id}
                data-sid={@terminal_sid}
                data-host-id={@host_id}
                data-socket-token={@socket_token}
                data-terminal-capability={@terminal_workspace_capability}
                class="min-h-0 flex-1"
              >
              </div>
          <% end %>
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
    <section class="flex h-full min-h-0 flex-col gap-2 overflow-auto pr-1">
      <%= case @host_loc do %>
        <% {:ok, _} -> %>
          <div class="flex gap-2 items-center text-sm">
            <%= for {id, argv} <- Enum.sort(Commands.allowlist()) do %>
              <button
                phx-click="run:start"
                phx-value-id={id}
                disabled={@active_run && @active_run.status == :running}
                class="rounded border px-3 py-1 disabled:opacity-50"
              >
                {run_button_label(id, argv)}
              </button>
            <% end %>
            <%= if @active_run && @active_run.status == :running do %>
              <button phx-click="run:cancel" class="ml-2 rounded border px-3 py-1 text-red-700">
                cancel
              </button>
            <% end %>
          </div>
          <%= if @active_run do %>
            <div class="text-xs text-zinc-500 font-mono flex gap-3">
              <span>{Enum.join(@active_run.argv, " ")}</span>
              <span class={run_status_class(@active_run.status)}>{@active_run.status}</span>
              <%= if @active_run.exit_code != nil do %>
                <span>exit={inspect(@active_run.exit_code)}</span>
              <% end %>
              <%= if @active_run.started_at do %>
                <span>started {DateTime.to_string(@active_run.started_at)}</span>
              <% end %>
              <%= if @active_run.finished_at do %>
                <span>finished {DateTime.to_string(@active_run.finished_at)}</span>
              <% end %>
            </div>
            <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded overflow-auto whitespace-pre-wrap h-[40dvh] min-h-[12rem]">{@active_run.buffer}</pre>
          <% else %>
            <p class="text-xs text-zinc-500">No runs yet.</p>
          <% end %>

          <div
            id="run-ledger"
            class="border-t pt-3 mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]"
          >
            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Run ledger</h3>
                <span class="text-[10px] font-mono text-zinc-400">
                  {length(@run_ledger)} runs
                </span>
              </div>
              <%= if @run_ledger == [] do %>
                <p id="run-ledger-empty" class="text-xs text-zinc-500">
                  No governed runs recorded.
                </p>
              <% else %>
                <ol class="space-y-1">
                  <%= for r <- @run_ledger do %>
                    <li>
                      <button
                        id={"run-ledger-run-#{dom_fragment(r.id)}"}
                        phx-click="run_ledger:select"
                        phx-value-id={r.id}
                        class={[
                          "w-full rounded border px-2 py-1.5 text-left text-xs transition hover:bg-zinc-50",
                          @selected_run_id == r.id && "border-zinc-900 bg-zinc-50"
                        ]}
                      >
                        <div class="flex items-center gap-2">
                          <span class="font-mono">
                            {Map.get(r, :command_id) || Map.get(r, :safe_action_id) || r.id}
                          </span>
                          <span class={run_status_class(Status.status_class(Map.get(r, :status)))}>
                            {Map.get(r, :status, "unknown")}
                          </span>
                        </div>
                        <div class="mt-1 flex flex-wrap gap-2 font-mono text-[10px] text-zinc-500">
                          <span>{Map.get(r, :protocol, "ledger")}</span>
                          <%= if Map.get(r, :assignment_id) do %>
                            <span>assignment={Map.get(r, :assignment_id)}</span>
                          <% end %>
                          <%= if Map.get(r, :finished_at) do %>
                            <span>{Map.get(r, :finished_at)}</span>
                          <% end %>
                        </div>
                      </button>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </section>

            <section>
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xs font-medium text-zinc-700">Timeline</h3>
                <%= if @selected_run_id do %>
                  <span class="text-[10px] font-mono text-zinc-400">
                    {@selected_run_id}
                  </span>
                <% end %>
              </div>
              <%= if @selected_run_timeline == [] do %>
                <p id="run-ledger-timeline-empty" class="text-xs text-zinc-500">
                  Select a run to inspect its canonical events.
                </p>
              <% else %>
                <%= if @selected_run_summary do %>
                  <dl
                    id="run-ledger-summary"
                    class="mb-2 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 rounded border bg-zinc-50 px-2 py-1.5 text-[10px]"
                  >
                    <dt class="text-zinc-500">status</dt>
                    <dd class="font-mono">{Map.get(@selected_run_summary, :status, "unknown")}</dd>
                    <dt class="text-zinc-500">command</dt>
                    <dd class="font-mono">
                      {Map.get(@selected_run_summary, :command_id) ||
                        Map.get(@selected_run_summary, :safe_action_id) || "unknown"}
                    </dd>
                    <%= if Map.get(@selected_run_summary, :assignment_id) do %>
                      <dt class="text-zinc-500">assignment</dt>
                      <dd class="font-mono">{Map.get(@selected_run_summary, :assignment_id)}</dd>
                    <% end %>
                  </dl>
                  <%= if Status.failed?(@selected_run_summary.status) do %>
                    <div
                      id="run-failure-surface"
                      class="rounded border bg-red-50 px-2 py-1.5 text-xs space-y-1 mb-2"
                    >
                      <div class="flex items-center gap-2">
                        <span class="text-red-700 font-medium">Failed</span>
                        <%= if @selected_run_failure_reason do %>
                          <span class="font-mono text-zinc-600">{@selected_run_failure_reason}</span>
                        <% end %>
                      </div>
                      <%= if @selected_run_can_retry do %>
                        <button
                          id="run-retry-btn"
                          phx-click="run:start"
                          phx-value-id={@selected_run_summary.command_id}
                          class="rounded border px-2 py-0.5 bg-white hover:bg-zinc-50"
                        >
                          Retry
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
                <ol id="run-ledger-timeline" class="space-y-1.5">
                  <%= for e <- @selected_run_timeline do %>
                    <li
                      id={"run-ledger-event-#{dom_fragment(e.id)}"}
                      class="rounded border px-2 py-1.5 text-xs"
                    >
                      <div class="flex flex-wrap items-baseline gap-2">
                        <span class={"inline-block w-1.5 h-1.5 rounded-full " <> audit_dot_class(e)}>
                        </span>
                        <span class="font-mono text-zinc-400">
                          {Calendar.strftime(e.inserted_at, "%H:%M:%S")}
                        </span>
                        <span class={"font-medium " <> audit_verb_class(e)}>
                          {e.action}
                        </span>
                        <span class="font-mono text-[10px] text-zinc-500">
                          {ledger_event_noun(e)}
                        </span>
                      </div>
                      <p class="mt-1 font-mono text-[10px] text-zinc-600 break-all">
                        {audit_detail(e)}
                      </p>
                    </li>
                  <% end %>
                </ol>
                <div id="run-ledger-artifacts" class="mt-3 space-y-2">
                  <h3 class="text-xs font-medium text-zinc-700">Artifacts</h3>
                  <%= if @selected_run_artifacts == [] do %>
                    <p class="text-xs text-zinc-500">No artifacts recorded for this run.</p>
                  <% else %>
                    <%= for artifact <- @selected_run_artifacts do %>
                      {render_run_artifact(assigns, artifact)}
                    <% end %>
                  <% end %>
                </div>
              <% end %>
            </section>
          </div>
        <% _ -> %>
          <p class="text-sm text-red-700">Cannot run commands: workspace path unavailable.</p>
      <% end %>
    </section>
    """
  end

  defp render_run_artifact(assigns, artifact) do
    assigns = assign(assigns, :artifact, artifact)

    case Map.get(artifact, :type) do
      "command_output" ->
        ~H"""
        <section id="run-artifact-command-output" class="rounded border text-xs">
          <header class="flex flex-wrap items-center gap-2 border-b px-2 py-1 font-mono text-[10px] text-zinc-500">
            <span>command output</span>
            <span>{Map.get(@artifact, :command_id)}</span>
            <span>{Map.get(@artifact, :status)}</span>
            <%= if Map.get(@artifact, :exit_code) do %>
              <span>exit={Map.get(@artifact, :exit_code)}</span>
            <% end %>
            <%= if Map.get(@artifact, :output_truncated) do %>
              <span class="text-amber-700">truncated</span>
            <% end %>
          </header>
          <pre class="max-h-72 overflow-auto whitespace-pre-wrap bg-zinc-950 p-2 text-[11px] text-zinc-100">{Map.get(@artifact, :output, "")}</pre>
        </section>
        """

      "runner_assignment" ->
        ~H"""
        <section id="run-artifact-runner-assignment" class="rounded border px-2 py-1.5 text-xs">
          <div class="flex flex-wrap items-center gap-2 font-mono text-[10px] text-zinc-600">
            <span>runner assignment</span>
            <span>{Map.get(@artifact, :assignment_id)}</span>
            <span>{Map.get(@artifact, :status)}</span>
            <%= if Map.get(@artifact, :safe_action_id) do %>
              <span>{Map.get(@artifact, :safe_action_id)}</span>
            <% end %>
          </div>
          <dl class="mt-1 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 text-[10px]">
            <dt class="text-zinc-500">reports</dt>
            <dd class="font-mono">{Map.get(@artifact, :reports_count, 0)}</dd>
            <dt class="text-zinc-500">events</dt>
            <dd class="font-mono">{artifact_events(@artifact)}</dd>
            <dt class="text-zinc-500">refs</dt>
            <dd class="font-mono break-all">{artifact_report_refs(@artifact)}</dd>
            <%= if Map.get(@artifact, :failure_reason) do %>
              <dt class="text-zinc-500">failure</dt>
              <dd class="font-mono text-red-700">{Map.get(@artifact, :failure_reason)}</dd>
            <% end %>
            <%= if Map.get(@artifact, :failure_class) do %>
              <dt class="text-zinc-500">class</dt>
              <dd class="font-mono">{Map.get(@artifact, :failure_class)}</dd>
            <% end %>
          </dl>
        </section>
        """

      _ ->
        ~H"""
        <section class="rounded border px-2 py-1.5 text-xs text-zinc-500">
          Unknown artifact.
        </section>
        """
    end
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

    (static_items ++ pane_palette_items(socket, q, category))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(50)
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

  defp resolve_palette_item(_socket, root, id), do: Palette.resolve(root, id)

  # Ordered category tabs shown in the palette. `:all` is always first so the
  # user can broaden out of any screen-derived default.
  @palette_categories [:all, :files, :commands, :tmux, :actions]

  @doc false
  def palette_categories, do: @palette_categories

  @doc false
  def palette_category_label(:all), do: "all"
  def palette_category_label(:files), do: "files"
  def palette_category_label(:commands), do: "commands"
  def palette_category_label(:tmux), do: "tmux"
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

  defp run_status_class(status) do
    case Status.status_class(status) do
      :running -> "text-amber-700"
      :succeeded -> "text-green-700"
      :failed -> "text-red-700"
      :timed_out -> "text-purple-700"
      _ -> "text-zinc-500"
    end
  end

  # Render button text per allowlist entry. Earlier the template hardcoded
  # "mix {id}", which made non-mix entries (claude, grok, opencode, codex)
  # show up as "mix grok" etc. Use the actual argv head so mix subcommands
  # show "mix test" but plain executables show just "grok".
  defp run_button_label(id, ["mix" | _]), do: "mix " <> id
  defp run_button_label(id, _argv), do: id

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
        <%= if @agent_transcripts == [] do %>
          <p class="text-xs text-zinc-500">No transcripts found.</p>
        <% else %>
          <ul class="text-xs space-y-1">
            <%= for a <- @agent_transcripts do %>
              <li class="font-mono flex justify-between">
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
        <% end %>
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
      <%= if @proposals == [] do %>
        <p class="text-xs text-zinc-500">No proposals discovered.</p>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-[260px_1fr] gap-3">
          <ul class="text-xs space-y-1 max-h-72 overflow-auto">
            <%= for p <- @proposals do %>
              <li>
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
      <%= if @audit_events != [] do %>
        <p class="text-[11px] text-zinc-500 mt-2">
          {length(@audit_events)} audit events ·
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
  defp cap_label(:fff), do: "FFF MCP"
  defp cap_label(:browser_artifacts), do: "Browser artifacts"
  defp cap_label(:transcripts), do: "Transcripts"
  defp cap_label(other), do: to_string(other)

  defp cap_status_class(:detected), do: "text-green-700 text-xs"
  defp cap_status_class(:missing), do: "text-zinc-400 text-xs"

  defp render_logs(assigns) do
    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-2">
      <.form
        for={%{}}
        phx-change="set_log_service"
        class="flex flex-wrap gap-2 items-center flex-none"
      >
        <label class="text-sm">Service</label>
        <input name="service" value={@log_service} class="border rounded px-2 py-1 text-sm font-mono" />
      </.form>
      <%= if is_nil(@log_ref) do %>
        <p class="text-xs text-amber-700">
          <%= if DevIDE.WorkspaceSource.impl() == DevIDE.WorkspaceSource.Local do %>
            Log streaming is not available for local filesystem workspaces.
          <% else %>
            Log stream unavailable (source unreachable or service not started).
          <% end %>
        </p>
      <% end %>
      <pre class="bg-zinc-950 text-zinc-100 text-xs p-3 rounded overflow-auto flex-1 min-h-[12rem]"><%=
        @log_lines |> Enum.reverse() |> Enum.join("\n")
      %></pre>
    </section>
    """
  end

  defp render_path({:ok, {:remote, host, path}}, _), do: "#{host}:#{path}"
  defp render_path({:ok, {:local, path}}, _), do: path
  defp render_path(_, {:ok, cwd}), do: cwd
  defp render_path(_, {:error, :missing_path}), do: "(no host path)"
  defp render_path(_, {:error, :outside_root}), do: "(path outside allowed roots)"
  defp render_path(_, _), do: "(no host path)"

  # Hide the Shell / Exec / refresh chip group when there is nothing to
  # switch between. For typical workspaces (no attached fleet executions)
  # the strip is dead chrome.
  defp has_active_executions?(nil), do: false
  defp has_active_executions?([]), do: false

  defp has_active_executions?(sessions) when is_list(sessions),
    do: Enum.any?(sessions, &(&1.kind == :execution))

  defp has_active_executions?(_), do: false

  # All chrome pills use daisyUI theme tokens (`base-*`, `primary-*`) so
  # they flip automatically with the user's `data-theme` setting (which
  # also honours the OS `prefers-color-scheme` via daisyUI's
  # `prefersdark: true`, set in assets/css/app.css).
  defp tab_class(current, current),
    do: "px-2.5 py-1 rounded bg-primary text-primary-content text-sm font-medium"

  defp tab_class(_, _),
    do:
      "px-2.5 py-1 rounded text-sm text-base-content/70 hover:text-base-content hover:bg-base-200"

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

  defp audit_terminal_mode_transition(socket, _from, _to), do: socket

  defp raw_terminal_allowed?(:manual, host_id), do: host_id in ["local", "localhost"]

  defp raw_terminal_allowed?(_mode, host_id) do
    # Dev override: in `config :dev_ide, :allow_local_raw_terminal, true`,
    # local hosts can open the raw shell even when the workspace is not in
    # :manual mode. Off by default so the production boundary (and
    # `TerminalBoundaryLiveTest`) stays tight.
    host_id in ["local", "localhost"] and
      Application.get_env(:dev_ide, :allow_local_raw_terminal, false)
  end

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
         error: Map.get(pane, :error)
       }}
    end)
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
    do: id in ~w(claude clauded codex grok opencode)

  # Interactive coding-agent launchers (claude / grok / opencode / codex /
  # clauded) bridge from governed → raw: rather than running as a one-shot
  # Commands.Run (which captures stdout to the Run tab — wrong shape for a
  # full-screen TUI), we send the command into the focused pane's tmux
  # session via `tmux send-keys` and flip the operator to the Terminal tab
  # in raw mode. The tmux session is the same one the raw Ghostty pane
  # attaches to, so the operator sees the agent already running when the
  # mode change settles.
  defp launch_interactive_agent(socket, id) do
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
        case DevIDE.Terminals.Tmux.send_command(tmux_session, id) do
          :ok ->
            {:noreply,
             socket
             |> assign(:tab, "terminal")
             |> assign(:terminal_mode, :raw)
             |> put_flash(:info, "Launched #{id} in terminal pane.")}

          other ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not send #{id} to terminal: #{inspect(other)}. " <>
                 "Try opening the Terminal tab first to start the session."
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

        # cwd is required for the WorkspaceSource argv wrap (docker compose
        # exec runs from the workspace's compose project root) and for the
        # container_has_tmux? probe to key its cache.
        cwd =
          case socket.assigns[:host_path] do
            {:ok, path} -> path
            _ -> "."
          end

        backend = ghostty_pane_backend()
        session_sid = pane[:session_sid] || socket.assigns.terminal_sid
        workspace_key = terminal_workspace_key(socket)
        loc = terminal_loc(socket, cwd)

        result =
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

        {result, %{}}
      end
    )
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
