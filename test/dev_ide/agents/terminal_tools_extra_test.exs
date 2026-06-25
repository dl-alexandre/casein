defmodule DevIDE.Agents.TerminalToolsExtraTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.TerminalTools
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:dev_ide, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes),
      fake_tmux_scrollback: TmuxCtl.Test.FakeState.get(:fake_tmux_scrollback),
      fake_tmux_test_pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid),
      terminal_command_policy: Application.get_env(:dev_ide, :terminal_command_policy),
      env_command_policy: System.get_env("DEV_IDE_TERMINAL_COMMAND_POLICY")
    }

    MemoryAdapter.clear()
    Runtimes.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:dev_ide, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:dev_ide, :tmux_adapter)

      restore_app_env(:terminal_command_policy, previous.terminal_command_policy)
      restore_system_env("DEV_IDE_TERMINAL_COMMAND_POLICY", previous.env_command_policy)

      MemoryAdapter.clear()
      Runtimes.clear()
      DevIDE.Audit.MemoryAdapter.clear()
    end)

    :ok
  end

  # ---- dispatch / invoke ----

  test "invoke returns unknown_tool for an unrecognized tool name" do
    assert {:error, :unknown_tool} =
             TerminalTools.invoke("terminal_does_not_exist", %{"workspace_id" => "alpha"})
  end

  # ---- session validation branches ----

  test "topology rejects a session without the devide_ prefix" do
    assert {:error, :unscoped_session} =
             TerminalTools.invoke("terminal_topology", %{"session" => "plain-session"})
  end

  test "topology rejects a missing session argument" do
    assert {:error, {:missing_argument, "session"}} =
             TerminalTools.invoke("terminal_topology", %{})
  end

  test "topology rejects a devide_ session that does not exist" do
    fake_adapter()
    # A devide_-prefixed session that is not present in fake windows is not alive.
    assert {:error, :no_such_session} =
             TerminalTools.invoke("terminal_topology", %{
               "session" => "devide_ghost_main"
             })
  end

  test "topology returns a snapshot for an existing session" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:ok, snapshot} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => "alpha",
               "session" => session
             })

    assert is_map(snapshot)
  end

  # ---- default-session selection branches ----

  test "agent_pane with no workspace sessions reports no_workspace_sessions" do
    fake_adapter()
    # No fake windows seeded -> sessions_for/1 is empty.
    assert {:error, :no_workspace_sessions} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})
  end

  # ---- pane targeting branches (target_arg) ----

  test "capture rejects a pane id that is not in the session" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [%{id: "%1", window_id: "@1", index: 0, active: true}]
    })

    assert {:error, :pane_not_in_session} =
             TerminalTools.invoke("terminal_capture", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%99"
             })
  end

  test "capture rejects a non-string pane argument" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, :invalid_pane} =
             TerminalTools.invoke("terminal_capture", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => 7
             })
  end

  test "capture targets an explicit pane and tails lines with ansi preserved" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true},
        %{id: "%2", window_id: "@1", index: 1, active: false}
      ]
    })

    # capture/1 calls capture_scrollback(target, opts) with the pane id as the
    # first positional arg, so the fake resolves the {target, target} / bare-id key.
    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      "%2" => "\e[31mred\e[0m\n"
    })

    assert {:ok, %{session: ^session, target: "%2", output: output}} =
             TerminalTools.invoke("terminal_capture", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%2",
               "lines" => 10,
               "ansi" => true
             })

    # ansi: true keeps the escape sequences in the formatted output.
    assert output =~ "\e[31m"
  end

  # ---- list_sessions contains filter ----

  test "list_sessions filters by the contains substring" do
    fake_adapter()

    match = Tmux.session_name("alpha", "match-me")
    other = Tmux.session_name("alpha", "nope")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      match => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 1}],
      other => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 1}]
    })

    assert {:ok, %{sessions: sessions, workspace_id: "alpha"}} =
             TerminalTools.list_sessions(%{"workspace_id" => "alpha", "contains" => "match-me"})

    names = Enum.map(sessions, & &1.session)
    assert match in names
    refute other in names
  end

  # ---- missing string-argument branches ----

  test "send_keys requires the keys argument" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, {:missing_argument, "keys"}} =
             TerminalTools.invoke("terminal_send_keys", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  test "send_command requires the command argument" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, {:missing_argument, "command"}} =
             TerminalTools.invoke("terminal_send_command", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  # ---- happy paths for send_keys / send_command on the default (active) pane ----

  test "send_command sends to the active pane and reports sent" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:ok, %{session: ^session, target: ^session, status: "sent"}} =
             TerminalTools.invoke("terminal_send_command", %{
               "workspace_id" => "alpha",
               "session" => session,
               "command" => "ls"
             })

    assert_receive {:fake_tmux_send_command, ^session, ^session, "ls", _opts}
  end

  # ---- agent pane mutation happy paths (capture_agent / send_agent_keys) ----

  test "capture_agent reads scrollback from the marked agent pane" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"},
        %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "bash"}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\nhello\n"
    })

    assert {:ok, %{session: ^session, target: "%2", output: output}} =
             TerminalTools.invoke("terminal_capture_agent", %{
               "workspace_id" => "alpha",
               "session" => session
             })

    assert output =~ "hello"
  end

  test "send_agent_keys targets only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"},
        %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "bash"}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok, %{session: ^session, target: "%2", status: "sent"}} =
             TerminalTools.invoke("terminal_send_agent_keys", %{
               "workspace_id" => "alpha",
               "session" => session,
               "keys" => "Enter"
             })

    assert_receive {:fake_tmux_keys, ^session, "%2", "Enter", _opts}
  end

  test "send_agent_keys requires the keys argument before resolving the pane" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, {:missing_argument, "keys"}} =
             TerminalTools.invoke("terminal_send_agent_keys", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  # ---- report_worktree missing workspace_id ----

  test "report_worktree without a workspace_id returns workspace_id_required" do
    assert {:error, :workspace_id_required} =
             TerminalTools.invoke("terminal_report_worktree", %{
               "worktree_path" => "/tmp/some-worktree"
             })
  end

  # ---- set_agent_label argument branches ----

  test "set_agent_label without a workspace_id returns missing_workspace_id" do
    assert {:error, :missing_workspace_id} =
             TerminalTools.invoke("terminal_set_agent_label", %{"label" => "Working"})
  end

  test "set_agent_label rejects a pane id not in the session" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [%{id: "%1", window_id: "@1", index: 0, active: true}]
    })

    assert {:error, :invalid_pane} =
             TerminalTools.invoke("terminal_set_agent_label", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%does-not-exist",
               "label" => "Working"
             })
  end

  # ---- command policy gate (allowlist denial) ----

  test "send_command is blocked when an allowlist policy rejects the command" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    Application.put_env(:dev_ide, :terminal_command_policy, {:allowlist, ["^mix "]})

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, %{error: :command_blocked, reason: :not_allowlisted, command: "rm -rf /"}} =
             TerminalTools.invoke("terminal_send_command", %{
               "workspace_id" => "alpha",
               "session" => session,
               "command" => "rm -rf /"
             })
  end

  test "send_agent_command is blocked when a denylist policy matches the command" do
    session = Tmux.session_name("alpha", "main")
    fake_adapter()

    Application.put_env(:dev_ide, :terminal_command_policy, {:denylist, ["rm -rf"]})

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:error, %{error: :command_blocked, reason: :denylisted}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "session" => session,
               "command" => "rm -rf /tmp"
             })
  end

  defp fake_adapter do
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_app_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
