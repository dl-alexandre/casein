defmodule DevIdeWeb.WorkspaceLive.Show.TerminalStateQuietTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{live_temp: %{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-1", name: "workspace"},
            default_terminal_sid: "u-dev",
            tmux_session: "other-session"
          },
          assigns
        )
    }
  end

  defp tab(window) do
    SessionInfo.new_shell("ws-1", "u-agent",
      metadata: %{
        windows: [window]
      }
    )
    |> Map.put(:tmux_session, "tmux-agent")
  end

  test "cold ready windows do not push quiet OS notifications" do
    ready_window = %{
      id: "@1",
      index: 0,
      name: "claude",
      active: true,
      quiet: true,
      pane_state: :ready
    }

    socket =
      socket(%{quiet_window_ids: MapSet.new(), quiet_window_entries: %{}})
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert socket.assigns.quiet_window_ids == MapSet.new([{"u-agent", "@1"}])
    assert socket.private.live_temp[:push_events] in [nil, []]
  end

  test "working then ready pushes one quiet OS notification" do
    working_window = %{
      id: "@1",
      index: 0,
      name: "claude",
      active: true,
      quiet: false,
      pane_state: :working
    }

    ready_window = %{working_window | quiet: true, pane_state: :ready}

    socket =
      socket(%{quiet_window_ids: MapSet.new(), quiet_window_entries: %{}})
      |> TerminalState.assign_session_tabs([tab(working_window)])
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert [["devide:agent_quiet", payload]] = socket.private.live_temp.push_events
    assert payload.session_id == "u-agent"
    assert payload.window_id == "@1"
    assert payload.workspace == "workspace"
  end
end
