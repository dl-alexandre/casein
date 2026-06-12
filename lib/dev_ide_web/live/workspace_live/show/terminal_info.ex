defmodule DevIdeWeb.WorkspaceLive.Show.TerminalInfo do
  @moduledoc false

  alias DevIDE.Terminals.Tmux
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

  defp sync_ghostty_dimensions(socket, pane_id, cols, rows) do
    case Show.get_pane_data(socket, pane_id) do
      %{worker: worker, tmux_session: tmux_session} when is_pid(worker) ->
        PaneWorker.resize(worker, cols, rows)

        Task.start(fn ->
          _ = Tmux.resize_window(tmux_session, cols, rows)
          _ = Tmux.apply_defaults(tmux_session)
        end)

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
