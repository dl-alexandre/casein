defmodule CaseinWeb.WorkspaceLive.Show.FleetEvents do
  # Fleet board drawer open/close. Board rows rebuild with topology tabs.
  @moduledoc false

  import Phoenix.Component

  alias Casein.Terminals.FleetBoard

  def mount(socket) do
    socket
    |> assign(:fleet_drawer_open, false)
    |> assign(:fleet_board, socket.assigns[:fleet_board] || FleetBoard.empty())
  end

  def handle_event("fleet_drawer:toggle", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, not socket.assigns.fleet_drawer_open)}
  end

  def handle_event("fleet_drawer:close", _params, socket) do
    {:noreply, assign(socket, :fleet_drawer_open, false)}
  end
end
