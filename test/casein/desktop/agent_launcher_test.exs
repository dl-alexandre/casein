defmodule Casein.Desktop.AgentLauncherTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.AgentLauncher

  test "constructs only known token-free provider commands" do
    for id <- ~w(agent claude clauded codex grok opencode cursor) do
      assert AgentLauncher.supported?(id)
      assert {:ok, command} = AgentLauncher.command(id)
      assert String.ends_with?(command, "\r")
      refute command =~ "CASEIN_API_TOKEN"
      refute command =~ "Bearer"
    end
  end

  test "rejects arbitrary command text" do
    refute AgentLauncher.supported?("grok; Remove-Item -Recurse C:\\")
    assert {:error, :unsupported_agent} = AgentLauncher.command("grok; whoami")
    assert {:error, :unsupported_agent} = AgentLauncher.command(nil)
  end

  test "reports token-free executable, bounded version, and auth diagnostics" do
    home =
      Path.join(System.tmp_dir!(), "agent-launcher-auth-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(home, ".codex"))
    File.write!(Path.join([home, ".codex", "auth.json"]), "{}")

    assert {:ok, diagnostics} =
             AgentLauncher.diagnose("codex",
               home: home,
               resolver: fn "codex" -> "C:\\Tools\\codex.exe" end,
               version_runner: fn "C:\\Tools\\codex.exe", 5_000 ->
                 {:ok, String.duplicate("v", 600)}
               end
             )

    assert diagnostics.executable == "C:\\Tools\\codex.exe"
    assert diagnostics.executable_status == :available
    assert diagnostics.auth == :signed_in
    assert {:ok, version} = diagnostics.version
    assert byte_size(version) == 512
    refute inspect(diagnostics) =~ "CASEIN_API_TOKEN"

    File.rm_rf!(home)
  end

  test "reports missing executables without running a version command" do
    assert {:ok, diagnostics} =
             AgentLauncher.diagnose("grok",
               resolver: fn "grok" -> nil end,
               version_runner: fn _, _ -> flunk("version runner must not execute") end
             )

    assert diagnostics.executable_status == :missing
    assert diagnostics.version == {:error, :missing}
    assert diagnostics.auth == :provider_managed
    assert {:error, :unsupported_agent} = AgentLauncher.diagnose("grok; whoami")
  end
end
