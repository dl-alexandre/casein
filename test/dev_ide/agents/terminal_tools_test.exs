defmodule DevIDE.Agents.TerminalToolsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.TerminalTools
  alias DevIDE.Terminals.Tmux

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:dev_ide, :tmux_adapter),
      fake_tmux_windows: Application.get_env(:dev_ide, :fake_tmux_windows),
      fake_tmux_panes: Application.get_env(:dev_ide, :fake_tmux_panes),
      fake_tmux_scrollback: Application.get_env(:dev_ide, :fake_tmux_scrollback),
      fake_tmux_test_pid: Application.get_env(:dev_ide, :fake_tmux_test_pid)
    }

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:dev_ide, key),
          else: Application.put_env(:dev_ide, key, value)
      end
    end)

    :ok
  end

  test "workspace_id scopes session listing" do
    prefix = Tmux.workspace_session_prefix("alpha")

    assert {:ok, %{sessions: sessions}} =
             TerminalTools.list_sessions(%{"workspace_id" => "alpha"})

    assert Enum.all?(sessions, &String.starts_with?(&1.session, prefix))
  end

  test "workspace_id rejects mismatched session" do
    assert {:error, :workspace_mismatch} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => "alpha",
               "session" => "devide_other_u-dev"
             })
  end

  test "definitions include workspace_id on every tool" do
    for tool <- TerminalTools.definitions() do
      assert Map.has_key?(tool.parameters.properties, :workspace_id)
    end
  end

  test "list_sessions omits workspace_id when it was not supplied" do
    assert {:ok, result} = TerminalTools.list_sessions(%{})
    refute Map.has_key?(result, :workspace_id)
  end

  test "agent pane shortcuts target only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :fake_tmux_test_pid, self())

    Application.put_env(:dev_ide, :fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "work",
          active: true,
          panes: 3,
          activity: 10,
          current_command: "bash"
        }
      ]
    })

    Application.put_env(:dev_ide, :fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          left: 80,
          top: 0,
          width: 80,
          height: 20,
          current_command: "bash",
          current_path: "/workspace"
        },
        %{
          id: "%3",
          window_id: "@1",
          index: 2,
          active: false,
          left: 80,
          top: 20,
          width: 80,
          height: 20,
          current_command: "git",
          current_path: "/workspace"
        }
      ]
    })

    Application.put_env(:dev_ide, :fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok, %{session: ^session, pane: "%2"}} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})

    assert {:ok, %{target: "%2", status: "sent"}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "command" => "mix test"
             })

    assert_receive {:fake_tmux_send_command, ^session, "%2", "mix test", _opts}
  end
end
