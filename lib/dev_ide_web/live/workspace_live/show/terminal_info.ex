defmodule DevIdeWeb.WorkspaceLive.Show.TerminalInfo do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias DevIdeWeb.WorkspaceLive.PaneWorker
  alias DevIdeWeb.WorkspaceLive.Show
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  @doc false
  def handle_info({:terminal_ready, "ghostty-" <> pane_id, cols, rows}, socket) do
    sync_ghostty_dimensions(socket, pane_id, cols, rows)
  end

  def handle_info({:terminal_ready, _other_id, _cols, _rows}, socket),
    do: {:noreply, socket}

  def handle_info({:terminal_resize, "ghostty-" <> pane_id, cols, rows}, socket) do
    sync_ghostty_dimensions(socket, pane_id, cols, rows)
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
  # term to the history modal so the GhosttyTerminalComponent can mount on it.
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
    case Show.get_pane_data(socket, pane_id) do
      %{worker: worker, tmux_session: tmux_session} when is_pid(worker) ->
        # Resize this viewer's own grid to its fitted size. The shared PTY and the
        # tmux window are sized by the SessionOwner, which tracks the focused
        # viewer through the terminal owner — a per-viewer tmux resize
        # here would fight that and re-introduce cross-viewer rendering corruption.
        PaneWorker.resize(worker, cols, rows)

        socket = Show.update_pane(socket, pane_id, fn p -> %{p | cols: cols, rows: rows} end)

        socket =
          if tmux_session == socket.assigns.tmux_session,
            do: TerminalState.refresh_tmux_topology(socket),
            else: socket

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end
end
