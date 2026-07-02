defmodule DevIDE.Terminals.ModePolicyTest do
  # async: false — toggles the global :raw_terminal_everywhere app env.
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.ModePolicy
  alias DevIDE.Terminals.Session.Info

  describe "raw_terminal_allowed?/2" do
    test "defaults to local manual workspace access only" do
      assert ModePolicy.raw_terminal_allowed?(:manual, "local")
      assert ModePolicy.raw_terminal_allowed?(:manual, "localhost")
      refute ModePolicy.raw_terminal_allowed?(:review, "local")
      refute ModePolicy.raw_terminal_allowed?(:manual, "remote-host")
      refute ModePolicy.raw_terminal_allowed?(:agent_write_locked, "remote-host")
      refute ModePolicy.raw_terminal_allowed?(:shared_stage_guarded, "stage-host")
      refute ModePolicy.raw_terminal_allowed?(nil, nil)
    end

    test "honors explicit raw everywhere opt-in" do
      with_raw_everywhere(true, fn ->
        assert ModePolicy.raw_terminal_allowed?(:manual, "local")
        assert ModePolicy.raw_terminal_allowed?(:review, "remote-host")
        assert ModePolicy.raw_terminal_allowed?(:agent_write_locked, "remote-host")
        assert ModePolicy.raw_terminal_allowed?(:shared_stage_guarded, "stage-host")
        assert ModePolicy.raw_terminal_allowed?(nil, nil)
      end)
    end

    test "honors explicit disabled raw everywhere config" do
      with_raw_everywhere(false, fn ->
        assert ModePolicy.raw_terminal_allowed?(:manual, "local")
        refute ModePolicy.raw_terminal_allowed?(:review, "remote-host")
      end)
    end
  end

  describe "mode resolution is raw-only" do
    test "initial_mode/2 is always raw" do
      assert ModePolicy.initial_mode(:manual, "local") == :raw
      assert ModePolicy.initial_mode(:review, "local") == :raw
      assert ModePolicy.initial_mode(nil, nil) == :raw
    end

    test "session_switch_mode/3 is always raw for every kind/loc" do
      agent = Info.new_agent("agent-1", workspace_id: "ws")
      remote_agent = %{agent | loc: :remote}
      shell = Info.new_shell("ws", "u-1")
      remote_shell = %{shell | loc: :remote}

      assert ModePolicy.session_switch_mode(agent, :review, "remote") == :raw
      assert ModePolicy.session_switch_mode(remote_agent, :review, "remote") == :raw
      assert ModePolicy.session_switch_mode(shell, :review, "elsewhere") == :raw
      assert ModePolicy.session_switch_mode(remote_shell, :manual, "local") == :raw
    end

    test "attachment_mode/2 is always raw regardless of kind or request" do
      agent = Info.new_agent("agent-2", workspace_id: "ws")
      shell = Info.new_shell("ws", "u-2")

      assert ModePolicy.attachment_mode(agent, :raw) == {:ok, :raw}
      assert ModePolicy.attachment_mode(shell, :raw) == {:ok, :raw}
    end
  end

  describe "tmux_mutations_enabled?/1" do
    test "only shell sessions may mutate tmux layout" do
      assert ModePolicy.tmux_mutations_enabled?(:shell)
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
