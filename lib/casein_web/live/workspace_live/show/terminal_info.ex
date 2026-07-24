defmodule CaseinWeb.WorkspaceLive.Show.TerminalInfo do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias CaseinWeb.WorkspaceLive.PaneWorker
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  @doc false
  def handle_info({:terminal_ready, "ghostty-" <> pane_id, cols, rows}, socket) do
    sync_ghostty_dimensions(socket, pane_id, cols, rows)
  end

  def handle_info({:terminal_ready, _other_id, _cols, _rows}, socket),
    do: {:noreply, socket}

  def handle_info({:terminal_resize, "ghostty-" <> pane_id, cols, rows}, socket) do
    # While the nav rail is open the terminal viewport is squeezed; applying
    # that transient size means a tmux reflow on open and another on close —
    # and, with a second viewer attached, a visible resize fight. Hold the
    # report instead (the client scales the frozen grid to fit) and flush the
    # latest one when the rail closes. `:terminal_ready` below still applies
    # immediately so a pane mounted while the rail is open gets a real size.
    if socket.assigns[:sidebar_mode] in [nil, :closed] do
      sync_ghostty_dimensions(socket, pane_id, cols, rows)
    else
      held = Map.put(socket.assigns[:held_pane_resizes] || %{}, pane_id, {cols, rows})
      {:noreply, assign(socket, :held_pane_resizes, held)}
    end
  end

  def handle_info({:terminal_resize, _other_id, _cols, _rows}, socket),
    do: {:noreply, socket}

  # A viewer reported whether its browser tab is active (visible + focused). The
  # SessionOwner sizes the shared PTY/tmux to the focused viewer, so a
  # backgrounded or passive viewer no longer shrinks the primary one.
  def handle_info({:terminal_active, "ghostty-" <> pane_id, active?}, socket) do
    case Show.get_pane_data(socket, pane_id) do
      %{worker: worker} when is_pid(worker) -> PaneWorker.set_active(worker, active?)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_active, _other_id, _active?}, socket),
    do: {:noreply, socket}

  def handle_info({:terminal_resync, "ghostty-" <> pane_id, _reason}, socket) do
    case Show.get_pane_data(socket, pane_id) do
      %{worker: worker} when is_pid(worker) -> PaneWorker.resync(worker)
      _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_info({:terminal_resync, _other_id, _reason}, socket),
    do: {:noreply, socket}

  # The PaneHistoryWorker finished seeding its read-only emulator: hand the
  # term to the history drawer so the GhosttyTerminalComponent can mount on it.
  # Guarded by pane id — a slow capture must not attach to a modal that was
  # meanwhile closed or reopened on another pane (the stale worker was already
  # stopped by close_pane_history).
  def handle_info({:pane_history_ready, pane_id, term}, socket) do
    case socket.assigns[:pane_history] do
      %{pane_id: ^pane_id} = history ->
        {:noreply, assign(socket, :pane_history, %{history | term: term})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:pane_history_down, pane_id}, socket) do
    case socket.assigns[:pane_history] do
      %{pane_id: ^pane_id} -> {:noreply, assign(socket, :pane_history, nil)}
      _ -> {:noreply, socket}
    end
  end

  defp sync_ghostty_dimensions(socket, pane_id, cols, rows) do
    {:noreply, apply_ghostty_dimensions(socket, pane_id, cols, rows)}
  end

  defp apply_ghostty_dimensions(socket, pane_id, cols, rows) do
    case Show.get_pane_data(socket, pane_id) do
      %{worker: worker, tmux_session: tmux_session} when is_pid(worker) ->
        # Resize this viewer's emulator grid. Only the focused viewer's resize
        # reaches SessionOwner (PaneWorker gates owner_resize); passive viewers
        # scale display locally in ghostty_terminal.js to the authoritative grid.
        PaneWorker.resize(worker, cols, rows)

        socket = Show.update_pane(socket, pane_id, fn p -> %{p | cols: cols, rows: rows} end)

        if tmux_session == socket.assigns.tmux_session,
          do: TerminalState.refresh_tmux_topology(socket),
          else: socket

      _ ->
        socket
    end
  end

  @doc """
  Apply the freshest viewer resize held per pane while the nav rail was open
  (see the `:terminal_resize` hold above), then clear the held map. Called by
  `Sidebar.close/1` so the terminal snaps back to its real viewport exactly
  once per rail open/close cycle.
  """
  def flush_held_pane_resizes(socket) do
    case socket.assigns[:held_pane_resizes] do
      held when is_map(held) and map_size(held) > 0 ->
        held
        |> Enum.reduce(socket, fn {pane_id, {cols, rows}}, acc ->
          apply_ghostty_dimensions(acc, pane_id, cols, rows)
        end)
        |> assign(:held_pane_resizes, %{})

      _ ->
        socket
    end
  end
end
