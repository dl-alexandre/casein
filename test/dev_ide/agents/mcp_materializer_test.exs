defmodule DevIDE.Agents.MCPMaterializerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.MCPMaterializer

  @workspace %{
    id: "ws-abc",
    name: "test-ws",
    path: "/tmp/ws-checkout"
  }

  setup do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_API_TOKEN")
    Application.put_env(:dev_ide, :api_token, "secret-token")
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("mcp-materializer-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.put_env(:dev_ide, :api_token, prev_token)
      Application.put_env(:dev_ide, :agent_mcp_base_url, prev_base)

      if prev_env_token,
        do: System.put_env("DEV_IDE_API_TOKEN", prev_env_token),
        else: System.delete_env("DEV_IDE_API_TOKEN")

      File.rm_rf(tmp)
    end)

    %{staging: tmp}
  end

  test "materialize writes runtime-specific MCP configs", %{staging: staging} do
    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    grok = File.read!(Path.join(staging, "grok/config.toml"))
    assert grok =~ "devide-terminal"
    assert grok =~ "workspace_id=ws-abc"
    assert grok =~ "${DEV_IDE_API_TOKEN}"

    mcp_json = File.read!(Path.join(staging, ".mcp.json"))
    assert mcp_json =~ "devide-terminal-test-ws"
    assert mcp_json =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute mcp_json =~ "secret-token"
    refute mcp_json =~ "Bearer '"
    assert File.regular?(Path.join(staging, "cursor/mcp.json"))
  end

  test "materialize strips accidental shell quotes from bearer token", %{staging: staging} do
    Application.put_env(:dev_ide, :api_token, "'quoted-token'")

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    mcp_json = File.read!(Path.join(staging, ".mcp.json"))
    assert mcp_json =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute mcp_json =~ "Bearer quoted-token"
    refute mcp_json =~ "Bearer '"

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "DEVIDE_WORKSPACE_ID"
    assert env_sh =~ "DEVIDE_PREVIEW_MCP_URL"
  end
end
