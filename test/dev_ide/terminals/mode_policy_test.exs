defmodule DevIDE.Terminals.ModePolicyTest do
  # async: false — toggles the global :raw_terminal_everywhere app env.
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.ModePolicy
  alias DevIDE.Terminals.Session.Info

  describe "raw_terminal_allowed?/2" do
    test "allows raw from any workspace, mode, and host by default" do
      assert ModePolicy.raw_terminal_allowed?(:manual, "local")
      assert ModePolicy.raw_terminal_allowed?(:review, "remote-host")
      assert ModePolicy.raw_terminal_allowed?(:agent_write_locked, "remote-host")
      assert ModePolicy.raw_terminal_allowed?(:shared_stage_guarded, "stage-host")
      assert ModePolicy.raw_terminal_allowed?(nil, nil)
    end

    test "re-tightens to manual-mode-on-local-host when the flag is disabled" do
      with_raw_everywhere(false, fn ->
        assert ModePolicy.raw_terminal_allowed?(:manual, "local")
        assert ModePolicy.raw_terminal_allowed?(:manual, "localhost")
        assert ModePolicy.raw_terminal_allowed?(:manual, "")

        refute ModePolicy.raw_terminal_allowed?(:manual, "remote-host")
        refute ModePolicy.raw_terminal_allowed?(:review, "local")
        refute ModePolicy.raw_terminal_allowed?(nil, "local")
        refute ModePolicy.raw_terminal_allowed?(:manual, nil)
      end)
    end
  end

  describe "initial_mode/2" do
    test "boots raw only in manual mode on a local host, governed otherwise" do
      # Boot mode is independent of raw availability: terminals start governed
      # everywhere except a manual local workspace, even though raw is now
      # reachable everywhere via escalation.
      assert ModePolicy.initial_mode(:manual, "local") == :raw
      assert ModePolicy.initial_mode(:review, "local") == :governed
      assert ModePolicy.initial_mode(:manual, "other") == :governed
      assert ModePolicy.initial_mode(:review, "remote") == :governed
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

    test "local shells boot raw only for a manual local workspace" do
      shell = Info.new_shell("ws", "u-1")

      # Session-switch boot mode tracks raw_default?/2 (manual + local), not
      # raw availability — so review/remote shells stay governed by default.
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

  defp with_raw_everywhere(value, fun) do
    prev = Application.get_env(:dev_ide, :raw_terminal_everywhere)
    Application.put_env(:dev_ide, :raw_terminal_everywhere, value)

    try do
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:dev_ide, :raw_terminal_everywhere)
        _ -> Application.put_env(:dev_ide, :raw_terminal_everywhere, prev)
      end
    end
  end
end
