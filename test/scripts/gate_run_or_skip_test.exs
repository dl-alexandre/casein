defmodule Scripts.GateRunOrSkipTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/gate-run-or-skip.sh", __DIR__)

  # System.cmd/3 merges env with the parent. Inside the PR gate, #818 exports
  # CASEIN_GATE_SKIP_* after the cheap phase — so "unset" tests must delete
  # those vars for the child (nil entry) or they inherit the gate's skips.
  @clear_skip_env [
    {"CASEIN_GATE_SKIP_FORMAT", nil},
    {"CASEIN_GATE_SKIP_HEEX_BOOL", nil},
    {"CASEIN_GATE_SKIP_PORTABLE", nil},
    {"CASEIN_GATE_SKIP_DOC_CITATIONS", nil},
    {"CASEIN_GATE_SKIP_CREDO", nil},
    {"CASEIN_GATE_SKIP_SOBELOW", nil}
  ]

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "runs the command when skip env is unset" do
    assert {"ok\n", 0} =
             System.cmd("bash", [@script, "FORMAT", "printf", "ok\n"],
               env: @clear_skip_env,
               stderr_to_stdout: true
             )
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
             System.cmd("bash", [@script, "CREDO", "sh", "-c", "exit 7"],
               env: @clear_skip_env,
               stderr_to_stdout: true
             )
  end
end
