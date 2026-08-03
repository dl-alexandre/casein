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
        {:ok, "/tmp/casein-agent-worktrees/agent-grok-phase-a-arbiter-20260708012302 (deleted)"}
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
      refute TerminalSmoke.pane_cwd_alive?("/tmp/casein-agent-worktrees/reaped", fn _ -> false end)
    end

    test "false for a nil or empty pane path" do
      refute TerminalSmoke.pane_cwd_alive?(nil, fn _ -> true end)
      refute TerminalSmoke.pane_cwd_alive?("", fn _ -> true end)
    end
  end

  describe "pairing probe" do
    test "the typed probe command cannot match its own output marker" do
      # The capture contains the echoed command line as well as its output. If
      # the literal marker+`=` appeared in the command, every run would read as
      # hydrated and the check would be permanently green.
      probe = TerminalSmoke.pairing_probe()

      refute probe =~ "casein-pairing="
      assert TerminalSmoke.pairing_verdict(probe, "casein-pairing-1") == :unknown
    end

    test "hydrated when the probe printed the nonce" do
      capture = """
      $ printf '%s%s\\n' 'casein-pairing' "=${CASEIN_SMOKE_PAIRING:-MISSING}"
      casein-pairing=casein-pairing-42
      """

      assert TerminalSmoke.pairing_verdict(capture, "casein-pairing-42") == :hydrated
    end

    test "missing when the shell never picked the session variable up (the incident)" do
      capture = """
      $ printf '%s%s\\n' 'casein-pairing' "=${CASEIN_SMOKE_PAIRING:-MISSING}"
      casein-pairing=MISSING
      """

      assert TerminalSmoke.pairing_verdict(capture, "casein-pairing-42") == :missing
    end

    test "hydrated wins over an earlier MISSING line in the same capture" do
      # The first probe always misses — the shell hydrates on its *next* prompt.
      # The capture is cumulative, so that stale line must not mask the success.
      capture = """
      casein-pairing=MISSING
      casein-pairing=casein-pairing-42
      """

      assert TerminalSmoke.pairing_verdict(capture, "casein-pairing-42") == :hydrated
    end

    test "a stale value from an earlier run does not count as hydrated" do
      # Nonce per run, so a leftover value in the scrollback cannot pass the
      # check for the current probe.
      capture = "casein-pairing=casein-pairing-1\n"

      assert TerminalSmoke.pairing_verdict(capture, "casein-pairing-2") == :unknown
    end

    test "unknown when the probe produced no output at all" do
      assert TerminalSmoke.pairing_verdict("$ \n", "casein-pairing-42") == :unknown
    end
  end
end
