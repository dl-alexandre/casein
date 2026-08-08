defmodule CaseinWeb.WorkspaceLive.Show.InspectorEvents do
  @moduledoc false

  # LiveView-owned inspector panes (issue #690). Socket state only — no registry,
  # no tmux, no Panes.feature_types. Ordinary LiveView events + a workspace
  # PubSub surface request from Casein.Cockpit.Inspectors.

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Cockpit.Inspectors

  def mount_assigns(socket) do
    Enum.reduce(Inspectors.initial_assigns(), socket, fn {k, v}, s -> assign(s, k, v) end)
  end

  def subscribe(socket) do
    if connected?(socket) do
      _ = Inspectors.subscribe(socket.assigns.workspace.id)
    end

    socket
  end

  def handle_event("inspector:open", params, socket) do
    {:noreply, open_inspector(socket, params)}
  end

  def handle_event("inspector:close", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, close_inspector(socket, id)}
  end

  def handle_event("inspector:close", _params, socket), do: {:noreply, socket}

  def handle_event("inspector:close_all", _params, socket) do
    {:noreply, close_all(socket)}
  end

  def handle_event("inspector:set_placement", %{"placement" => placement}, socket) do
    placement = if placement in ["bottom", :bottom], do: :bottom, else: :right

    socket =
      socket
      |> assign(:inspector_placement, placement)
      |> recompute_geometry()

    {:noreply, socket}
  end

  def handle_event("inspector:set_placement", _params, socket), do: {:noreply, socket}

  def handle_info({:inspector_open, attrs}, socket) do
    {:noreply, open_inspector(socket, attrs)}
  end

  def open_inspector(socket, attrs) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.open(socket.assigns.inspector_panes, attrs, opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
  end

  def close_inspector(socket, id) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close(socket.assigns.inspector_panes, id, opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
  end

  def close_all(socket) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close_all(opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
  end

  defp recompute_geometry(socket) do
    geometry =
      Inspectors.geometry(socket.assigns.inspector_panes, geometry_opts(socket))

    assign(socket, :cockpit_geometry, geometry)
  end

  defp geometry_opts(socket) do
    [
      placement: socket.assigns[:inspector_placement] || :right,
      fraction: socket.assigns[:inspector_fraction] || 0.4
    ]
  end
end
