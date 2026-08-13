defmodule CaseinWeb.WorkspaceLive.Show.FleetEvents do
  # Fleet board drawer open/close. Board rows rebuild with topology tabs.
  @moduledoc false

  import Phoenix.Component

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.PaneLiveness
  alias Casein.Terminals.TicketFeed
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  def mount(socket) do
    if Phoenix.LiveView.connected?(socket) do
      TicketFeed.subscribe()
      PaneLiveness.subscribe()
    end

    socket
    |> assign(:fleet_drawer_open, false)
    |> assign(:fleet_board, socket.assigns[:fleet_board] || FleetBoard.empty())
  end

  # A landed ticket refresh is the only thing that turns an unknown feed into
  # joined rows, so rebuild the board from the tabs already in the socket. No
  # topology read, no `gh` — the refresh already did both.
  def handle_info({:pane_liveness, :refreshed, session}, socket) do
    if socket.assigns[:tmux_session] == session and is_list(socket.assigns[:tmux_window_tabs]) do
      {:noreply, TerminalState.assign_tmux_window_tabs(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ticket_feed, :refreshed, _key}, socket) do
    if is_list(socket.assigns[:tmux_window_tabs]) do
      {:noreply, TerminalState.assign_tmux_window_tabs(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("fleet_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, not socket.assigns.fleet_drawer_open)}
  end

  def handle_event("fleet_drawer:close", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, false)}
  end
end
