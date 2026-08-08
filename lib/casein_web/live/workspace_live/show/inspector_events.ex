defmodule CaseinWeb.WorkspaceLive.Show.InspectorEvents do
  @moduledoc false

  # LiveView-owned inspector panes (issue #690). Socket state only — no registry,
  # no tmux, no Panes.feature_types. Ordinary LiveView events + a workspace
  # PubSub surface request from Casein.Cockpit.Inspectors.
  #
  # Focus / zoom / tab selection (#692) live in InspectorFocus and ride the
  # same socket assigns — still never tmux.

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Cockpit.Inspectors
  alias CaseinWeb.WorkspaceLive.Show.InspectorFocus

  def mount_assigns(socket) do
    socket =
      Enum.reduce(Inspectors.initial_assigns(), socket, fn {k, v}, s -> assign(s, k, v) end)

    Enum.reduce(InspectorFocus.mount_assigns(), socket, fn {k, v}, s -> assign(s, k, v) end)
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

  def handle_event("inspector:select", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, InspectorFocus.focus_inspector(socket, id)}
  end

  def handle_event("inspector:select", _params, socket), do: {:noreply, socket}

  def handle_event("inspector:set_placement", %{"placement" => placement}, socket) do
    placement = if placement in ["bottom", :bottom], do: :bottom, else: :right

    socket =
      socket
      |> assign(:inspector_placement, placement)
      |> recompute_geometry()
      |> InspectorFocus.reconcile()

    {:noreply, socket}
  end

  def handle_event("inspector:set_placement", _params, socket), do: {:noreply, socket}

  def handle_info({:inspector_open, attrs}, socket) do
    {:noreply, open_inspector(socket, attrs)}
  end

  def open_inspector(socket, attrs) do
    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.open(socket.assigns.inspector_panes, attrs, opts)
    opened_id = List.last(panes) && List.last(panes).id

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> InspectorFocus.after_open(opened_id)
  end

  def close_inspector(socket, id) do
    import Phoenix.Component, only: [assign: 3]

    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close(socket.assigns.inspector_panes, id, opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> InspectorFocus.reconcile()
    |> then(fn socket ->
      case InspectorFocus.active_id(socket.assigns) do
        nil ->
          socket
          |> assign(:inspector_focus_id, nil)
          |> assign(:inspector_zoomed?, false)
          |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])

        next_id ->
          if socket.assigns[:inspector_focus_id] do
            InspectorFocus.focus_inspector(socket, next_id)
          else
            assign(socket, :active_inspector_id, next_id)
          end
      end
    end)
  end

  def close_all(socket) do
    import Phoenix.Component, only: [assign: 3]

    opts = geometry_opts(socket)
    {panes, geometry} = Inspectors.close_all(opts)

    socket
    |> assign(:inspector_panes, panes)
    |> assign(:cockpit_geometry, geometry)
    |> assign(:active_inspector_id, nil)
    |> assign(:inspector_focus_id, nil)
    |> assign(:inspector_zoomed?, false)
    |> assign(:ui_highlight_pane_id, socket.assigns[:tmux_active_pane_id])
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
