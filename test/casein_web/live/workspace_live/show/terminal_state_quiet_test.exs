defmodule CaseinWeb.WorkspaceLive.Show.TerminalStateQuietTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

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

  defp attach_transition_telemetry(context) do
    handler = "quiet-transition-test-#{context.test}"

    :ok =
      :telemetry.attach(
        handler,
        [:casein, :attention, :quiet_agent, :transition],
        fn event, measurements, metadata, pid ->
          send(pid, {:quiet_transition, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "cold ready windows do not push quiet OS notifications", context do
    attach_transition_telemetry(context)

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

    assert_receive {:quiet_transition, [:casein, :attention, :quiet_agent, :transition],
                    %{count: 1}, metadata}

    assert metadata.reaction == :inline
    assert metadata.reason == :cold_ready
    assert metadata.observed_working? == false
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

    assert [["casein:agent_quiet", payload]] = socket.private.live_temp.push_events
    assert payload.session_id == "u-agent"
    assert payload.window_id == "@1"
    assert payload.workspace == "workspace"
    assert payload.reaction == "notify"
    assert socket.assigns.unseen_quiet_window_ids == MapSet.new([{"u-agent", "@1"}])
  end

  test "focused current quiet window uses inline attention without OS notification" do
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
      socket(%{
        quiet_window_ids: MapSet.new(),
        quiet_window_entries: %{},
        attention_surface_state: :focused,
        terminal_sid: "u-agent",
        tmux_session: "tmux-agent",
        tmux_active_window_id: "@1"
      })
      |> TerminalState.assign_session_tabs([tab(working_window)])
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert socket.private.live_temp[:push_events] in [nil, []]
    assert socket.assigns.quiet_window_ids == MapSet.new([{"u-agent", "@1"}])
    assert socket.assigns.unseen_quiet_window_ids == MapSet.new()
  end

  test "focused workspace uses inline attention for background quiet windows" do
    working_window = %{
      id: "@1",
      index: 0,
      name: "claude",
      active: false,
      quiet: false,
      pane_state: :working
    }

    ready_window = %{working_window | quiet: true, pane_state: :ready}

    socket =
      socket(%{
        quiet_window_ids: MapSet.new(),
        quiet_window_entries: %{},
        attention_surface_state: :focused,
        terminal_sid: "u-agent",
        tmux_session: "tmux-agent",
        tmux_active_window_id: "@0"
      })
      |> TerminalState.assign_session_tabs([tab(working_window)])
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert socket.private.live_temp[:push_events] in [nil, []]
    assert socket.assigns.unseen_quiet_window_ids == MapSet.new([{"u-agent", "@1"}])
  end

  test "hidden workspace pushes a quiet OS notification", context do
    attach_transition_telemetry(context)

    working_window = %{
      id: "@1",
      index: 0,
      name: "claude",
      active: false,
      quiet: false,
      pane_state: :working
    }

    ready_window = %{working_window | quiet: true, pane_state: :ready}

    socket =
      socket(%{
        quiet_window_ids: MapSet.new(),
        quiet_window_entries: %{},
        attention_surface_state: :hidden
      })
      |> TerminalState.assign_session_tabs([tab(working_window)])
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert [["casein:agent_quiet", payload]] = socket.private.live_temp.push_events
    assert payload.reaction == "notify"

    assert_receive {:quiet_transition, [:casein, :attention, :quiet_agent, :transition],
                    %{count: 1}, metadata}

    assert metadata.reaction == :notify
    assert metadata.reason == :background_surface
    assert metadata.surface_state == :hidden
    assert metadata.target_state == :hidden
  end

  test "acknowledging a quiet window clears unseen state but keeps quiet chrome" do
    working_window = %{
      id: "@1",
      index: 0,
      name: "claude",
      active: false,
      quiet: false,
      pane_state: :working
    }

    ready_window = %{working_window | quiet: true, pane_state: :ready}

    socket =
      socket(%{
        quiet_window_ids: MapSet.new(),
        quiet_window_entries: %{},
        attention_surface_state: :focused,
        terminal_sid: "u-agent",
        tmux_session: "tmux-agent",
        tmux_active_window_id: "@0"
      })
      |> TerminalState.assign_session_tabs([tab(working_window)])
      |> TerminalState.assign_session_tabs([tab(ready_window)])

    assert socket.assigns.unseen_quiet_window_ids == MapSet.new([{"u-agent", "@1"}])

    assert %{unseen_quiet_count: 1, windows: [%{attention: "unseen"}]} =
             Enum.find(socket.assigns.session_tabs, &(&1.id == "u-agent"))

    socket = TerminalState.acknowledge_quiet_window(socket, "u-agent", "@1")

    assert socket.assigns.unseen_quiet_window_ids == MapSet.new()

    assert %{unseen_quiet_count: 0, windows: [%{quiet?: true, attention: "inline"}]} =
             Enum.find(socket.assigns.session_tabs, &(&1.id == "u-agent"))
  end
end
