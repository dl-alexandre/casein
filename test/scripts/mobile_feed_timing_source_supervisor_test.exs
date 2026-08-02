defmodule Scripts.MobileFeedTimingSourceSupervisorTest do
  use ExUnit.Case, async: true

  @contract_test Path.expand("mobile_feed_timing_source_supervisor_test.py", __DIR__)

  test "native timing source supervision and privacy contract passes" do
    {output, status} =
      System.cmd("python3", ["-B", @contract_test],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
