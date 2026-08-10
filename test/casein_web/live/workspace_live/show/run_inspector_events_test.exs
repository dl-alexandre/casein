defmodule CaseinWeb.WorkspaceLive.Show.RunInspectorEventsTest do
  use Casein.TestCase, async: true

  import Phoenix.Component, only: [assign: 3]

  alias Casein.Cockpit.Inspectors
  alias Casein.CommandPalette.Actions
  alias Casein.Workspace
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.ActionAvailability, as: Avail
  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents
  alias CaseinWeb.WorkspaceLive.Show.RunInspectorEvents

  setup do
    root =
      Path.join(System.tmp_dir!(), "run-insp-events-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "palette entry resolves to run:open_in_pane" do
    item = Enum.find(Actions.all(), &(&1.id == "run:open_in_pane"))
    assert item
    assert item.payload.event == "run:open_in_pane"
    assert "run:open_in_pane" in Actions.allowed_events()
    assert "run:open_in_pane" in Show.known_events()
    assert "run:open_inspector" in Show.known_events()
  end

  test "availability rule always offers the palette item" do
    item = Enum.find(Actions.all(), &(&1.id == "run:open_in_pane"))

    ctx =
      Avail.context(%{
        tmux_mutations_enabled?: false,
        tmux_session: nil,
        terminal_mode: :governed,
        tmux_panes: []
      })

    assert Avail.item_available?(item, ctx)
    assert Avail.available?("run:open_in_pane", ctx)
  end

  test "run:open_in_pane falls back to the full-area run tab without tmux", %{root: root} do
    {:noreply, socket} =
      RunInspectorEvents.handle_event("run:open_in_pane", %{}, socket(root))

    assert socket.assigns.tab == "run"
    refute Inspectors.run_open?(socket.assigns.inspector_slots)
  end

  test "run:open_in_pane opens a LiveView inspector when tmux context exists", %{root: root} do
    {:noreply, socket} =
      RunInspectorEvents.handle_event(
        "run:open_in_pane",
        %{"run_id" => "run-abc"},
        socket(root, tmux: true)
      )

    assert socket.assigns.tab == "terminal"
    assert Inspectors.run_open?(socket.assigns.inspector_slots)
    assert Inspectors.primary_run_id(socket.assigns.inspector_slots) == "run-abc"
  end

  test "missing run id restore clears selection (empty ledger state, not error)", %{root: root} do
    serialized = [
      %{"type" => "inspector", "kind" => "run", "run_id" => "run-does-not-exist"}
    ]

    socket = InspectorEvents.restore_inspectors(socket(root, tmux: true), serialized)

    assert Inspectors.run_open?(socket.assigns.inspector_slots)
    assert socket.assigns.tab == "terminal"
    assert socket.assigns.selected_run_id == nil
    assert socket.assigns.selected_run_summary == nil
    assert socket.assigns.selected_run_timeline == []
    refute match?(%{flash: %{error: _}}, socket.assigns)
  end

  test "inspector_open PubSub intent opens the run inspector", %{root: root} do
    {:noreply, socket} =
      InspectorEvents.handle_info(
        {:inspector_open, %{kind: :run, run_id: "run-xyz"}},
        socket(root)
      )

    assert socket.assigns.tab == "terminal"
    assert Inspectors.run_open?(socket.assigns.inspector_slots)
    assert Inspectors.primary_run_id(socket.assigns.inspector_slots) == "run-xyz"
  end

  test "diff fallback still works without tmux (both inspector types)", %{root: root} do
    {:noreply, socket} =
      InspectorEvents.handle_event("diff:open_inspector", %{}, socket(root))

    assert socket.assigns.tab == "diff"
    refute Inspectors.diff_open?(socket.assigns.inspector_slots)
  end

  defp socket(root, opts \\ []) do
    workspace = %Workspace{
      id: "ws-run-insp",
      name: "ws-run-insp",
      path: root,
      status: :running,
      metadata: %{attached_folder: true}
    }

    initial = Inspectors.initial_assigns()

    socket =
      %Phoenix.LiveView.Socket{}
      |> assign(:workspace, workspace)
      |> assign(:host_path, {:ok, root})
      |> assign(:host_loc, {:ok, {:local, root}})
      |> assign(:tab, "terminal")
      |> assign(:open_file, nil)
      |> assign(:file_render_mode, nil)
      |> assign(:file_error, nil)
      |> assign(:save_error, nil)
      |> assign(:file_diff, nil)
      |> assign(:git_status, [])
      |> assign(:tree, %{})
      |> assign(:selected_dir, "")
      |> assign(:inspector_slots, initial.inspector_slots)
      |> assign(:inspector_placement, initial.inspector_placement)
      |> assign(:inspector_fraction, initial.inspector_fraction)
      |> assign(:cockpit_geometry, initial.cockpit_geometry)
      |> assign(:preview_panes, %{})
      |> assign(:feature_panes, %{})
      |> assign(:tmux_session, nil)
      |> assign(:tmux_panes, [])
      |> assign(:tmux_active_pane_id, nil)
      |> assign(:terminal_surface_pane_id, nil)
      |> assign(:run_ledger, [])
      |> assign(:selected_run_id, nil)
      |> assign(:selected_run_summary, nil)
      |> assign(:selected_run_timeline, [])
      |> assign(:selected_run_artifacts, [])
      |> assign(:selected_run_failure_reason, nil)
      |> assign(:selected_run_can_retry, false)
      |> assign(:active_run, nil)
      |> put_in([Access.key(:assigns), Access.key(:flash, %{})], %{})

    if Keyword.get(opts, :tmux, false) do
      socket
      |> assign(:tmux_session, "casein_ws-run-insp_main")
      |> assign(:tmux_active_pane_id, "%1")
      |> assign(:terminal_surface_pane_id, "%1")
      |> assign(:tmux_panes, [%{id: "%1"}])
    else
      socket
    end
  end
end
