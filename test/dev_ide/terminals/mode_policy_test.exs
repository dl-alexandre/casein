defmodule DevIDE.Terminals.ModePolicyTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.ModePolicy
  alias DevIDE.Terminals.Session.Info

  describe "raw_terminal_allowed?/2" do
    test "allows raw only in manual mode on a local host" do
      assert ModePolicy.raw_terminal_allowed?(:manual, "local")
      assert ModePolicy.raw_terminal_allowed?(:manual, "localhost")
      assert ModePolicy.raw_terminal_allowed?(:manual, "")

      refute ModePolicy.raw_terminal_allowed?(:manual, "remote-host")
      refute ModePolicy.raw_terminal_allowed?(:review, "local")
      refute ModePolicy.raw_terminal_allowed?(:agent_write_locked, "local")
      refute ModePolicy.raw_terminal_allowed?(:shared_stage_guarded, "local")
      refute ModePolicy.raw_terminal_allowed?(nil, "local")
      refute ModePolicy.raw_terminal_allowed?(:manual, nil)
    end
  end

  describe "initial_mode/2" do
    test "raw when allowed, governed otherwise" do
      assert ModePolicy.initial_mode(:manual, "local") == :raw
      assert ModePolicy.initial_mode(:review, "local") == :governed
      assert ModePolicy.initial_mode(:manual, "other") == :governed
    end
  end

  describe "session_switch_mode/3" do
    test "executions and agents are always governed" do
      exec = Info.new_execution("ex-1", "tmux-ex-1", workspace_id: "ws", loc: :local)
      agent = Info.new_agent("agent-1", workspace_id: "ws")

      assert ModePolicy.session_switch_mode(exec, :manual, "local") == :governed
      assert ModePolicy.session_switch_mode(agent, :manual, "local") == :governed
    end

    test "remote shells are always governed" do
      shell = %{Info.new_shell("ws", "u-1") | loc: :remote}

      assert ModePolicy.session_switch_mode(shell, :manual, "local") == :governed
    end

    test "local shells follow the workspace raw policy" do
      shell = Info.new_shell("ws", "u-1")

      assert ModePolicy.session_switch_mode(shell, :manual, "local") == :raw
      assert ModePolicy.session_switch_mode(shell, :review, "local") == :governed
      assert ModePolicy.session_switch_mode(shell, :manual, "elsewhere") == :governed
    end
  end

  describe "attachment_mode/2" do
    test "executions are governed regardless of request" do
      exec = Info.new_execution("ex-2", "tmux-ex-2", workspace_id: "ws", loc: :local)

      assert ModePolicy.attachment_mode(exec, :raw) == {:ok, :governed}
      assert ModePolicy.attachment_mode(exec, :governed) == {:ok, :governed}
    end

    test "shells honor the requested mode" do
      shell = Info.new_shell("ws", "u-2")

      assert ModePolicy.attachment_mode(shell, :raw) == {:ok, :raw}
      assert ModePolicy.attachment_mode(shell, :governed) == {:ok, :governed}
    end
  end

  describe "tmux_mutations_enabled?/1" do
    test "only shell sessions may mutate tmux layout" do
      assert ModePolicy.tmux_mutations_enabled?(:shell)
      refute ModePolicy.tmux_mutations_enabled?(:execution)
      refute ModePolicy.tmux_mutations_enabled?(:agent)
      refute ModePolicy.tmux_mutations_enabled?(nil)
    end
  end
end
