defmodule DevIdeWeb.WorkspaceLive.Show.PaneLayoutEvents do
  # Tmux pane layout handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates split/zoom/close/cycle-layout/equalize/snapshot events here.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.{Audit, Terminals}
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  def handle_event("split_right", _params, socket) do
    do_split(socket, :horizontal)
  end

  def handle_event("split_down", _params, socket) do
    do_split(socket, :vertical)
  end

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

  def handle_event("pane:ensure_focus_zoom", _params, socket),
    do: ensure_mobile_focus_zoom(socket)

  def handle_event("retry_pane", %{"pane-id" => pane_id}, socket) do
    if Show.get_pane_data(socket, pane_id) do
      {:noreply,
       socket
       |> Show.update_pane(pane_id, fn p ->
         p |> Map.put(:error, nil) |> Map.put(:auto_retry_count, 0)
       end)
       |> Show.start_ghostty_for_pane(pane_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("nav:dir", %{"dir" => dir_str}, socket)
      when dir_str in ["left", "right", "up", "down"] do
    if is_binary(socket.assigns[:tmux_session]) do
      TerminalEvents.handle_event("pane:navigate", %{"dir" => dir_str}, socket)
    else
      {:noreply, socket}
    end
  end

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

  def handle_event("ghostty:snapshot", _params, socket) do
    focused_id = socket.assigns.focused_pane_id
    focused = Show.get_pane_data(socket, focused_id)

    case focused && focused.ghostty_term do
      term when is_pid(term) ->
        ws_id = socket.assigns.workspace.id

        %{base: base, files: files, preview: preview} =
          Terminals.capture_ghostty_snapshot(term, ws_id)

        Audit.emit!(%{
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

        Audit.emit!(%{
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

  defp do_split(socket, direction) do
    socket = Show.refresh_workspace_mode(socket)

    if Show.raw_terminal_allowed?(socket.assigns.workspace_mode, socket.assigns.host_id) do
      session = socket.assigns.tmux_session
      flag = if direction == :horizontal, do: "h", else: "v"

      target_pane =
        socket.assigns[:tmux_active_pane_id] ||
          Terminals.tmux_topology_snapshot(session).active_pane_id

      with pane_id when is_binary(pane_id) <- target_pane,
           {:ok, _new_pane_id} <-
             TerminalState.tmux_adapter().split_pane(session, pane_id, flag,
               cwd: Show.terminal_window_cwd(socket)
             ) do
        {:noreply,
         socket
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

  defp ensure_mobile_focus_zoom(socket) do
    if socket.assigns[:window_zoomed?] do
      {:noreply, socket}
    else
      with session when is_binary(session) <- socket.assigns[:tmux_session],
           pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id],
           :ok <- TerminalState.tmux_adapter().ensure_zoomed(session, pane_id, true) do
        {:noreply,
         socket
         |> TerminalState.refresh_tmux_topology()
         |> TerminalState.patch_current_session()
         |> TerminalState.focus_active_terminal(%{"reason" => "mobile_focus_zoom"})}
      else
        _ -> {:noreply, socket}
      end
    end
  end

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

  defp replace_only_window(socket, session, window_id) do
    case TerminalState.tmux_adapter().new_window(session, cwd: Show.terminal_window_cwd(socket)) do
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
end
