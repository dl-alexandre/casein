defmodule Casein.Terminals.CleanExecTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.CleanExec

  describe "wrap_argv/1 — non-tmux execs are scrubbed" do
    test "wraps a bare shell exec in the fd-closing /bin/sh wrapper" do
      assert ["/bin/sh", "-c", script, "casein-clean-exec", "bash", "-l"] =
               CleanExec.wrap_argv(["bash", "-l"])

      assert script =~ "exec \"$@\""
      assert script =~ "/proc/$$/fd/"
    end

    test "wraps an env-prefixed non-tmux exec" do
      assert ["/bin/sh", "-c", _script, "casein-clean-exec", "env", "FOO=1", "bash", "-l"] =
               CleanExec.wrap_argv(["env", "FOO=1", "bash", "-l"])
    end
  end

  describe "wrap_argv/1 — tmux is exempt (passthrough)" do
    # Pre-closing inherited fds before `exec tmux new-session` breaks the
    # foreground attach (client exits 0 -> "Terminal exited 0"). tmux
    # self-daemonizes, so it must NOT be wrapped.

    test "passes a bare tmux invocation through untouched" do
      argv = ["tmux", "new-session", "-A", "-s", "x"]
      assert CleanExec.wrap_argv(argv) == argv
    end

    test "passes an env-prefixed tmux invocation through untouched" do
      argv = ["env", "TERM=xterm-256color", "tmux", "new-session", "-A", "-s", "x"]
      assert CleanExec.wrap_argv(argv) == argv
    end

    test "passes a docker-compose-exec-wrapped tmux invocation through untouched" do
      argv = ["docker", "compose", "exec", "app", "tmux", "new-session", "-A"]
      assert CleanExec.wrap_argv(argv) == argv
    end

    test "recognizes tmux by basename when resolved to an absolute path" do
      # A resolved absolute path must still be detected, otherwise the wrapper
      # would re-break the pane.
      argv = ["env", "TERM=xterm-256color", "/usr/bin/tmux", "new-session", "-A"]
      assert CleanExec.wrap_argv(argv) == argv
    end
  end
end
