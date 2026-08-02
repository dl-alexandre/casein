defmodule Scripts.AndroidNativeProvenanceGuardTest do
  use ExUnit.Case, async: true

  @contract_test Path.expand("android_native_provenance_guard_test.py", __DIR__)

  test "Android native runtime provenance stays exact and privacy safe" do
    {output, status} =
      System.cmd("python3", ["-B", @contract_test],
        env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
