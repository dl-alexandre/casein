defmodule DevIdeWeb.WorkspaceLive.Show.TerminalEvents do
  # Terminal/tmux handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates the "tmux:*", "terminal:*" and "attach_terminal_session"
  # events listed here; template and paste events stay in Show and match
  # before the delegators. No catch-all on purpose: unknown tmux:/terminal:
  # events crash exactly as they did before the extraction.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.Terminals.Tmux
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  def handle_event("tmux:refresh_windows", _params, socket) do
    {:noreply, TerminalState.refresh_tmux_topology(socket)}
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
    prefix = Tmux.workspace_session_prefix(ws.name || ws.id)
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

  def handle_event("tmux:new_window", _params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      socket = TerminalState.ensure_primary_tmux_session(socket)

      case TerminalState.tmux_adapter().new_window(socket.assigns.tmux_session,
             cwd: Show.workspace_cwd(socket)
           ) do
        {:ok, window_id} ->
          socket =
            socket
            |> track_last_window()
            |> TerminalState.refresh_tmux_topology()
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
             cwd: Show.workspace_cwd(socket)
           ) do
        {:ok, window_id} ->
          url = TerminalState.workspace_window_path(socket, window_id)

          socket =
            socket
            |> track_last_window()
            |> TerminalState.refresh_tmux_topology()
            |> push_event("devide:open_tab", %{url: url})

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
         |> track_last_window()
         |> TerminalState.refresh_tmux_topology()
         |> push_patch(to: TerminalState.workspace_window_path(socket, window_id))
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:select_window"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not select tmux window: #{inspect(reason)}")}
    end
  end

  # tmux `C-b l`: toggle to the window that was active before the last switch.
  def handle_event("tmux:last_window", _params, socket) do
    last_id = socket.assigns[:tmux_last_window_id]

    if is_binary(last_id) and last_id != socket.assigns[:tmux_active_window_id] do
      handle_event("tmux:select_window", %{"window-id" => last_id}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("tmux:select_pane", %{"pane-id" => pane_id}, socket) do
    case TerminalState.tmux_adapter().select_pane(socket.assigns.tmux_session, pane_id) do
      :ok ->
        {:noreply,
         socket
         |> TerminalState.refresh_tmux_topology()
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

  def handle_event("tmux:split_pane", %{"pane-id" => pane_id, "direction" => direction}, socket)
      when direction in ["h", "v"] do
    if TerminalState.tmux_mutations_allowed?(socket) do
      case TerminalState.tmux_adapter().split_pane(
             socket.assigns.tmux_session,
             pane_id,
             direction
           ) do
        {:ok, _pane_id} ->
          {:noreply,
           socket
           |> TerminalState.refresh_tmux_topology()
           |> TerminalState.focus_active_terminal(%{"reason" => "tmux:split_pane"})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not split tmux pane: #{inspect(reason)}")}
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
      with {:ok, amount} <- TerminalState.parse_resize_amount(Map.get(params, "amount")),
           :ok <-
             TerminalState.tmux_adapter().resize_pane(
               socket.assigns.tmux_session,
               pane_id,
               direction,
               amount
             ) do
        {:noreply, TerminalState.refresh_tmux_topology(socket)}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not resize tmux pane: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("tmux:rename_start", %{"window-id" => window_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      {:noreply, assign(socket, :tmux_rename_window_id, window_id)}
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

  def handle_event("tmux:cycle_window", %{"dir" => dir}, socket)
      when dir in ["next", "prev"] do
    case TerminalState.tmux_adapter().cycle_window(socket.assigns.tmux_session, dir) do
      :ok ->
        {:noreply,
         socket
         |> track_last_window()
         |> TerminalState.refresh_tmux_topology()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "tmux:cycle_window"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cycle tmux window: #{inspect(reason)}")}
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
        socket = socket |> TerminalState.refresh_tmux_topology()

        socket =
          if was_zoomed? do
            new_pane = socket.assigns[:tmux_active_pane_id]
            session = socket.assigns[:tmux_session]
            TerminalState.tmux_adapter().zoom_pane(session, new_pane)
            socket |> TerminalState.refresh_tmux_topology()
          else
            socket
          end

        {:noreply, TerminalState.focus_active_terminal(socket, %{"reason" => "pane:navigate"})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not navigate pane: #{inspect(reason)}")}
    end
  end

  def handle_event("tmux:kill_window", %{"window-id" => window_id}, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      case TerminalState.tmux_adapter().kill_window(socket.assigns.tmux_session, window_id) do
        :ok ->
          {:noreply,
           socket
           |> assign(:tmux_rename_window_id, nil)
           |> TerminalState.refresh_tmux_topology()
           |> TerminalState.focus_active_terminal(%{"reason" => "tmux:kill_window"})}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not close tmux window: #{inspect(reason)}")}
      end
    else
      TerminalState.deny_tmux_mutation(socket)
    end
  end

  def handle_event("terminal:set_mode", %{"mode" => "governed"}, socket) do
    socket =
      socket
      |> Show.cleanup_ghostty_resources_if_leaving()
      |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], :governed)
      |> assign(:terminal_mode, :governed)
      |> Show.refresh_terminal_workspace_capability()
      |> Show.maybe_schedule_raw_prewarm()
      |> TerminalState.focus_active_terminal(%{"reason" => "terminal:set_mode"})

    {:noreply, socket}
  end

  # All-in on Ghostty: "raw" now starts the Ghostty component.
  # The old xterm.js raw path is deprecated for raw terminals.
  def handle_event("terminal:set_mode", %{"mode" => "raw"}, socket) do
    socket = Show.refresh_workspace_mode(socket)

    if Show.raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      socket =
        socket
        |> Show.cleanup_ghostty_resources_if_leaving()
        |> Show.start_ghostty_terminal()
        |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
        |> assign(:terminal_mode, :raw)
        |> Show.refresh_terminal_workspace_capability()
        |> TerminalState.focus_active_terminal(%{"reason" => "terminal:set_mode"})

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
    socket = Show.refresh_workspace_mode(socket)

    if Show.raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      {:noreply,
       socket
       |> Show.start_ghostty_terminal()
       |> Show.audit_terminal_mode_transition(socket.assigns[:terminal_mode], :raw)
       |> assign(:terminal_mode, :raw)
       |> Show.refresh_terminal_workspace_capability()
       |> TerminalState.focus_active_terminal(%{"reason" => "terminal:set_mode"})}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Raw Ghostty requires manual workspace mode on the local host."
       )}
    end
  end

  # Attach to a fleet execution tmux session. The channel resolves the session
  # type from the sid (exec_*) and applies the governed-only policy itself; the
  # LiveView retargets tmux topology chrome to the execution's tmux session.
  def handle_event("attach_terminal_session", %{"session-id" => sid} = params, socket) do
    socket =
      socket
      |> TerminalState.switch_active_session(sid, Map.get(params, "tmux-session"))
      |> TerminalState.assign_session_tabs()

    socket =
      if socket.assigns.terminal_sid == sid do
        socket
        |> maybe_select_window(Map.get(params, "window-id"))
        |> TerminalState.patch_current_session()
      else
        socket
      end

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

  def handle_event("terminal:refresh_sessions", _params, socket) do
    {:noreply,
     socket |> TerminalState.refresh_session_tabs() |> Show.assign_workspace_summaries()}
  end

  # Choose-tree style attach: the session dropdown's expanded window rows pass
  # the target window so attaching lands on it directly. Best-effort — the
  # window may have died between the directory poll and the click.
  defp maybe_select_window(socket, window_id) when is_binary(window_id) and window_id != "" do
    case TerminalState.tmux_adapter().select_window(socket.assigns.tmux_session, window_id) do
      :ok -> TerminalState.refresh_tmux_topology(socket)
      {:error, _reason} -> socket
    end
  end

  defp maybe_select_window(socket, _window_id), do: socket

  # Remember the outgoing active window before a switch so `C-b l`
  # (tmux:last_window) can toggle back to it.
  defp track_last_window(socket) do
    case socket.assigns[:tmux_active_window_id] do
      id when is_binary(id) and id != "" -> assign(socket, :tmux_last_window_id, id)
      _ -> socket
    end
  end
end
