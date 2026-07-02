defmodule DevIDE.Workspaces.SshRunner.SystemTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspaces.SshRunner.System, as: SshSystem

  @invalid_host "devide-ssh-invalid.#{System.unique_integer([:positive])}.invalid"

  test "run/2 returns error for unreachable host without hanging" do
    assert {:error, {:ssh_failed, _code, _err}} = SshSystem.run(@invalid_host, ["echo", "hi"])
  end

  @tag timeout: 35_000
  test "run_with_stdin/3 returns timeout when ssh never reports exit status" do
    assert {:error, :timeout} =
             SshSystem.run_with_stdin(@invalid_host, ["cat"], "stdin-data\n")
  end
end
