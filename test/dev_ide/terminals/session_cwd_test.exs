defmodule Casein.Terminals.SessionCwdTest do
  # Not tagged :pty — these are pure and must run in CI (the main session_test is
  # :pty and excluded). Guards the fix for the 2026-07-09 devbox incident where
  # host tmux panes inherited a reaped worktree cwd → `getcwd failed` shells.
  use ExUnit.Case, async: false

  alias Casein.Terminals.Session

  describe "safe_local_cwd/2" do
    test "honors the requested cwd when it exists" do
      assert Session.safe_local_cwd("/data/workspaces/dalexandre-devbox", fn _ -> true end) ==
               "/data/workspaces/dalexandre-devbox"
    end

    test "keeps valid host paths outside the workspaces root (scratch $HOME, agent worktrees)" do
      # Regression: host tmux must start in the real host directory, never the
      # manager's container exec workdir (/app), for paths that are not under
      # /data/workspaces — i.e. the scratch home PTY and /tmp agent worktrees.
      assert Session.safe_local_cwd("/home/devbox", fn _ -> true end) == "/home/devbox"

      assert Session.safe_local_cwd("/tmp/devide-agent-worktrees/w", fn _ -> true end) ==
               "/tmp/devide-agent-worktrees/w"
    end

    test "falls back to $HOME when the requested cwd was reaped" do
      prev = System.get_env("HOME")
      System.put_env("HOME", "/home/tester")

      on_exit(fn ->
        if prev, do: System.put_env("HOME", prev), else: System.delete_env("HOME")
      end)

      # cwd gone, $HOME present
      exists? = fn path -> path == "/home/tester" end

      assert Session.safe_local_cwd(
               "/tmp/devide-agent-worktrees/agent-grok-phase-a-arbiter-20260708012302",
               exists?
             ) == "/home/tester"
    end

    test "falls back to / when neither the cwd nor $HOME exist" do
      assert Session.safe_local_cwd("/gone", fn _ -> false end) == "/"
    end

    test "falls back to / for a nil/invalid cwd" do
      assert Session.safe_local_cwd(nil, fn _ -> false end) == "/"
    end
  end
end
