defmodule DevIDE.Terminals.ActivityTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.Activity

  @now 1_800_000_000

  defp window(attrs) do
    Map.merge(%{current_command: "claude", activity: @now - 120}, Map.new(attrs))
  end

  describe "agent_window_quiet?/2" do
    test "true for an agent window silent past the threshold" do
      assert Activity.agent_window_quiet?(window([]), @now)
    end

    test "false while the agent is still producing output" do
      refute Activity.agent_window_quiet?(window(activity: @now - 10), @now)
    end

    test "false once silence is stale (outside the attention window)" do
      refute Activity.agent_window_quiet?(window(activity: @now - 7_200), @now)
    end

    test "false for non-agent commands regardless of silence" do
      refute Activity.agent_window_quiet?(window(current_command: "bash"), @now)
    end

    test "false without a usable activity timestamp" do
      refute Activity.agent_window_quiet?(window(activity: nil), @now)
      refute Activity.agent_window_quiet?(window(activity: 0), @now)
      refute Activity.agent_window_quiet?(window(activity: "junk"), @now)
    end

    test "accepts string keys and string timestamps" do
      raw = %{"current_command" => "opencode", "activity" => Integer.to_string(@now - 120)}
      assert Activity.agent_window_quiet?(raw, @now)
    end
  end

  describe "agent_command?/1" do
    test "matches the boundary's interactive command ids" do
      assert Activity.agent_command?("claude")
      assert Activity.agent_command?("codex")
      refute Activity.agent_command?("bash")
      refute Activity.agent_command?(nil)
    end
  end
end
