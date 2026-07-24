defmodule Scripts.CheckSccGuardTest do
  @moduledoc """
  Hermetic coverage of the awk parse/classify logic in check-scc-guard.sh.

  Drives the real script with a fake `mix` that cats a fixture matching
  `mix xref graph --format cycles` output — never runs real xref.
  """
  use ExUnit.Case, async: true

  @scc_script Path.expand("../../scripts/check-scc-guard.sh", __DIR__)

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "check-scc-guard-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "mixed preview/core cycle is flagged", %{tmp: tmp} do
    fixture = """
    Cycle of length 2:

        lib/casein/previews/pane.ex
        lib/casein/terminals/session_directory.ex
    """

    {output, status} = run_guard(tmp, fixture)

    assert status == 1
    assert output =~ ~r/mixed preview\/core cycle|MIXED cycle/
  end

  test "all-preview cycle is not flagged", %{tmp: tmp} do
    fixture = """
    Cycle of length 2:

        lib/casein/previews/pane.ex
        lib/casein/preview_panes.ex
    """

    {output, status} = run_guard(tmp, fixture)

    assert status == 0
    assert output =~ "remain in separate SCCs"
  end

  test "all-core cycle is not flagged", %{tmp: tmp} do
    fixture = """
    Cycle of length 2:

        lib/casein/terminals/session_directory.ex
        lib/casein/workspaces/manager.ex
    """

    {output, status} = run_guard(tmp, fixture)

    assert status == 0
    assert output =~ "remain in separate SCCs"
  end

  defp run_guard(tmp, fixture_body) do
    fixture_path = Path.join(tmp, "cycles.txt")
    fake_mix = Path.join(tmp, "fake-mix")

    File.write!(fixture_path, fixture_body)

    File.write!(fake_mix, """
    #!/usr/bin/env bash
    cat "$SCC_FIXTURE"
    """)

    File.chmod!(fake_mix, 0o755)

    System.cmd(@scc_script, [],
      env: [{"MIX", fake_mix}, {"SCC_FIXTURE", fixture_path}],
      stderr_to_stdout: true
    )
  end
end
