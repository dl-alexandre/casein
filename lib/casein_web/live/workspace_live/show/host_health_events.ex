defmodule CaseinWeb.WorkspaceLive.Show.HostHealthEvents do
  @moduledoc false

  import Phoenix.Component

  alias Casein.HostHealth

  def assign_snapshot(socket) do
    assign(socket, :host_health, HostHealth.snapshot())
  end

  def handle_event("host_health:refresh", _params, socket) do
    {:noreply, assign_snapshot(socket)}
  end
end
