defmodule Scripts.IOSScannerBoundaryProbeRunnerTest do
  use ExUnit.Case, async: true

  @contract_test Path.expand("ios_scanner_boundary_probe_runner_test.py", __DIR__)

  test "physical scanner runner stays bounded, exact-PID, and privacy-safe" do
    {output, status} =
      System.cmd("python3", ["-B", @contract_test],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
