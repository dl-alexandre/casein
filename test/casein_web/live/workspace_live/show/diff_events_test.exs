defmodule CaseinWeb.WorkspaceLive.Show.DiffEventsTest do
  use Casein.TestCase, async: true

  import Phoenix.Component, only: [assign: 3]

  alias Casein.Cockpit.Inspectors
  alias Casein.CommandPalette.Actions
  alias Casein.Workspace
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.ActionAvailability, as: Avail
  alias CaseinWeb.WorkspaceLive.Show.DiffEvents
  alias CaseinWeb.WorkspaceLive.Show.InspectorEvents

  setup do
    root =
      Path.join(System.tmp_dir!(), "diff-events-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "palette entry resolves to diff:open_in_pane" do
    item = Enum.find(Actions.all(), &(&1.id == "diff:open_in_pane"))
    assert item
    assert item.payload.event == "diff:open_in_pane"
    assert "diff:open_in_pane" in Actions.allowed_events()
    assert "diff:open_in_pane" in Show.known_events()
  end

  test "availability rule always offers the palette item" do
    item = Enum.find(Actions.all(), &(&1.id == "diff:open_in_pane"))

    ctx =
      Avail.context(%{
        tmux_mutations_enabled?: false,
        tmux_session: nil,
        terminal_mode: :governed,
        tmux_panes: []
      })

    assert Avail.item_available?(item, ctx)
    assert Avail.available?("diff:open_in_pane", ctx)
  end

  test "diff:open_in_pane falls back to the full-area diff tab without tmux", %{root: root} do
    {:noreply, socket} =
      DiffEvents.handle_event("diff:open_in_pane", %{}, socket(root))

    assert socket.assigns.tab == "diff"
    refute Inspectors.diff_open?(socket.assigns.inspector_panes)
  end

  test "diff:open_in_pane with path focuses the file on the diff tab", %{root: root} do
    {:noreply, socket} =
      DiffEvents.handle_event(
        "diff:open_in_pane",
        %{"path" => "lib/foo.ex"},
        socket(root)
      )

    assert socket.assigns.tab == "diff"
    assert socket.assigns.open_file.path == "lib/foo.ex"
  end

  test "diff:open_in_pane opens a LiveView inspector when tmux context exists", %{root: root} do
    {:noreply, socket} =
      DiffEvents.handle_event(
        "diff:open_in_pane",
        %{"path" => "lib/foo.ex"},
        socket(root, tmux: true)
      )

    assert socket.assigns.tab == "terminal"
    assert Inspectors.diff_open?(socket.assigns.inspector_panes)
    assert Inspectors.primary_diff_path(socket.assigns.inspector_panes) == "lib/foo.ex"
  end

  test "inspector_open PubSub intent opens the diff tab with no tmux", %{root: root} do
    {:noreply, socket} =
      InspectorEvents.handle_info(
        {:inspector_open, %{kind: :diff, path: "lib/foo.ex"}},
        socket(root)
      )

    # Without tmux context the inspector open still lands on the socket-state
    # inspector list (request_open is viewer-local); the LiveView path for
    # human open falls back via diff:open_inspector. Agent broadcast always
    # goes through open_diff_inspector when kind is :diff.
    assert socket.assigns.tab == "terminal"
    assert Inspectors.diff_open?(socket.assigns.inspector_panes)
    assert Inspectors.primary_diff_path(socket.assigns.inspector_panes) == "lib/foo.ex"
  end

  defp socket(root, opts \\ []) do
    workspace = %Workspace{
      id: "ws-diff",
      name: "ws-diff",
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
      |> assign(:inspector_panes, initial.inspector_panes)
      |> assign(:inspector_placement, initial.inspector_placement)
      |> assign(:inspector_fraction, initial.inspector_fraction)
      |> assign(:cockpit_geometry, initial.cockpit_geometry)
      |> assign(:preview_panes, %{})
      |> assign(:feature_panes, %{})
      |> assign(:tmux_session, nil)
      |> assign(:tmux_panes, [])
      |> assign(:tmux_active_pane_id, nil)
      |> assign(:terminal_surface_pane_id, nil)
      |> put_in([Access.key(:assigns), Access.key(:flash, %{})], %{})

    if Keyword.get(opts, :tmux, false) do
      socket
      |> assign(:tmux_session, "casein_ws-diff_main")
      |> assign(:tmux_active_pane_id, "%1")
      |> assign(:terminal_surface_pane_id, "%1")
      |> assign(:tmux_panes, [%{id: "%1"}])
    else
      socket
    end
  end
end
