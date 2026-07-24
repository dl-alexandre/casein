defmodule Casein.Deployment.TerminalSmokeTest do
  use ExUnit.Case, async: true

  alias Casein.Deployment.TerminalSmoke

  describe "proc_cwd_alive?/2" do
    test "true when the cwd symlink resolves to a live path" do
      read_link = fn "/proc/1234/cwd" -> {:ok, "/home/devbox"} end
      assert TerminalSmoke.proc_cwd_alive?(1234, read_link)
    end

    test "false when the cwd was deleted — kernel appends ' (deleted)' (the incident)" do
      # A held-open deleted dir still passes File.stat/File.dir?; only the
      # readlink suffix reveals it. This is the case the File.stat detector missed.
      read_link = fn "/proc/1234/cwd" ->
        {:ok, "/tmp/devide-agent-worktrees/agent-grok-phase-a-arbiter-20260708012302 (deleted)"}
      end

      refute TerminalSmoke.proc_cwd_alive?(1234, read_link)
    end

    test "fails open (true) when the link can't be read (non-Linux / process gone)" do
      read_link = fn _ -> {:error, :enoent} end
      assert TerminalSmoke.proc_cwd_alive?(1234, read_link)
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
