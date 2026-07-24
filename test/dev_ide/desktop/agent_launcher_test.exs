defmodule Casein.Desktop.AgentLauncherTest do
  use ExUnit.Case, async: true

  alias Casein.Desktop.AgentLauncher

  test "constructs only known token-free provider commands" do
    for id <- ~w(agent claude clauded codex grok opencode cursor) do
      assert AgentLauncher.supported?(id)
      assert {:ok, command} = AgentLauncher.command(id)
      assert String.ends_with?(command, "\r")
      refute command =~ "DEV_IDE_API_TOKEN"
      refute command =~ "Bearer"
    end
  end

  test "rejects arbitrary command text" do
    refute AgentLauncher.supported?("grok; Remove-Item -Recurse C:\\")
    assert {:error, :unsupported_agent} = AgentLauncher.command("grok; whoami")
    assert {:error, :unsupported_agent} = AgentLauncher.command(nil)
  end
end
