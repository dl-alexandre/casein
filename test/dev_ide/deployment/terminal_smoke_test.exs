defmodule DevIDE.Deployment.TerminalSmokeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Deployment.TerminalSmoke

  describe "proc_cwd_alive?/2" do
    test "true when the process exists and its cwd resolves" do
      stat = fn _ -> {:ok, %File.Stat{}} end
      assert TerminalSmoke.proc_cwd_alive?(1234, stat)
    end

    test "false when the process exists but its cwd was deleted (the incident)" do
      stat = fn
        "/proc/1234" -> {:ok, %File.Stat{}}
        "/proc/1234/cwd" -> {:error, :enoent}
      end

      refute TerminalSmoke.proc_cwd_alive?(1234, stat)
    end

    test "fails open (true) when /proc/<pid> is unavailable (non-Linux / gone)" do
      stat = fn _ -> {:error, :enoent} end
      assert TerminalSmoke.proc_cwd_alive?(1234, stat)
    end
  end

  describe "pane_cwd_alive?/2" do
    test "true when the pane path exists" do
      assert TerminalSmoke.pane_cwd_alive?("/home/devbox", fn _ -> true end)
    end

    test "false when the pane path does not exist" do
      refute TerminalSmoke.pane_cwd_alive?("/tmp/devide-agent-worktrees/reaped", fn _ -> false end)
    end

    test "false for a nil or empty pane path" do
      refute TerminalSmoke.pane_cwd_alive?(nil, fn _ -> true end)
      refute TerminalSmoke.pane_cwd_alive?("", fn _ -> true end)
    end
  end
end
