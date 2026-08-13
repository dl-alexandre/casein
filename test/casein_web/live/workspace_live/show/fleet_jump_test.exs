defmodule CaseinWeb.WorkspaceLive.Show.FleetJumpTest do
  @moduledoc """
  `C-b a` / badge → next needs-you pane (#952).

  The cycle itself is pinned in `Casein.Terminals.FleetBoardTest`; this covers
  the wiring that makes the key reachable and the chrome that offers it.
  """
  use Casein.TestCase, async: true

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Casein.Terminals.FleetBoard
  alias CaseinWeb.WorkspaceLive.Show
  alias CaseinWeb.WorkspaceLive.Show.FleetEvents
  alias CaseinWeb.WorkspaceLive.Show.FleetPanel
  alias CaseinWeb.WorkspaceLive.Show.LeaderBindings
  alias CaseinWeb.WorkspaceLive.Show.LeaderHelp

  describe "the key reaches the handler" do
    test "C-b a dispatches jump-needs-you" do
      assert LeaderBindings.key_map()["a"] == "jump-needs-you"
      assert "jump-needs-you" in LeaderBindings.dispatch_actions()
      assert LeaderBindings.key_for_action("jump-needs-you") == "a"
    end

    test "the event is admitted by the authz gate" do
      # Show's @direct_events is an allowlist: an event missing from it is
      # silently denied and audited, which reads as "the key does nothing"
      # rather than "the allowlist is stale". Without this line the binding
      # dispatches, the button clicks, and nothing happens.
      assert "fleet:jump_needs_you" in Show.known_events()
    end

    test "the cheatsheet lists it so operators can discover it" do
      rows =
        LeaderBindings.groups()
        |> Enum.flat_map(& &1.rows)

      row = Enum.find(rows, &("jump-needs-you" in &1.actions))

      assert row, "jump-needs-you is not in any cheatsheet group"
      assert row.display == "a"
      assert row.desc =~ "needs you"

      html = render_component(&LeaderHelp.leader_help_overlay/1, %{open: true})
      assert html =~ "needs you"
    end
  end

  describe "handle_event/3" do
    test "a calm fleet is a no-op with a note, not a wrong jump" do
      {:noreply, socket} =
        FleetEvents.handle_event("fleet:jump_needs_you", %{}, socket(FleetBoard.empty()))

      assert socket.assigns.flash["info"] =~ "Nothing needs you"
      # No window selection was attempted: the active window is untouched.
      assert socket.assigns.tmux_active_window_id == nil
    end

    test "a board with no needs-you rows is equally a no-op" do
      board =
        FleetBoard.from_window_tabs(
          [
            %{
              id: "w1",
              name: "w1",
              display_name: "w1",
              agent_state: :working,
              quiet?: false,
              unseen_quiet?: false,
              active?: false,
              agent_pane_id: "%1"
            }
          ],
          gate_queue: gate_free()
        )

      assert board.total == 1
      assert FleetBoard.needs_you_rows(board) == []

      {:noreply, socket} =
        FleetEvents.handle_event("fleet:jump_needs_you", %{}, socket(board))

      assert socket.assigns.flash["info"] =~ "Nothing needs you"
    end
  end

  describe "the badge is a jump target without losing the drawer" do
    test "attention splits the pill into jump and drawer halves" do
      html = render_component(&FleetPanel.fleet_badge/1, %{board: attention_board(), open: false})

      assert html =~ ~s(id="fleet-badge-jump")
      assert html =~ ~s(phx-click="fleet:jump_needs_you")
      assert html =~ "need you"

      # #952 scope 2: the drawer must stay reachable by click.
      assert html =~ ~s(id="fleet-badge-drawer")
      assert html =~ ~s(phx-click="fleet_drawer:toggle")
      assert html =~ "fleet"
    end

    test "a calm fleet offers only the drawer, as before" do
      html =
        render_component(&FleetPanel.fleet_badge/1, %{board: FleetBoard.empty(), open: false})

      refute html =~ ~s(id="fleet-badge-jump")
      assert html =~ ~s(phx-click="fleet_drawer:toggle")
    end
  end

  defp attention_board do
    FleetBoard.from_window_tabs(
      [
        %{
          id: "w-blocked",
          name: "blocked-worker",
          display_name: "blocked-worker",
          agent_state: :blocked,
          quiet?: false,
          unseen_quiet?: false,
          active?: false,
          agent_pane_id: "%1"
        }
      ],
      gate_queue: gate_free()
    )
  end

  defp gate_free do
    %{
      lock_state: :free,
      depth: 0,
      waiter_count: 0,
      holder: nil,
      waiters: [],
      observed_at: nil,
      lock_path: "/tmp/casein-pr-gate.lock",
      source: :proc
    }
  end

  defp socket(board) do
    %Phoenix.LiveView.Socket{}
    |> assign(:fleet_board, board)
    |> assign(:fleet_drawer_open, false)
    |> assign(:tmux_active_window_id, nil)
    |> put_in([Access.key(:assigns), Access.key(:flash, %{})], %{})
  end
end
