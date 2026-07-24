defmodule CaseinWeb.WorkspaceLive.Show.PaneLayoutEventsTest do
  use Casein.TestCase, async: true

  alias CaseinWeb.WorkspaceLive.Show.PaneLayoutEvents

  # Pure / no-op branches only: missing tmux session, missing pane data, empty
  # ghostty snapshot, already-zoomed mobile focus.
  # SKIPPED (TmuxCtl adapter / TerminalState / Terminals / Audit / Show.raw_terminal):
  # split_right, split_down, successful close/zoom/equalize/cycle paths,
  # pane:focus_next/previous (delegate into TerminalEvents → navigate_pane),
  # ghostty:snapshot with a live pid, snapshot_all with live terms.

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            focused_pane_id: "p1",
            pane_data: %{},
            workspace: %{id: "ws-pane-#{System.unique_integer([:positive])}"}
          },
          assigns
        ),
      private: %{live_temp: %{}}
    }
  end

  defp pushed_events(socket) do
    socket.private[:live_temp][:push_events] || Map.get(socket.private, :push_events, []) || []
  end

  test "pane:close_focused is a no-op without a tmux session" do
    s = socket(%{tmux_session: nil, tmux_active_pane_id: "%1"})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:close_focused", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "pane:close_others is a no-op without a tmux session" do
    s = socket(%{tmux_session: nil, tmux_active_pane_id: "%1"})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:close_others", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "pane:close_others is a no-op without an active pane id" do
    s = socket(%{tmux_session: "sess", tmux_active_pane_id: nil})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:close_others", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "equalize_layout is a no-op without a tmux session" do
    s = socket(%{tmux_session: nil})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("equalize_layout", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "pane:cycle_layout is a no-op without a tmux session" do
    s = socket(%{tmux_session: nil})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:cycle_layout", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "pane:zoom_focused is a no-op without a tmux session" do
    s = socket(%{tmux_session: nil, tmux_active_pane_id: "%1"})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:zoom_focused", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "pane:zoom_focused requests a client transition before mutating tmux" do
    s =
      socket(%{
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

  test "pane:commit_zoom rejects an invalid layout version before reading tmux" do
    s =
      socket(%{
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true
      })

    assert {:reply, %{ok: false, error: "invalid_layout_version"}, _socket} =
             PaneLayoutEvents.handle_event(
               "pane:commit_zoom",
               %{"pane_id" => "%1", "base_layout_version" => "bad"},
               s
             )
  end

  test "pane swap requests identify the active pane, direction, and layout version" do
    s =
      socket(%{
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true,
        tmux_topology_layout_version: 42
      })

    for {event, direction} <- [{"pane:swap_previous", "U"}, {"pane:swap_next", "D"}] do
      assert {:noreply, updated} = PaneLayoutEvents.handle_event(event, %{}, s)

      assert Enum.any?(pushed_events(updated), fn
               ["tmux:swap_transition_requested", payload] ->
                 payload == %{pane_id: "%1", direction: direction, layout_version: 42}

               {_, "tmux:swap_transition_requested", payload} ->
                 payload == %{pane_id: "%1", direction: direction, layout_version: 42}

               _ ->
                 false
             end)
    end
  end

  test "pane:commit_swap rejects invalid direction and layout version before reading tmux" do
    s =
      socket(%{
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true
      })

    assert {:reply, %{ok: false, error: "invalid_direction"}, _socket} =
             PaneLayoutEvents.handle_event(
               "pane:commit_swap",
               %{"pane_id" => "%1", "direction" => "left", "base_layout_version" => "1"},
               s
             )

    assert {:reply, %{ok: false, error: "invalid_layout_version"}, _socket} =
             PaneLayoutEvents.handle_event(
               "pane:commit_swap",
               %{"pane_id" => "%1", "direction" => "U", "base_layout_version" => "bad"},
               s
             )
  end

  test "tmux:split_pane requests a client transition with its explicit target" do
    s =
      socket(%{
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true,
        tmux_topology_layout_version: 42
      })

    assert {:noreply, updated} =
             PaneLayoutEvents.handle_event(
               "tmux:split_pane",
               %{"pane-id" => "%7", "direction" => "v"},
               s
             )

    assert Enum.any?(pushed_events(updated), fn
             ["tmux:split_transition_requested", payload] ->
               payload == %{pane_id: "%7", direction: "v", layout_version: 42}

             {_, "tmux:split_transition_requested", payload} ->
               payload == %{pane_id: "%7", direction: "v", layout_version: 42}

             _ ->
               false
           end)
  end

  test "pane:commit_split rejects invalid direction and layout version before reading tmux" do
    s =
      socket(%{
        tmux_session: "sess",
        tmux_active_pane_id: "%1",
        tmux_mutations_enabled?: true
      })

    assert {:reply, %{ok: false, error: "invalid_direction"}, _socket} =
             PaneLayoutEvents.handle_event(
               "pane:commit_split",
               %{"pane_id" => "%1", "direction" => "right", "base_layout_version" => "1"},
               s
             )

    assert {:reply, %{ok: false, error: "invalid_layout_version"}, _socket} =
             PaneLayoutEvents.handle_event(
               "pane:commit_split",
               %{"pane_id" => "%1", "direction" => "h", "base_layout_version" => "bad"},
               s
             )
  end

  test "pane:ensure_focus_zoom is a no-op when already window-zoomed" do
    s = socket(%{window_zoomed?: true, tmux_session: "sess", tmux_active_pane_id: "%1"})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:ensure_focus_zoom", %{}, s)
    assert s2.assigns.window_zoomed? == true
    assert s2.assigns == s.assigns
  end

  test "pane:ensure_focus_zoom is a no-op without a tmux session" do
    s = socket(%{window_zoomed?: false, tmux_session: nil, tmux_active_pane_id: "%1"})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("pane:ensure_focus_zoom", %{}, s)
    assert s2.assigns == s.assigns
  end

  test "retry_pane is a no-op when the pane id is unknown" do
    s = socket(%{pane_data: %{}})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("retry_pane", %{"pane-id" => "gone"}, s)
    assert s2.assigns == s.assigns
  end

  test "nav:dir is a no-op without a tmux session for each cardinal direction" do
    s = socket(%{tmux_session: nil})

    for dir <- ["left", "right", "up", "down"] do
      assert {:noreply, s2} = PaneLayoutEvents.handle_event("nav:dir", %{"dir" => dir}, s)
      assert s2.assigns == s.assigns
    end
  end

  test "nav:dir with a non-cardinal dir raises FunctionClauseError" do
    s = socket(%{tmux_session: nil})

    assert_raise FunctionClauseError, fn ->
      PaneLayoutEvents.handle_event("nav:dir", %{"dir" => "diagonal"}, s)
    end
  end

  test "ghostty:snapshot without a live term pushes a no_terminal error event" do
    s =
      socket(%{
        focused_pane_id: "p1",
        pane_data: %{"p1" => %{ghostty_term: nil}}
      })

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("ghostty:snapshot", %{}, s)

    assert Enum.any?(pushed_events(s2), fn
             ["ghostty:snapshot:captured", %{"error" => "no_terminal"}] -> true
             {_, "ghostty:snapshot:captured", %{"error" => "no_terminal"}} -> true
             _ -> false
           end)
  end

  test "ghostty:snapshot without focused pane data pushes a no_terminal error event" do
    s = socket(%{focused_pane_id: "missing", pane_data: %{}})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("ghostty:snapshot", %{}, s)

    assert Enum.any?(pushed_events(s2), fn
             ["ghostty:snapshot:captured", %{"error" => "no_terminal"}] -> true
             {_, "ghostty:snapshot:captured", %{"error" => "no_terminal"}} -> true
             _ -> false
           end)
  end

  test "snapshot_all with no live ghostty pids flashes an empty-snapshot message" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    s =
      socket(%{
        pane_data: %{
          "p1" => %{ghostty_term: nil},
          "p2" => %{ghostty_term: dead}
        },
        current_user: %{id: "u1"}
      })

    assert {:noreply, s2} = PaneLayoutEvents.handle_event("snapshot_all", %{}, s)
    assert s2.assigns.flash["info"] == "No live Ghostty panes to snapshot"
  end

  test "snapshot_all with empty pane_data flashes the empty-snapshot message" do
    s = socket(%{pane_data: nil, current_user: %{id: "u1"}})
    assert {:noreply, s2} = PaneLayoutEvents.handle_event("snapshot_all", %{}, s)
    assert s2.assigns.flash["info"] == "No live Ghostty panes to snapshot"
  end
end
