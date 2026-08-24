defmodule Casein.Agents.TerminalToolsTuiSurfaceTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Terminals.Tmux

  @agents_view_excerpt """
  Agents
  Background sessions

  describe a task for a new session
  """

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes),
      fake_tmux_scrollback: TmuxCtl.Test.FakeState.get(:fake_tmux_scrollback),
      fake_tmux_test_pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid)
    }

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)
    end)

    :ok
  end

  test "paste into agents view is refused and does not write" do
    session = agent_session!(@agents_view_excerpt)

    assert {:error, error} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "text" => "implement the brief",
               "submit" => true,
               "confirm" => false
             })

    assert error.error == :non_conversation_surface
    assert error.refused
    assert error.surface == "agents_view"
    assert error.pane == "%9"
    assert error.escape_hatch == "allow_non_conversation"
    assert error.message =~ "agents view"
    refute_receive {:fake_tmux_paste_text, _, _, _, _}
  end

  test "send_command into agents view is refused and does not write" do
    session = agent_session!(@agents_view_excerpt)

    assert {:error, error} =
             TerminalTools.invoke("terminal_send_command", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "command" => "implement the brief",
               "confirm" => false
             })

    assert error.error == :non_conversation_surface
    assert error.surface == "agents_view"
    refute_receive {:fake_tmux_send_command, _, _, _, _}
  end

  test "allow_non_conversation pastes into agents view but submitted stays false" do
    session = agent_session!(@agents_view_excerpt)

    assert {:ok, result} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "text" => "implement the brief",
               "submit" => true,
               "confirm" => false,
               "allow_non_conversation" => true
             })

    assert result.status == "sent"
    assert result.surface == "agents_view"
    assert result.receipt.surface == "agents_view"
    refute result[:submitted]
    assert_receive {:fake_tmux_paste_text, ^session, "%9", "implement the brief", _}
  end

  test "conversation paste still sends and names the surface on the receipt" do
    session = agent_session!("# Casein agent pane\n")

    assert {:ok, result} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "text" => "fleet brief",
               "submit" => true,
               "confirm" => false
             })

    assert result.status == "sent"
    assert result.surface == "unknown"
    assert result.receipt.surface == "unknown"
    assert_receive {:fake_tmux_paste_text, ^session, "%9", "fleet brief", _}
  end

  test "busy conversation footer is named conversation and allowed" do
    session = agent_session!("working\nesc to interrupt")

    assert {:ok, result} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "text" => "follow up",
               "confirm" => false
             })

    assert result.surface == "conversation"
    assert result.receipt.surface == "conversation"
    assert_receive {:fake_tmux_paste_text, ^session, "%9", "follow up", _}
  end

  defp agent_session!(excerpt) do
    session = Tmux.session_name("alpha", "tui-surface")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 10}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%9", window_id: "@1", index: 0, active: true, current_command: "claude"}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%9"} => excerpt
    })

    session
  end
end
