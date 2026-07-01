defmodule DevIDE.Agents.MCPMaterializerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.AuthProfile
  alias DevIDE.Agents.MCPMaterializer

  @workspace %{
    id: "ws-abc",
    name: "test-ws",
    path: "/tmp/ws-checkout"
  }

  setup do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    prev_auth_root = Application.get_env(:dev_ide, :agent_auth_profile_root)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_API_TOKEN")
    Application.put_env(:dev_ide, :api_token, "secret-token")
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("mcp-materializer-#{System.unique_integer([:positive])}")

    auth_root =
      System.tmp_dir!()
      |> Path.join("mcp-materializer-auth-#{System.unique_integer([:positive])}")

    Application.put_env(:dev_ide, :agent_auth_profile_root, auth_root)

    on_exit(fn ->
      Application.put_env(:dev_ide, :api_token, prev_token)
      Application.put_env(:dev_ide, :agent_mcp_base_url, prev_base)
      restore_auth_root(prev_auth_root)

      if prev_env_token,
        do: System.put_env("DEV_IDE_API_TOKEN", prev_env_token),
        else: System.delete_env("DEV_IDE_API_TOKEN")

      File.rm_rf(tmp)
      File.rm_rf(auth_root)
    end)

    %{staging: tmp, auth_root: auth_root}
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

    codex = File.read!(Path.join(staging, "codex/config.toml"))
    refute codex =~ "devide-terminal"
    refute codex =~ "devide-preview"
    refute codex =~ "DEV_IDE_API_TOKEN"

    env_sh = File.read!(Path.join(staging, "env.sh"))
    refute env_sh =~ "CLAUDE_CONFIG_DIR"
    refute env_sh =~ "CODEX_HOME"
  end

  test "materialize writes opt-in provider auth profiles to env.sh", %{
    staging: staging
  } do
    claude_dir = AuthProfile.ensure_named_profile_dir!("test", :claude)
    codex_dir = AuthProfile.ensure_named_profile_dir!("test", :codex)

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "export CLAUDE_CONFIG_DIR='#{claude_dir}'"
    assert env_sh =~ "export CODEX_HOME='#{codex_dir}'"
  end

  test "materialize includes tidewave MCP when resolved", %{staging: staging} do
    home =
      Path.join(
        System.tmp_dir!(),
        "devide-preview-materializer-#{System.unique_integer([:positive])}"
      )

    inst_dir = Path.join(home, "instances")
    File.mkdir_p!(inst_dir)

    File.write!(
      Path.join(inst_dir, "prev-abc.json"),
      Jason.encode!(%{
        "id" => "prev-abc",
        "port" => "41042",
        "status" => "running",
        "tidewave_mcp_url" => "http://127.0.0.1:41042/tidewave/mcp"
      })
    )

    prev_home = Application.get_env(:dev_ide, :preview_env_home)
    prev_preview_home_env = System.get_env("DEVIDE_PREVIEW_HOME")
    System.delete_env("DEVIDE_PREVIEW_HOME")
    Application.put_env(:dev_ide, :preview_env_home, home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_preview_home(prev_home)

      if prev_preview_home_env,
        do: System.put_env("DEVIDE_PREVIEW_HOME", prev_preview_home_env),
        else: System.delete_env("DEVIDE_PREVIEW_HOME")
    end)

    assert {:ok, ^staging} =
             MCPMaterializer.materialize(@workspace,
               staging_home: staging,
               preview_env_fallback: true
             )

    grok = File.read!(Path.join(staging, "grok/config.toml"))
    assert grok =~ "devide-tidewave-test-ws"
    assert grok =~ "http://127.0.0.1:41042/tidewave/mcp"
    refute grok =~ "devide-tidewave-test-ws.headers"

    mcp_json = Jason.decode!(File.read!(Path.join(staging, ".mcp.json")))
    assert Map.has_key?(mcp_json["mcpServers"], "devide-tidewave-test-ws")

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "DEVIDE_TIDEWAVE_MCP_URL='http://127.0.0.1:41042/tidewave/mcp'"
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

  test "ignores an inherited DEVIDE_AGENT_MCP_HOME that belongs to a different workspace" do
    home =
      System.tmp_dir!()
      |> Path.join("mcp-materializer-home-#{System.unique_integer([:positive])}")

    prev_home = System.get_env("HOME")
    prev_agent_home = System.get_env("DEVIDE_AGENT_MCP_HOME")
    System.put_env("HOME", home)

    other_workspace_staging = Path.join([home, ".devide", "agent-mcp", "some-other-workspace"])
    System.put_env("DEVIDE_AGENT_MCP_HOME", other_workspace_staging)

    on_exit(fn ->
      File.rm_rf(home)

      if prev_home, do: System.put_env("HOME", prev_home), else: System.delete_env("HOME")

      if prev_agent_home,
        do: System.put_env("DEVIDE_AGENT_MCP_HOME", prev_agent_home),
        else: System.delete_env("DEVIDE_AGENT_MCP_HOME")
    end)

    expected_staging = Path.join([home, ".devide", "agent-mcp", "test-ws"])
    assert {:ok, ^expected_staging} = MCPMaterializer.materialize(@workspace)
    refute File.exists?(Path.join(other_workspace_staging, ".mcp.json"))

    mcp_json = File.read!(Path.join(expected_staging, ".mcp.json"))
    assert mcp_json =~ "devide-terminal-test-ws"
  end

  defp restore_preview_home(nil), do: Application.delete_env(:dev_ide, :preview_env_home)
  defp restore_preview_home(value), do: Application.put_env(:dev_ide, :preview_env_home, value)
  defp restore_auth_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)

  defp restore_auth_root(value),
    do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)
end
