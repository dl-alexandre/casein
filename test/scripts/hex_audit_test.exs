defmodule Scripts.HexAuditTest do
  @moduledoc """
  Coverage of scripts/hex-audit.sh.

  The allowlist exists so one broken upstream release cannot block every
  deploy. It must not become a hole: everything not named, and every version
  not named, still has to fail.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/hex-audit.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "a clean audit passes" do
    {out, 0} = audit("No retired packages found", 0)
    refute out =~ "warn:"
  end

  test "the allowlisted erlexec retirement is tolerated loudly" do
    {out, 0} =
      audit(
        """
        Retired:
          erlexec 2.3.4 - (deprecated) Deprecated

        Found retired packages
        """,
        1
      )

    assert out =~ "tolerating allowlisted retired dependencies"
    assert out =~ "erlexec 2.3.4"
  end

  test "a retired package outside the allowlist still fails" do
    {out, 1} =
      audit(
        """
        Retired:
          some_other_dep 1.2.3 - (deprecated) Deprecated

        Found retired packages
        """,
        1
      )

    assert out =~ "outside the hex-audit allowlist"
    assert out =~ "some_other_dep 1.2.3"
  end

  test "an allowlisted package at a different version is not excused" do
    # The entry pins the version it was reasoned about, so a later bump cannot
    # inherit the exemption without someone looking at it again.
    {out, 1} =
      audit(
        """
        Retired:
          erlexec 2.4.0 - (deprecated) Deprecated

        Found retired packages
        """,
        1
      )

    assert out =~ "outside the hex-audit allowlist"
    assert out =~ "erlexec 2.4.0"
  end

  test "an allowlisted entry alongside an unlisted one still fails" do
    {out, 1} =
      audit(
        """
        Retired:
          erlexec 2.3.4 - (deprecated) Deprecated
          some_other_dep 1.2.3 - (deprecated) Deprecated

        Found retired packages
        """,
        1
      )

    assert out =~ "some_other_dep 1.2.3"
    refute out =~ "outside the hex-audit allowlist:\n       erlexec"
  end

  test "an audit that fails without a parseable retirement is a real failure" do
    {out, 1} = audit("** (Mix) Could not reach hex.pm", 1)

    assert out =~ "reported no parseable retirement"
  end

  defp audit(mix_output, mix_status) do
    dir = Path.join(System.tmp_dir!(), "hex-audit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    mix = Path.join(dir, "mix")
    File.write!(mix, "#!/usr/bin/env bash\ncat <<'OUT'\n#{mix_output}\nOUT\nexit #{mix_status}\n")
    File.chmod!(mix, 0o755)

    System.cmd("bash", [@script],
      env: [{"PATH", "#{dir}:#{System.get_env("PATH")}"}],
      stderr_to_stdout: true
    )
  end
end
