defmodule Scripts.MobileFeedTimingCollectorTest do
  use ExUnit.Case, async: true

  @contract_test Path.expand("mobile_feed_timing_collector_test.py", __DIR__)

  test "bounded privacy and cohort contract passes" do
    {output, status} =
      System.cmd("python3", [@contract_test],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
