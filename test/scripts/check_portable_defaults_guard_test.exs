defmodule Scripts.CheckPortableDefaultsGuardTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-portable-defaults-guard.sh", __DIR__)

  test "portable defaults guard has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "current tree satisfies the portable defaults guard" do
    {output, status} = System.cmd("bash", [@script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "host-agnostic"
  end

  test "guard flags a planted /home/devbox default" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "portable-defaults-guard-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.mkdir_p!(Path.join(tmp, "config"))
    File.mkdir_p!(Path.join(tmp, "scripts"))

    File.write!(Path.join(tmp, "lib/bad.ex"), """
    defmodule Bad do
      defp home, do: System.get_env("HOME") || "/home/devbox"
    end
    """)

    File.write!(Path.join(tmp, "config/config.exs"), "import_config \"runtime.exs\"\n")
    File.write!(Path.join(tmp, "config/runtime.exs"), "# clean\n")

    script_body = File.read!(@script)
    planted = Path.join(tmp, "scripts/check-portable-defaults-guard.sh")
    File.write!(planted, script_body)
    File.chmod!(planted, 0o755)

    {output, status} =
      System.cmd("bash", [planted], cd: tmp, stderr_to_stdout: true)

    File.rm_rf!(tmp)

    assert status == 1
    assert output =~ "/home/devbox"
  end
end
