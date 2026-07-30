defmodule CaseinWeb.WorkspaceLive.Show.TerminalEvents do
  # Terminal/tmux handle_event clauses extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates the "tmux:*", "terminal:*" and "attach_terminal_session"
  # events listed here; template and paste events stay in Show and match
  # before the delegators. No catch-all on purpose: unknown tmux:/terminal:
  # events crash exactly as they did before the extraction.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Terminals
  alias Casein.Attention.Policy, as: AttentionPolicy
  alias Casein.Workspaces.Scratch
  alias CaseinWeb.WorkspaceLive.PaneHistoryWorker
  alias CaseinWeb.WorkspaceLive.Show
  alias Casein.Previews
  alias CaseinWeb.WorkspaceLive.Show.FilePaneEvents
  alias CaseinWeb.WorkspaceLive.Show.PreviewPaneEvents
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome
  alias CaseinWeb.WorkspaceLive.Show.TerminalState
  alias CaseinWeb.WorkspaceLive.Show.ViewDeepLink
  alias CaseinWeb.WorkspaceLive.Show.Sidebar
  alias CaseinWeb.WorkspaceLive.Show.WindowTerminalMode
  alias CaseinWeb.WorkspaceRoutes

  def handle_event("terminal:user_interaction", _params, socket) do
    {:noreply, ViewDeepLink.touch_terminal_interaction(socket)}
  end

  def handle_event("terminal:attention_surface", %{"state" => state}, socket) do
    {:noreply, assign(socket, :attention_surface_state, AttentionPolicy.surface_state(state))}
  end

  def handle_event("tmux:refresh_windows", _params, socket) do
    {:noreply, TerminalState.refresh_tmux_topology(socket)}
  end

  def handle_event("terminal:scheme", %{"scheme" => scheme}, socket) do
    scheme = if scheme == "light", do: :light, else: :dark

    for {_pane_id, pane} <- socket.assigns.pane_data || %{},
        worker when is_pid(worker) <- [pane[:worker]] do
      send(worker, {:terminal_scheme, scheme})
    end

    {:noreply, assign(socket, :terminal_color_scheme, scheme)}
  end

  def handle_event("terminal:set_preset", %{"preset" => preset} = params, socket) do
    preview? = params["preview"] in [true, "true"]

    case apply_terminal_preset(socket, preset, preview?: preview?) do
      {:ok, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  # choose-tree style preview for the picker dropdowns: the SessionPicker hook
  # requests the focused entry's pane content and renders the reply client-side
  # (assigns-free on purpose — a re-render would patch the open dropdown).
  # Sessions are validated against the workspace tmux prefix so a viewer
  # cannot capture panes of another workspace's sessions.
  def handle_event("terminal:picker_preview", params, socket) do
    session =
      case Map.get(params, "tmux-session") do
        s when is_binary(s) and s != "" -> s
        _ -> socket.assigns.tmux_session
      end

    target =
      case Map.get(params, "window-id") do
        w when is_binary(w) and w != "" -> "#{session}:#{w}"
        _ -> session
      end

    ws = socket.assigns.workspace
    prefix = Terminals.tmux_workspace_session_prefix(ws.name || ws.id)
    adapter = TerminalState.tmux_adapter()

    text =
      if is_binary(session) and String.starts_with?(session, prefix) and
           Code.ensure_loaded?(adapter) and function_exported?(adapter, :capture_scrollback, 2) do
        adapter.capture_scrollback(session, target: target, ansi: false, lines: 18)
      else
        ""
      end

    {:reply, %{text: String.trim_trailing(text)}, socket}
  end

  # Per-pane scrollback viewer: capture this pane's tmux history into a
  # dedicated read-only emulator (PaneHistoryWorker) and browse it in a drawer,
  # without touching the live shared PTY/tmux (no focus change, no resize —
  # unlike wheel-scrolling into copy-mode, which is modal and visible to every
  # viewer of the shared session). The session is validated against the
  # workspace tmux prefix like terminal:picker_preview, so a viewer cannot
  # capture panes of another workspace's sessions.
  def handle_event("pane:history_open", %{"pane-id" => pane_id}, socket) do
    socket = close_pane_history(socket)
    session = socket.assigns.tmux_session
    ws = socket.assigns.workspace
    prefix = Terminals.tmux_workspace_session_prefix(ws.name || ws.id)

    pane =
      socket.assigns.tmux_windows
      |> TerminalChrome.active_tmux_window_panes()
      |> Enum.find(&(&1.id == pane_id))

    cols = pane && TerminalChrome.tmux_dimension(pane.width)
    rows = pane && TerminalChrome.tmux_dimension(pane.height)

    with true <- is_binary(session) and String.starts_with?(session, prefix),
         true <- is_map(pane) and cols > 0 and rows > 0,
         {:ok, worker} <-
           PaneHistoryWorker.start_link(
             parent: self(),
             pane_id: pane_id,
             tmux_session: session,
             cols: cols,
             rows: rows,
             tmux_adapter: TerminalState.tmux_adapter()
           ) do
      {:noreply,
       assign(socket, :pane_history, %{
         pane_id: pane_id,
         window_id: pane.window_id,
         session: session,
         key: pane_history_key(session, pane.window_id, pane_id),
         worker: worker,
         term: nil,
         cols: cols,
         rows: rows,
         title: TerminalChrome.pane_full_title(pane),
         refreshed_at: System.system_time(:second)
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("pane:history_close", _params, socket) do
    {:noreply, close_pane_history(socket)}
  end

  def handle_event("tmux:new_window", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket = TerminalState.ensure_primary_tmux_session(socket)

      case TerminalState.tmux_adapter().new_window(socket.assigns.tmux_session,
             cwd: Show.terminal_window_cwd(socket)
           ) do
        {:ok, window_id} ->
          socket =
            socket
            |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
            |> push_patch(to: TerminalState.workspace_window_path(socket, window_id))
            |> TerminalState.focus_active_terminal(%{"reason" => "tmux:new_window"})

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not create tmux window: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("tmux:new_window_tab", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket = TerminalState.ensure_primary_tmux_session(socket)

      case TerminalState.tmux_adapter().new_window(socket.assigns.tmux_session,
             cwd: Show.terminal_window_cwd(socket)
           ) do
        {:ok, window_id} ->
          url = TerminalState.workspace_window_path(socket, window_id)

          socket =
            socket
            |> TerminalState.refresh_tmux_topology()
            |> push_event("casein:open_tab", %{url: url})

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not create tmux window: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("tmux:refresh_topology", _, socket) do
    {:noreply, TerminalState.refresh_tmux_topology(socket)}
  end

  def handle_event("tmux:select_window", %{"window-id" => window_id}, socket) do
    case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
      :ok ->
        {:noreply,
         socket
         |> Sidebar.close()
         |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
         |> TerminalState.acknowledge_active_quiet_window()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:select_window"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not select tmux window: #{inspect(reason)}")}
    end
  end

  # tmux `C-b l`: use tmux's session-level history so this also works after a
  # browser reconnect or a window switch made by another client.
  def handle_event("tmux:last_window", _params, socket) do
    case TerminalState.tmux_adapter().last_window(socket.assigns.tmux_session) do
      :ok ->
        {:noreply,
         socket
         |> Sidebar.close()
         |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
         |> TerminalState.acknowledge_active_quiet_window()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:last_window"})}

      {:error, :no_last_window} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not select last tmux window: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:consolidate_sessions", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket =
        socket
        |> TerminalState.ensure_primary_tmux_session()
        |> TerminalState.refresh_session_tabs()

      target_session = socket.assigns.tmux_session
      source_sessions = consolidation_source_sessions(socket, target_session)

      if source_sessions == [] do
        {:noreply, put_flash(socket, :info, "No other workspace sessions to consolidate.")}
      else
        case TerminalState.tmux_adapter().consolidate_sessions(target_session, source_sessions) do
          {:ok, result} ->
            socket =
              socket
              |> assign(:tmux_rename_session_id, nil)
              |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
              |> TerminalState.refresh_session_tabs()
              |> Show.assign_workspace_summaries()
              |> TerminalState.patch_current_session()
              |> TerminalState.focus_active_terminal(%{"reason" => "tmux:consolidate_sessions"})
              |> put_flash(:info, consolidate_sessions_message(result))

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not consolidate sessions: #{inspect(reason)}")}
        end
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("tmux:select_pane", %{"pane-id" => pane_id} = params, socket) do
    surface_id = socket.assigns[:terminal_surface_pane_id]

    # A pane picked from the window picker may live in another tmux window;
    # switch to that window first so selecting the pane actually brings the
    # operator into that window (deeplink semantics).
    socket = maybe_select_pane_window(socket, params["window-id"], pane_id)
    session = socket.assigns.tmux_session

    # Normal shell panes should become the tmux focus so keyboard input follows
    # the clicked pane. Feature-pane tiles (preview iframes AND file-editor
    # overlays) remain a UI-only selection so Ghostty stays attached to the
    # operator pane — selecting a file holder pane in tmux would make Ghostty
    # follow the holder script's output and steal the surface.
    tmux_result =
      if pane_id == surface_id or
           not TerminalChrome.feature_pane?(
             socket.assigns[:preview_panes] || %{},
             socket.assigns[:feature_panes] || %{},
             pane_id
           ) do
        TerminalState.tmux_adapter().select_pane(session, pane_id)
      else
        :ok
      end

    case tmux_result do
      :ok ->
        {:noreply,
         socket
         |> assign(:ui_highlight_pane_id, pane_id)
         |> assign(:entered_preview_pane_id, nil)
         |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
         |> TerminalState.acknowledge_active_quiet_window()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:select_pane"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not select tmux pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:kill_pane", %{"pane-id" => pane_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      case TerminalState.tmux_adapter().kill_pane(socket.assigns.tmux_session, pane_id) do
        :ok ->
          {:noreply,
           socket
           |> TerminalState.refresh_tmux_topology()
           |> TerminalState.focus_active_terminal(%{"reason" => "tmux:kill_pane"})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not close tmux pane: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event(
        "tmux:resize_pane",
        %{"pane-id" => pane_id, "direction" => direction} = params,
        socket
      )
      when direction in ["left", "right", "up", "down"] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      case resize_pane_mutation(socket, pane_id, direction, Map.get(params, "amount")) do
        {:ok, socket} ->
          {:noreply, TerminalState.refresh_tmux_topology(socket)}

        {:error, reason, socket} ->
          {:noreply, put_flash(socket, :error, "Could not resize tmux pane: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event(
        "tmux:resize_pane_step",
        %{"pane-id" => pane_id, "direction" => direction} = params,
        socket
      )
      when direction in ["left", "right", "up", "down"] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      case resize_pane_mutation(socket, pane_id, direction, Map.get(params, "amount")) do
        {:ok, socket} -> {:reply, %{ok: true}, socket}
        {:error, _reason, socket} -> {:reply, %{ok: false}, socket}
      end
    else
      {:reply, %{ok: false, reason: "mutations_disabled"}, socket}
    end
  end

  def handle_event("tmux:resize_pane_finish", _params, socket) do
    {:noreply, TerminalState.refresh_tmux_topology(socket)}
  end

  def handle_event("tmux:rename_start", %{"window-id" => window_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      {:noreply,
       socket
       |> assign(:tmux_rename_window_id, window_id)
       |> assign(:tmux_rename_session_id, nil)}
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("tmux:rename_cancel", _params, socket) do
    {:noreply, assign(socket, :tmux_rename_window_id, nil)}
  end

  def handle_event(
        "tmux:rename_window",
        %{"window" => %{"id" => window_id, "name" => name}},
        socket
      ) do
    TerminalState.rename_tmux_window(socket, window_id, name)
  end

  def handle_event("tmux:rename_window", %{"id" => window_id, "name" => name}, socket) do
    TerminalState.rename_tmux_window(socket, window_id, name)
  end

  def handle_event("terminal:rename_session_start", %{"session-id" => session_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      {:noreply,
       socket
       |> assign(:tmux_rename_session_id, session_id)
       |> assign(:tmux_rename_window_id, nil)}
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("terminal:rename_session_cancel", _params, socket) do
    {:noreply, assign(socket, :tmux_rename_session_id, nil)}
  end

  def handle_event(
        "terminal:rename_session",
        %{"session" => %{"id" => session_id, "tmux_session" => tmux_session, "name" => name}},
        socket
      ) do
    TerminalState.rename_tmux_session(socket, session_id, tmux_session, name)
  end

  def handle_event("tmux:cycle_window", %{"dir" => dir}, socket)
      when dir in ["next", "prev"] do
    case TerminalState.tmux_adapter().cycle_window(socket.assigns.tmux_session, dir) do
      :ok ->
        {:noreply,
         socket
         |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
         |> TerminalState.acknowledge_active_quiet_window()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:cycle_window"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cycle tmux window: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:move_window", %{"window-id" => window_id, "dir" => dir}, socket)
      when dir in ["left", "right"] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      windows = sorted_tmux_windows(socket.assigns[:tmux_windows] || [])

      case neighbor_window_move(windows, window_id, dir) do
        :edge ->
          {:noreply, socket}

        {:ok, dst_id, move_dir} ->
          move_tmux_window(socket, window_id, dst_id, move_dir)
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event(
        "tmux:move_window",
        %{"window-id" => window_id, "before-window-id" => before_id} = params,
        socket
      ) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      windows = sorted_tmux_windows(socket.assigns[:tmux_windows] || [])
      placement = Map.get(params, "dir", "before")

      {dst_id, move_dir} =
        if placement == "after" do
          {before_id, :after}
        else
          {before_id, :before}
        end

      cond do
        window_id == dst_id ->
          {:noreply, socket}

        not window_in_topology?(windows, window_id) ->
          {:noreply, put_flash(socket, :error, "Window no longer exists.")}

        not window_in_topology?(windows, dst_id) ->
          {:noreply, put_flash(socket, :error, "Target window no longer exists.")}

        already_at_target?(windows, window_id, dst_id, move_dir) ->
          {:noreply, socket}

        true ->
          move_tmux_window(socket, window_id, dst_id, move_dir)
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("terminal:cycle_session", %{"dir" => dir}, socket)
      when dir in ["next", "prev"] do
    socket = TerminalState.assign_session_tabs(socket)

    case cycle_session_target(
           socket.assigns[:session_tabs] || [],
           socket.assigns[:terminal_sid],
           dir
         ) do
      nil ->
        {:noreply,
         TerminalState.focus_active_terminal(socket, %{"reason" => "terminal:cycle_session"})}

      %{id: sid, tmux_session: tmux_session} ->
        socket =
          socket
          |> TerminalState.switch_active_session(sid, tmux_session)
          |> TerminalState.assign_session_tabs()

        socket =
          if socket.assigns[:terminal_sid] == sid,
            do: TerminalState.patch_current_session(socket),
            else: socket

        {:noreply,
         TerminalState.focus_active_terminal(socket, %{"reason" => "terminal:cycle_session"})}
    end
  end

  def handle_event("pane:navigate", %{"dir" => dir}, socket)
      when dir in ["left", "right", "up", "down", "next", "prev", "last"] do
    tmux_dir =
      %{
        "left" => "L",
        "right" => "R",
        "up" => "U",
        "down" => "D",
        "next" => "n",
        "prev" => "p",
        "last" => "l"
      }[dir]

    was_zoomed? = socket.assigns[:window_zoomed?]

    case TerminalState.tmux_adapter().navigate_pane(socket.assigns.tmux_session, tmux_dir) do
      :ok ->
        socket = socket |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)

        socket =
          if was_zoomed? do
            new_pane = socket.assigns[:tmux_active_pane_id]
            session = socket.assigns[:tmux_session]
            TerminalState.tmux_adapter().zoom_pane(session, new_pane)
            socket |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
          else
            socket
          end

        {:noreply,
         socket
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "pane:navigate"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not navigate pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:kill_window", %{"window-id" => window_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket = TerminalState.refresh_tmux_topology(socket)
      windows = socket.assigns[:tmux_windows] || []

      cond do
        length(windows) <= 1 ->
          {:noreply, put_flash(socket, :error, "Cannot close the last tmux window.")}

        not Enum.any?(windows, &(&1.id == window_id)) ->
          {:noreply, put_flash(socket, :error, "Window no longer exists. Refreshed windows.")}

        true ->
          case TerminalState.tmux_adapter().kill_window(socket.assigns.tmux_session, window_id) do
            :ok ->
              {:noreply,
               socket
               |> assign(:tmux_rename_window_id, nil)
               |> TerminalState.refresh_tmux_topology()
               |> TerminalState.focus_active_terminal(%{"reason" => "tmux:kill_window"})}

            {:error, reason} ->
              socket = TerminalState.refresh_tmux_topology(socket)
              {:noreply, put_flash(socket, :error, kill_window_error(reason))}
          end
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  # Terminals are always raw. `terminal:set_mode` (and the legacy `raw_ghostty`
  # alias) just (re)start the Ghostty multi-pane surface for the active pane.
  def handle_event("terminal:set_mode", %{"mode" => mode}, socket)
      when mode in ["raw", "raw_ghostty"] do
    {:noreply,
     socket
     |> WindowTerminalMode.set_mode(:raw)
     |> TerminalState.focus_active_terminal(%{"reason" => "terminal:set_mode"})}
  end

  # Workspaceless scratch entry in the SESSIONS sidebar — open the home-rooted
  # PTY via the existing `/workspaces/__scratch__` mount (Stage 4a). Prefer this
  # over in-place attach so mount owns SessionOwner + loc resolution.
  def handle_event("attach_terminal_session", %{"kind" => "scratch"}, socket) do
    {:noreply, push_navigate(socket, to: WorkspaceRoutes.workspace_path(Scratch.id(), "local"))}
  end

  # Attach to an execution tmux session. The channel resolves the session type
  # from the sid (exec_*); the LiveView retargets tmux topology chrome to the
  # execution's tmux session.
  def handle_event("attach_terminal_session", %{"session-id" => sid} = params, socket) do
    socket =
      socket
      |> TerminalState.switch_active_session(sid, Map.get(params, "tmux-session"))
      |> TerminalState.assign_session_tabs()

    socket =
      if socket.assigns.terminal_sid == sid do
        socket
        |> maybe_select_window(Map.get(params, "window-id"))
        |> acknowledge_attached_window(sid, Map.get(params, "window-id"))
        |> TerminalState.patch_current_session()
      else
        socket
      end

    socket =
      socket
      |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)
      |> Sidebar.maybe_focus_windows_after_attach(true)
      |> Sidebar.assign_sessions_sidebar_tree()

    {:noreply,
     TerminalState.focus_active_terminal(socket, %{"reason" => "attach_terminal_session"})}
  end

  # Switch back to the workspace shell tab. The previous channel terminates
  # automatically when the wrapper id changes (phx-hook destroy → channel.leave
  # → Attachment.close in TerminalChannel.terminate/2).
  def handle_event("terminal:switch_to_shell", _params, socket) do
    sid = socket.assigns[:default_terminal_sid] || socket.assigns.terminal_sid

    socket =
      socket
      |> TerminalState.switch_active_session(sid)
      |> TerminalState.assign_session_tabs()

    socket =
      if socket.assigns.terminal_sid == sid,
        do: TerminalState.patch_current_session(socket),
        else: socket

    {:noreply,
     TerminalState.focus_active_terminal(socket, %{"reason" => "terminal:switch_to_shell"})}
  end

  # Explicit "Refresh" in the rail: the user is asking for a re-scan, so drop
  # the memoized Browse tier too (see Sidebar.browse_tier/3) — otherwise a
  # directory created since the rail opened would stay invisible.
  def handle_event("terminal:refresh_sessions", _params, socket) do
    {:noreply,
     socket
     |> Sidebar.invalidate_browse_cache()
     |> TerminalState.refresh_session_tabs()
     |> Show.assign_workspace_summaries()
     |> Sidebar.assign_sessions_sidebar_tree()}
  end

  # Cmd/Ctrl+Click on a detected file path in terminal output. Show routes all
  # "terminal:" events here; the handler itself lives with the file-pane web
  # logic (LinkResolver re-validation, pane anchoring, files-tab fallback).
  def handle_event("terminal:open_file_link", params, socket),
    do: FilePaneEvents.handle_event("terminal:open_file_link", params, socket)

  # Cmd/Ctrl+Click on a detected http(s) URL in terminal output opens it in a
  # split preview pane (plain click opens a browser tab, handled client-side).
  # Re-validate the scheme here — the URL crossed the wire from the client. A
  # site that hard-blocks framing (X-Frame-Options / CSP frame-ancestors) can
  # only render as a blank/screenshot pane, so fall back to a browser tab
  # instead; otherwise delegate to the same path the "preview:open" UI uses.
  def handle_event("terminal:open_web_link_preview", %{"url" => url}, socket)
      when is_binary(url) do
    cond do
      not Previews.http_url?(url) ->
        {:noreply, socket}

      embeddability_checker().frame_blocked_url?(url) ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "That site blocks embedding — opened it in a new browser tab instead."
         )
         |> push_event("casein:open_tab", %{url: url})}

      true ->
        PreviewPaneEvents.handle_event("preview:open", %{"url" => url}, socket)
    end
  end

  def handle_event("terminal:open_web_link_preview", _params, socket), do: {:noreply, socket}

  @send_agent_text_max_bytes 32 * 1024

  # Editor context menu "send selection to agent": pastes the text into the
  # role-marked agent pane without submitting, so the operator reviews it and
  # presses Enter there themselves.
  def handle_event("terminal:send_agent_text", %{"text" => text} = params, socket)
      when is_binary(text) do
    cond do
      not TerminalState.tmux_mutations_allowed?(socket) ->
        TerminalState.deny_tmux_mutation(socket)

      String.trim(text) == "" ->
        {:noreply, socket}

      byte_size(text) > @send_agent_text_max_bytes ->
        {:noreply,
         put_flash(socket, :error, "Selection is too large to send to the agent (32 KB max).")}

      true ->
        prompt = agent_text_prompt(params["intent"], params["path"], text)

        case Terminals.send_agent_prompt_to_agent_pane(socket.assigns.tmux_session, prompt,
               submit: false
             ) do
          {:ok, _result} ->
            {:noreply,
             put_flash(socket, :info, "Pasted into the agent pane — press Enter there to send.")}

          {:error, error} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not reach the agent pane: #{agent_error_message(error)}"
             )}
        end
    end
  end

  def handle_event("terminal:send_agent_reference", %{"kind" => kind} = params, socket)
      when kind in ["session", "window"] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      prompt = agent_reference_prompt(kind, params)

      case Terminals.send_agent_prompt_to_agent_pane(socket.assigns.tmux_session, prompt,
             submit: false
           ) do
        {:ok, _result} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             "Pasted the reference into the agent pane — press Enter there to send."
           )}

        {:error, error} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Could not reach the agent pane: #{agent_error_message(error)}"
           )}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("terminal:send_agent_reference", _params, socket), do: {:noreply, socket}

  def handle_event(
        "terminal:kill_session",
        %{"session-id" => sid, "tmux-session" => tmux_session},
        socket
      ) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      cond do
        not is_binary(tmux_session) or tmux_session == "" ->
          {:noreply, put_flash(socket, :error, "Session has no tmux target.")}

        not Terminals.tmux_session_in_workspace?(tmux_session, socket.assigns.workspace) ->
          {:noreply, put_flash(socket, :error, "Session is outside this workspace.")}

        true ->
          case TerminalState.tmux_adapter().kill(tmux_session) do
            result ->
              if kill_session_ok?(result) do
                socket =
                  socket
                  |> assign(:tmux_rename_session_id, nil)
                  |> maybe_switch_after_kill_session(sid)
                  |> TerminalState.refresh_session_tabs()
                  |> Show.assign_workspace_summaries()
                  |> TerminalState.focus_active_terminal(%{"reason" => "terminal:kill_session"})

                {:noreply, socket}
              else
                {:noreply, put_flash(socket, :error, kill_session_error(result))}
              end
          end
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  @doc """
  Apply a terminal theme preset to the LiveView and attached pane workers.

  When `preview?: true`, the visual theme updates (client LUT + workers) but
  `terminal_preset_id` is left alone so a later restore can re-commit the
  previous choice. The client bundle includes `preview: true` so the browser
  skips writing `localStorage["casein:terminal-preset"]`.
  """
  @spec apply_terminal_preset(Phoenix.LiveView.Socket.t(), String.t(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | :error
  def apply_terminal_preset(socket, preset, opts \\ []) when is_binary(preset) do
    preview? = Keyword.get(opts, :preview?, false)

    if Terminals.valid_terminal_theme_preset?(preset) do
      themes =
        Terminals.terminal_theme_client_bundle(preset)
        |> Map.put(:preview, preview?)

      for {_pane_id, pane} <- socket.assigns.pane_data || %{},
          worker when is_pid(worker) <- [pane[:worker]] do
        send(worker, {:terminal_preset, preset})
      end

      socket =
        socket
        |> then(fn s ->
          if preview?, do: s, else: assign(s, :terminal_preset_id, preset)
        end)
        |> assign(:terminal_themes, themes)
        |> push_event("terminal:theme", themes)

      socket =
        if preview? do
          assign(socket, :palette_theme_preview_id, preset)
        else
          assign(socket, :palette_theme_preview_id, nil)
        end

      {:ok, socket}
    else
      :error
    end
  end

  @doc "Re-apply the committed terminal preset after a cancelled palette preview."
  @spec restore_terminal_preset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def restore_terminal_preset(socket) do
    case socket.assigns[:palette_theme_preview_id] do
      nil ->
        socket

      _preview ->
        committed = socket.assigns[:terminal_preset_id] || "catppuccin"

        case apply_terminal_preset(socket, committed, preview?: false) do
          {:ok, socket} -> socket
          :error -> assign(socket, :palette_theme_preview_id, nil)
        end
    end
  end

  @doc """
  Stop the pane-history worker (if any) and clear the modal assign. Also used
  by the info path when the worker reports its emulator died.
  """
  def close_pane_history(socket) do
    case socket.assigns[:pane_history] do
      %{worker: worker} when is_pid(worker) -> PaneHistoryWorker.stop(worker)
      _ -> :ok
    end

    assign(socket, :pane_history, nil)
  end

  defp pane_history_key(session, window_id, pane_id),
    do: Enum.join([session, window_id || "window", pane_id], ":")

  # Choose-tree style attach: the session dropdown's expanded window rows pass
  # the target window so attaching lands on it directly. Best-effort — the
  # window may have died between the directory poll and the click.
  defp maybe_select_window(socket, window_id) when is_binary(window_id) and window_id != "" do
    case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
      :ok -> TerminalState.refresh_tmux_topology(socket, skip_idle_patch: true)
      {:error, _reason} -> socket
    end
  end

  defp maybe_select_window(socket, _window_id), do: socket

  defp acknowledge_attached_window(socket, sid, window_id)
       when is_binary(window_id) and window_id != "" do
    TerminalState.acknowledge_quiet_window(socket, sid, window_id)
  end

  defp acknowledge_attached_window(socket, _sid, _window_id), do: socket

  defp cycle_session_target(tabs, current_sid, dir) do
    tabs =
      Enum.filter(tabs, fn tab ->
        id = Map.get(tab, :id)
        is_binary(id) and id != ""
      end)

    case tabs do
      [] ->
        nil

      [tab] ->
        if Map.get(tab, :id) == current_sid, do: nil, else: tab

      _ ->
        index = Enum.find_index(tabs, &(Map.get(&1, :id) == current_sid))
        target_index = cycle_session_index(index, length(tabs), dir)
        Enum.at(tabs, target_index)
    end
  end

  defp cycle_session_index(nil, _count, "next"), do: 0
  defp cycle_session_index(nil, count, "prev"), do: count - 1
  defp cycle_session_index(index, count, "next"), do: Integer.mod(index + 1, count)
  defp cycle_session_index(index, count, "prev"), do: Integer.mod(index - 1, count)

  defp consolidation_source_sessions(socket, target_session) do
    socket.assigns[:session_tabs]
    |> List.wrap()
    |> Enum.map(&Map.get(&1, :tmux_session))
    |> Enum.filter(&(is_binary(&1) and &1 != "" and &1 != target_session))
    |> Enum.uniq()
  end

  defp consolidate_sessions_message(result) when is_map(result) do
    moved_windows = result_count(result, :moved_windows)
    source_sessions = result_count(result, :source_sessions)

    if moved_windows == 0 do
      "No session windows were moved."
    else
      "Consolidated #{pluralize(moved_windows, "window")} from " <>
        "#{pluralize(source_sessions, "session")}."
    end
  end

  defp consolidate_sessions_message(_result), do: "Consolidated sessions."

  defp result_count(result, key) do
    value = Map.get(result, key) || Map.get(result, Atom.to_string(key)) || 0

    if is_integer(value) and value >= 0 do
      value
    else
      0
    end
  end

  defp pluralize(1, singular), do: "1 " <> singular
  defp pluralize(count, singular), do: "#{count} " <> singular <> "s"

  defp kill_window_error({code, message}) when is_binary(message) do
    if String.contains?(message, "can't kill last window") do
      "Cannot close the last tmux window. Refreshed windows."
    else
      "Could not close tmux window: #{inspect({code, message})}"
    end
  end

  defp kill_window_error(reason), do: "Could not close tmux window: #{inspect(reason)}"

  defp maybe_switch_after_kill_session(socket, sid) do
    if socket.assigns[:terminal_sid] == sid do
      shell_sid = socket.assigns[:default_terminal_sid] || socket.assigns.terminal_sid
      TerminalState.switch_active_session(socket, shell_sid)
    else
      socket
    end
  end

  defp kill_session_ok?(:ok), do: true
  defp kill_session_ok?({_, 0}), do: true
  defp kill_session_ok?(_), do: false

  defp kill_session_error(:refused_non_casein_session),
    do: "Could not close tmux session: refused non-casein session."

  defp kill_session_error({code, message}) when is_binary(message) do
    "Could not close tmux session: #{inspect({code, message})}"
  end

  defp kill_session_error(reason), do: "Could not close tmux session: #{inspect(reason)}"

  # Switch to the window that owns the selected pane when it differs from the
  # active one. The window id is taken from the picker click when present, else
  # resolved from the topology so palette/chrome callers cross windows too.
  defp maybe_select_pane_window(socket, window_id, pane_id) do
    window_id = resolve_pane_window_id(window_id, socket, pane_id)

    if is_binary(window_id) and window_id != "" and
         window_id != socket.assigns[:tmux_active_window_id] do
      case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
        :ok ->
          socket
          |> TerminalState.refresh_tmux_topology(skip_idle_patch: true)

        {:error, _reason} ->
          socket
      end
    else
      socket
    end
  end

  defp resolve_pane_window_id(window_id, _socket, _pane_id)
       when is_binary(window_id) and window_id != "",
       do: window_id

  defp resolve_pane_window_id(_window_id, socket, pane_id) do
    socket.assigns[:tmux_panes]
    |> List.wrap()
    |> Enum.find_value(fn pane ->
      if Map.get(pane, :id) == pane_id, do: Map.get(pane, :window_id)
    end)
  end

  defp resize_pane_mutation(socket, pane_id, direction, amount_param) do
    with {:ok, amount} <- TerminalState.parse_resize_amount(amount_param),
         :ok <-
           TerminalState.tmux_adapter().resize_pane(
             socket.assigns.tmux_session,
             pane_id,
             direction,
             amount
           ) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp agent_text_prompt("explain", path, text) when is_binary(path) and path != "" do
    "Explain this code from " <> path <> ":\n\n" <> text
  end

  defp agent_text_prompt("explain", _path, text), do: "Explain this code:\n\n" <> text
  defp agent_text_prompt(_intent, _path, text), do: text

  defp agent_reference_prompt("session", params) do
    """
    Inspect and reference the terminal session #{reference_label(params)}.
    Workspace: #{reference_value(params, "workspace_id")}
    Session ID: #{reference_value(params, "session_id")}
    tmux session: #{reference_value(params, "tmux_session")}
    """
    |> String.trim()
  end

  defp agent_reference_prompt("window", params) do
    """
    Inspect and reference the terminal window #{reference_label(params)}.
    Workspace: #{reference_value(params, "workspace_id")}
    Session ID: #{reference_value(params, "session_id")}
    Window ID: #{reference_value(params, "window_id")}
    Window index: #{reference_value(params, "window_index")}
    """
    |> String.trim()
  end

  defp reference_label(params), do: inspect(reference_value(params, "label"))

  defp reference_value(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value |> String.slice(0, 512) |> String.replace(~r/[\r\n]/, " ")

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        ""
    end
  end

  defp agent_error_message(%{message: message}) when is_binary(message), do: message
  defp agent_error_message(%{"message" => message}) when is_binary(message), do: message
  defp agent_error_message(other), do: inspect(other)

  defp sorted_tmux_windows(windows) do
    Enum.sort_by(windows, &Map.get(&1, :index, 0))
  end

  defp window_in_topology?(windows, window_id) do
    Enum.any?(windows, &(&1.id == window_id))
  end

  defp neighbor_window_move(windows, window_id, "left") do
    idx = Enum.find_index(windows, &(&1.id == window_id))

    case idx do
      nil -> :edge
      0 -> :edge
      i -> {:ok, Enum.at(windows, i - 1).id, :before}
    end
  end

  defp neighbor_window_move(windows, window_id, "right") do
    idx = Enum.find_index(windows, &(&1.id == window_id))

    case idx do
      nil -> :edge
      i when i >= length(windows) - 1 -> :edge
      i -> {:ok, Enum.at(windows, i + 1).id, :after}
    end
  end

  defp already_at_target?(windows, window_id, dst_id, move_dir) do
    idx = Enum.find_index(windows, &(&1.id == window_id))
    dst_idx = Enum.find_index(windows, &(&1.id == dst_id))

    case {idx, dst_idx, move_dir} do
      {i, j, :before} when i + 1 == j -> true
      {i, j, :after} when i - 1 == j -> true
      _ -> false
    end
  end

  defp move_tmux_window(socket, src_id, dst_id, dir) do
    case TerminalState.tmux_adapter().move_window(
           socket.assigns.tmux_session,
           src_id,
           dst_id,
           dir
         ) do
      :ok ->
        {:noreply, TerminalState.refresh_tmux_topology(socket, skip_idle_patch: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not move tmux window: #{inspect(reason)}")}
    end
  end

  # Config seam so tests can stub the (network-touching) embeddability probe.
  defp embeddability_checker do
    Application.get_env(:casein, :embeddability_checker, Casein.Previews)
  end
end
