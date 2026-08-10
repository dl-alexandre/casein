defmodule Scripts.GateRunOrSkipTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/gate-run-or-skip.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "runs the command when skip env is unset" do
    assert {"ok\n", 0} =
             System.cmd("bash", [@script, "FORMAT", "printf", "ok\n"], stderr_to_stdout: true)
  end

  test "skips when CASEIN_GATE_SKIP_<TOKEN>=1" do
    assert {out, 0} =
             System.cmd(
               "bash",
               [@script, "FORMAT", "sh", "-c", "echo should-not-run; exit 9"],
               env: [{"CASEIN_GATE_SKIP_FORMAT", "1"}],
               stderr_to_stdout: true
             )

    assert out =~ "already verified"
    refute out =~ "should-not-run"
  end

  test "propagates command failure when not skipped" do
    assert {_, 7} =
             System.cmd("bash", [@script, "CREDO", "sh", "-c", "exit 7"], stderr_to_stdout: true)
  end
end
