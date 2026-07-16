defmodule Scripts.GrokSandboxProfileTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/grok-sandbox-profile.py", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "grok-sandbox-profile-#{System.unique_integer([:positive])}")

    grok_home = Path.join(root, ".grok")
    File.mkdir_p!(grok_home)
    on_exit(fn -> File.rm_rf!(root) end)
    %{grok_home: grok_home}
  end

  test "installs and atomically replaces a managed strict profile without deleting user config",
       %{
         grok_home: grok_home
       } do
    config = Path.join(grok_home, "sandbox.toml")
    File.write!(config, "[profiles.user]\nextends = \"workspace\"\n")

    assert {"managed-profile\n", 0} =
             install(grok_home, "managed-profile", "strict", [
               "/home/dev/.ssh",
               "/tmp/leader.capability"
             ])

    first = File.read!(config)
    assert first =~ "[profiles.user]"
    assert first =~ "[profiles.managed-profile]"
    assert first =~ ~s(extends = "strict")
    assert first =~ ~s("/home/dev/.ssh")
    assert first =~ ~s("/tmp/leader.capability")
    assert {:ok, stat} = File.stat(config)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {"managed-profile\n", 0} =
             install(grok_home, "managed-profile", "read-only", ["/home/dev/.aws"])

    second = File.read!(config)
    assert second =~ "[profiles.user]"
    assert second =~ ~s(extends = "read-only")
    assert second =~ ~s("/home/dev/.aws")
    refute second =~ ~s("/home/dev/.ssh")
    assert length(Regex.scan(~r/\[profiles\.managed-profile\]/, second)) == 1
  end

  test "rejects an unsafe base profile", %{grok_home: grok_home} do
    assert {output, 2} = install(grok_home, "managed-profile", "workspace", ["/tmp/secret"])
    assert output =~ "invalid managed Grok sandbox profile"
  end

  defp install(grok_home, name, base, deny) do
    System.cmd("python3", [@script, "install", name, base | deny],
      env: [{"GROK_HOME", grok_home}],
      stderr_to_stdout: true
    )
  end
end
