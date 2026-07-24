defmodule CaseinWeb.WorkspaceLive.Show.PaneLayoutEvents do
  # Tmux pane layout handle_event clauses extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates split/zoom/close/cycle-layout/equalize/snapshot events here.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.{Audit, Terminals}
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

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

  def handle_event("pane:zoom_focused", _params, socket),
    do: request_tmux_zoom_transition(socket)

  def handle_event("pane:commit_zoom", params, socket), do: commit_tmux_zoom(params, socket)

  def handle_event("pane:swap_previous", _params, socket),
    do: request_tmux_swap_transition(socket, "U")

  def handle_event("pane:swap_next", _params, socket),
    do: request_tmux_swap_transition(socket, "D")

  def handle_event("pane:commit_swap", params, socket), do: commit_tmux_swap(params, socket)

  def handle_event(
        "tmux:split_pane",
        %{"pane-id" => pane_id, "direction" => direction},
        socket
      )
      when direction in ["h", "v"],
      do: request_tmux_split_transition(socket, pane_id, direction)

  def handle_event("pane:commit_split", params, socket), do: commit_tmux_split(params, socket)

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

      case target_pane do
        pane_id when is_binary(pane_id) ->
          request_tmux_split_transition(socket, pane_id, flag)

        _ ->
          {:noreply, put_flash(socket, :error, "No active tmux pane to split.")}
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

  # Every operator zoom entry point (header, context menu, palette, C-b z)
  # reaches this request event first. The browser captures the last painted
  # terminal frame, then calls pane:commit_zoom with the layout version it
  # actually captured. Mobile's automatic focus zoom intentionally stays on
  # the direct idempotent path above: it is viewport correction, not an
  # operator animation.
  defp request_tmux_zoom_transition(socket) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id] do
      if TerminalState.tmux_mutations_allowed?(socket) do
        {:noreply,
         push_event(socket, "tmux:zoom_transition_requested", %{
           pane_id: pane_id,
           layout_version: socket.assigns[:tmux_topology_layout_version] || 0
         })}
      else
        TerminalState.deny_tmux_mutation(socket)
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Like zoom, a swap is a two-step browser/server transaction. The request
  # names the tmux-active pane and direction, but performs no mutation; the
  # browser first freezes the projection it actually painted, then commits
  # against that projection's layout version.
  defp request_tmux_swap_transition(socket, direction) when direction in ["U", "D"] do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         pane_id when is_binary(pane_id) <- socket.assigns[:tmux_active_pane_id] do
      if TerminalState.tmux_mutations_allowed?(socket) do
        {:noreply,
         push_event(socket, "tmux:swap_transition_requested", %{
           pane_id: pane_id,
           direction: direction,
           layout_version: socket.assigns[:tmux_topology_layout_version] || 0
         })}
      else
        TerminalState.deny_tmux_mutation(socket)
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Splits use the same optimistic boundary as zoom and swap, but the target
  # may be a context-menu pane rather than the currently active pane. The
  # browser freezes the painted topology before asking the server to add the
  # new identity, so the confirmed pane can be uncovered from its shared edge.
  defp request_tmux_split_transition(socket, pane_id, direction)
       when is_binary(pane_id) and direction in ["h", "v"] do
    with session when is_binary(session) <- socket.assigns[:tmux_session] do
      if TerminalState.tmux_mutations_allowed?(socket) do
        {:noreply,
         push_event(socket, "tmux:split_transition_requested", %{
           pane_id: pane_id,
           direction: direction,
           layout_version: socket.assigns[:tmux_topology_layout_version] || 0
         })}
      else
        TerminalState.deny_tmux_mutation(socket)
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp commit_tmux_zoom(params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      with session when is_binary(session) <- socket.assigns[:tmux_session],
           pane_id when is_binary(pane_id) <- event_pane_id(params),
           {:ok, base_layout_version} <- parse_layout_version(params),
           current <- Terminals.tmux_topology_snapshot(session),
           :ok <- validate_zoom_precondition(current, pane_id, base_layout_version),
           :ok <- TerminalState.tmux_adapter().zoom_pane(session, pane_id),
           confirmed <- Terminals.tmux_topology_snapshot(session) do
        socket =
          socket
          |> TerminalState.assign_tmux_topology(confirmed, skip_idle_patch: true)
          |> TerminalState.patch_current_session()
          |> TerminalState.focus_active_terminal(%{"reason" => "zoom_pane"})

        {:reply, Map.put(layout_transition_projection(confirmed), :ok, true), socket}
      else
        {:error, :stale_layout, current} ->
          socket =
            socket
            |> TerminalState.assign_tmux_topology(current, skip_idle_patch: true)
            |> put_flash(:info, "Pane layout changed before zoom; try again.")

          {:reply,
           %{
             ok: false,
             error: "stale_layout",
             layout_version: Map.get(current, :layout_version, current.version)
           }, socket}

        {:error, :invalid_layout_version} ->
          {:reply, %{ok: false, error: "invalid_layout_version"},
           put_flash(socket, :error, "Could not verify the pane layout for zoom.")}

        {:error, reason} ->
          {:reply, %{ok: false, error: "zoom_failed"},
           put_flash(socket, :error, "Could not zoom tmux pane: #{inspect(reason)}")}

        _ ->
          {:reply, %{ok: false, error: "zoom_unavailable"},
           put_flash(socket, :error, "No active tmux pane is available to zoom.")}
      end
    else
      {:reply, %{ok: false, error: "mutations_disabled"},
       put_flash(socket, :error, "Tmux layout changes are not allowed for this session.")}
    end
  end

  defp commit_tmux_swap(params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      with session when is_binary(session) <- socket.assigns[:tmux_session],
           pane_id when is_binary(pane_id) <- event_pane_id(params),
           {:ok, direction} <- parse_swap_direction(params),
           {:ok, base_layout_version} <- parse_layout_version(params),
           current <- Terminals.tmux_topology_snapshot(session),
           :ok <- validate_swap_precondition(current, pane_id, base_layout_version),
           :ok <- TerminalState.tmux_adapter().swap_pane(session, pane_id, direction),
           confirmed <- Terminals.tmux_topology_snapshot(session) do
        socket =
          socket
          |> TerminalState.assign_tmux_topology(confirmed, skip_idle_patch: true)
          |> TerminalState.patch_current_session()
          |> TerminalState.focus_active_terminal(%{"reason" => "swap_pane"})

        {:reply, Map.put(layout_transition_projection(confirmed), :ok, true), socket}
      else
        {:error, :stale_layout, current} ->
          socket =
            socket
            |> TerminalState.assign_tmux_topology(current, skip_idle_patch: true)
            |> put_flash(:info, "Pane layout changed before swap; try again.")

          {:reply,
           %{
             ok: false,
             error: "stale_layout",
             layout_version: Map.get(current, :layout_version, current.version)
           }, socket}

        {:error, :invalid_layout_version} ->
          {:reply, %{ok: false, error: "invalid_layout_version"},
           put_flash(socket, :error, "Could not verify the pane layout for swap.")}

        {:error, :invalid_direction} ->
          {:reply, %{ok: false, error: "invalid_direction"},
           put_flash(socket, :error, "Could not determine which way to swap the pane.")}

        {:error, :window_zoomed} ->
          {:reply, %{ok: false, error: "window_zoomed"},
           put_flash(socket, :info, "Unzoom the window before swapping panes.")}

        {:error, :single_pane} ->
          {:reply, %{ok: false, error: "single_pane"}, socket}

        {:error, reason} ->
          {:reply, %{ok: false, error: "swap_failed"},
           put_flash(socket, :error, "Could not swap tmux pane: #{inspect(reason)}")}

        _ ->
          {:reply, %{ok: false, error: "swap_unavailable"},
           put_flash(socket, :error, "No active tmux pane is available to swap.")}
      end
    else
      {:reply, %{ok: false, error: "mutations_disabled"},
       put_flash(socket, :error, "Tmux layout changes are not allowed for this session.")}
    end
  end

  defp commit_tmux_split(params, socket) do
    if TerminalState.tmux_mutations_allowed?(socket) do
      with session when is_binary(session) <- socket.assigns[:tmux_session],
           pane_id when is_binary(pane_id) <- event_pane_id(params),
           {:ok, direction} <- parse_split_direction(params),
           {:ok, base_layout_version} <- parse_layout_version(params),
           current <- Terminals.tmux_topology_snapshot(session),
           :ok <- validate_split_precondition(current, pane_id, base_layout_version),
           {:ok, new_pane_id} <-
             TerminalState.tmux_adapter().split_pane(session, pane_id, direction,
               cwd: Show.terminal_window_cwd(socket)
             ),
           confirmed <- Terminals.tmux_topology_snapshot(session) do
        socket =
          socket
          |> TerminalState.assign_tmux_topology(confirmed, skip_idle_patch: true)
          |> assign(:ui_highlight_pane_id, new_pane_id)
          |> TerminalState.patch_current_session()
          |> TerminalState.focus_active_terminal(%{"reason" => "split_pane"})

        {:reply,
         layout_transition_projection(confirmed)
         |> Map.put(:ok, true)
         |> Map.put(:new_pane_id, new_pane_id), socket}
      else
        {:error, :stale_layout, current} ->
          socket =
            socket
            |> TerminalState.assign_tmux_topology(current, skip_idle_patch: true)
            |> put_flash(:info, "Pane layout changed before split; try again.")

          {:reply,
           %{
             ok: false,
             error: "stale_layout",
             layout_version: Map.get(current, :layout_version, current.version)
           }, socket}

        {:error, :invalid_layout_version} ->
          {:reply, %{ok: false, error: "invalid_layout_version"},
           put_flash(socket, :error, "Could not verify the pane layout for split.")}

        {:error, :invalid_direction} ->
          {:reply, %{ok: false, error: "invalid_direction"},
           put_flash(socket, :error, "Could not determine how to split the pane.")}

        {:error, :window_zoomed} ->
          {:reply, %{ok: false, error: "window_zoomed"},
           put_flash(socket, :info, "Unzoom the window before splitting a pane.")}

        {:error, reason} ->
          {:reply, %{ok: false, error: "split_failed"},
           put_flash(socket, :error, "Could not split tmux pane: #{inspect(reason)}")}

        _ ->
          {:reply, %{ok: false, error: "split_unavailable"},
           put_flash(socket, :error, "No tmux pane is available to split.")}
      end
    else
      {:reply, %{ok: false, error: "mutations_disabled"},
       put_flash(socket, :error, "Tmux layout changes are not allowed for this session.")}
    end
  end

  defp validate_zoom_precondition(topology, pane_id, base_layout_version) do
    current_layout_version = Map.get(topology, :layout_version, topology.version)

    cond do
      current_layout_version != base_layout_version ->
        {:error, :stale_layout, topology}

      topology.active_pane_id != pane_id ->
        {:error, :stale_layout, topology}

      true ->
        :ok
    end
  end

  defp validate_swap_precondition(topology, pane_id, base_layout_version) do
    current_layout_version = Map.get(topology, :layout_version, topology.version)
    active_panes = TerminalChrome.active_tmux_window_panes(topology.windows)

    cond do
      current_layout_version != base_layout_version ->
        {:error, :stale_layout, topology}

      topology.active_pane_id != pane_id ->
        {:error, :stale_layout, topology}

      Enum.any?(active_panes, &(Map.get(&1, :zoomed?) == true)) ->
        {:error, :window_zoomed}

      length(active_panes) < 2 ->
        {:error, :single_pane}

      true ->
        :ok
    end
  end

  defp validate_split_precondition(topology, pane_id, base_layout_version) do
    current_layout_version = Map.get(topology, :layout_version, topology.version)
    active_panes = TerminalChrome.active_tmux_window_panes(topology.windows)

    cond do
      current_layout_version != base_layout_version ->
        {:error, :stale_layout, topology}

      not Enum.any?(active_panes, &(&1.id == pane_id)) ->
        {:error, :stale_layout, topology}

      Enum.any?(active_panes, &(Map.get(&1, :zoomed?) == true)) ->
        {:error, :window_zoomed}

      true ->
        :ok
    end
  end

  defp parse_layout_version(params) do
    case params["base_layout_version"] || params["base-layout-version"] do
      version when is_integer(version) and version >= 0 ->
        {:ok, version}

      version when is_binary(version) ->
        case Integer.parse(version) do
          {parsed, ""} when parsed >= 0 -> {:ok, parsed}
          _ -> {:error, :invalid_layout_version}
        end

      _ ->
        {:error, :invalid_layout_version}
    end
  end

  defp parse_swap_direction(params) do
    case params["direction"] do
      direction when direction in ["U", "D"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp parse_split_direction(params) do
    case params["direction"] do
      direction when direction in ["h", "v"] -> {:ok, direction}
      _ -> {:error, :invalid_direction}
    end
  end

  defp event_pane_id(params), do: params["pane_id"] || params["pane-id"]

  defp layout_transition_projection(topology) do
    full_panes = TerminalChrome.active_tmux_window_panes(topology.windows)
    bounds = TerminalChrome.tmux_pane_bounds(full_panes)

    pane_rects =
      full_panes
      |> TerminalChrome.renderable_tmux_window_panes()
      |> Enum.map(fn pane ->
        %{
          id: pane.id,
          left: TerminalChrome.tmux_dimension(pane.left),
          top: TerminalChrome.tmux_dimension(pane.top),
          width: TerminalChrome.tmux_dimension(pane.width),
          height: TerminalChrome.tmux_dimension(pane.height)
        }
      end)

    %{
      version: topology.version,
      layout_version: Map.get(topology, :layout_version, topology.version),
      zoomed: Enum.any?(full_panes, &(Map.get(&1, :zoomed?) == true)),
      active_pane_id: topology.active_pane_id,
      bounds: %{width: bounds.width, height: bounds.height},
      pane_rects: pane_rects
    }
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
