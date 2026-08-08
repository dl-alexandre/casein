defmodule CaseinWeb.WorkspaceLive.Show.InspectorFocusTest do
  use Casein.DataCase, async: true

  alias Casein.Cockpit.Geometry
  alias Casein.Cockpit.Inspectors
  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents
  alias CaseinWeb.WorkspaceLive.Show.InspectorFocus
  alias CaseinWeb.WorkspaceLive.Show.PaneLayoutEvents
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents

  defp socket(assigns) do
    base = Inspectors.initial_assigns() |> Map.merge(InspectorFocus.mount_assigns())

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          Map.merge(base, %{
            __changed__: %{},
            flash: %{},
            focused_pane_id: "p1",
            pane_data: %{},
            tmux_active_pane_id: "%1",
            tmux_session: "sess",
            tmux_mutations_enabled?: true,
            tmux_topology_layout_version: 1,
            workspace: %{id: "ws-inspector-focus"}
          }),
          assigns
        ),
      private: %{live_temp: %{}}
    }
  end

  defp with_inspector(extra \\ %{}) do
    {panes, geometry} =
      Inspectors.open([], %{id: "insp-a", kind: :diff, title: "Diff"},
        placement: :right,
        fraction: 0.4
      )

    socket(
      Map.merge(
        %{
          inspector_panes: panes,
          cockpit_geometry: geometry,
          inspector_focus_id: "insp-a",
          active_inspector_id: "insp-a"
        },
        extra
      )
    )
  end

  defp pushed_events(socket) do
    socket.private[:live_temp][:push_events] || Map.get(socket.private, :push_events, []) || []
  end

  test "inspector zoom toggles socket state and never requests tmux zoom" do
    s = with_inspector()

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:zoom_focused", %{}, s)
    assert s2.assigns.inspector_zoomed? == true

    refute Enum.any?(pushed_events(s2), fn
             ["tmux:zoom_transition_requested", _] -> true
             {_, "tmux:zoom_transition_requested", _} -> true
             _ -> false
           end)

    assert {:noreply, s3} = PaneLayoutEvents.handle_event("pane:zoom_focused", %{}, s2)
    assert s3.assigns.inspector_zoomed? == false
  end

  test "inspector close removes the pane without kill_pane" do
    s = with_inspector()

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:close_focused", %{}, s)
    assert s2.assigns.inspector_panes == []
    assert s2.assigns.inspector_focus_id == nil
    assert s2.assigns.inspector_zoomed? == false
    refute Geometry.inspector_open?(s2.assigns.cockpit_geometry)
  end

  test "closing the last inspector clears zoom and focus" do
    s = with_inspector(%{inspector_zoomed?: true})

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:close_focused", %{}, s)
    assert s2.assigns.active_inspector_id == nil
    assert s2.assigns.inspector_zoomed? == false
    assert s2.assigns.ui_highlight_pane_id == "%1"
  end

  test "arrow from terminal into inspector is socket focus only" do
    {panes, geometry} =
      Inspectors.open([], %{id: "insp-side", kind: :diff, title: "Side"}, placement: :right)

    s =
      socket(%{
        inspector_panes: panes,
        cockpit_geometry: geometry,
        active_inspector_id: "insp-side",
        inspector_focus_id: nil,
        inspector_placement: :right
      })

    assert {:noreply, s2} =
             TerminalEvents.handle_event("pane:navigate", %{"dir" => "right"}, s)

    assert s2.assigns.inspector_focus_id == "insp-side"
    assert s2.assigns.active_inspector_id == "insp-side"
  end

  test "arrow from inspector back to terminal clears inspector focus" do
    s = with_inspector(%{inspector_placement: :right})

    assert {:noreply, s2} =
             TerminalEvents.handle_event("pane:navigate", %{"dir" => "left"}, s)

    assert s2.assigns.inspector_focus_id == nil
  end

  test "tabs: select switches active inspector without tmux" do
    {panes, geometry} =
      Inspectors.open([], %{id: "insp-a", kind: :diff, title: "A"}, placement: :right)

    {panes, geometry} =
      Inspectors.open(panes, %{id: "insp-b", kind: :run, title: "B"},
        placement: :right,
        fraction: Geometry.inspector_fraction(geometry)
      )

    s =
      socket(%{
        inspector_panes: panes,
        cockpit_geometry: geometry,
        inspector_focus_id: "insp-a",
        active_inspector_id: "insp-a"
      })

    assert {:noreply, s2} =
             InspectorEvents.handle_event("inspector:select", %{"id" => "insp-b"}, s)

    assert s2.assigns.active_inspector_id == "insp-b"
    assert s2.assigns.inspector_focus_id == "insp-b"
  end

  test "REGRESSION: real pane zoom still requests tmux transition" do
    s =
      socket(%{
        inspector_focus_id: nil,
        inspector_panes: [],
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true,
        tmux_topology_layout_version: 42
      })

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:zoom_focused", %{}, s)

    assert Enum.any?(pushed_events(s2), fn
             ["tmux:zoom_transition_requested", %{pane_id: "%1", layout_version: 42}] -> true
             {_, "tmux:zoom_transition_requested", %{pane_id: "%1", layout_version: 42}} -> true
             _ -> false
           end)
  end

  test "REGRESSION: without inspectors, navigate stays on the tmux path" do
    s =
      socket(%{
        inspector_focus_id: nil,
        inspector_panes: [],
        tmux_session: "sess",
        tmux_active_pane_id: "%1"
      })

    assert InspectorFocus.navigate(s, "left") == :tmux
  end

  test "focus_target prefers live inspector id and falls back to tmux" do
    assigns = with_inspector().assigns
    assert InspectorFocus.focus_target(assigns) == {:inspector, "insp-a"}

    stale = %{assigns | inspector_focus_id: "insp-missing", inspector_panes: []}
    assert InspectorFocus.focus_target(stale) == {:tmux, "%1"}
  end
end
