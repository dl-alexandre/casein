defmodule DevIDE.Agents.MCPMaterializerTest do
  use DevIDE.TestCase, async: false

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
    prev_ws_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_env_ws_tokens = System.get_env("DEV_IDE_WORKSPACE_API_TOKENS")
    System.delete_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")
    Application.put_env(:dev_ide, :api_token, "secret-token")
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"scoped-ws-abc-token" => "ws-abc"})
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("mcp-materializer-#{System.unique_integer([:positive])}")

    auth_root =
      System.tmp_dir!()
      |> Path.join("mcp-materializer-auth-#{System.unique_integer([:positive])}")

    Application.put_env(:dev_ide, :agent_auth_profile_root, auth_root)

    on_exit(fn ->
      Application.put_env(:dev_ide, :api_token, prev_token)
      Application.put_env(:dev_ide, :agent_mcp_base_url, prev_base)
      restore_workspace_tokens(prev_ws_tokens)
      restore_auth_root(prev_auth_root)

      if prev_env_token,
        do: System.put_env("DEV_IDE_API_TOKEN", prev_env_token),
        else: System.delete_env("DEV_IDE_API_TOKEN")

      if prev_env_ws_tokens,
        do: System.put_env("DEV_IDE_WORKSPACE_API_TOKENS", prev_env_ws_tokens),
        else: System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")

      File.rm_rf(tmp)
      File.rm_rf(auth_root)
    end)

    %{staging: tmp, auth_root: auth_root}
  end

  test "materialize writes runtime-specific MCP configs and owner auth homes", %{
    staging: staging,
    auth_root: auth_root
  } do
    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    grok = File.read!(Path.join(staging, "grok/config.toml"))
    assert grok =~ "devide-terminal"
    assert grok =~ "devide-artifact"
    assert grok =~ "workspace_id=ws-abc"
    assert grok =~ "${DEV_IDE_API_TOKEN}"

    mcp_json = File.read!(Path.join(staging, ".mcp.json"))
    assert mcp_json =~ "devide-terminal-test-ws"
    assert mcp_json =~ "devide-artifact-test-ws"
    assert mcp_json =~ "/api/artifacts/mcp?workspace_id=ws-abc"
    assert mcp_json =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute mcp_json =~ "secret-token"
    refute mcp_json =~ "Bearer '"
    assert File.regular?(Path.join(staging, "cursor/mcp.json"))

    codex = File.read!(Path.join(staging, "codex/config.toml"))
    refute codex =~ "devide-terminal"
    refute codex =~ "devide-preview"
    refute codex =~ "devide-artifact"
    refute codex =~ "DEV_IDE_API_TOKEN"

    hooks = Jason.decode!(File.read!(Path.join(staging, "claude-hooks-settings.json")))

    assert Enum.sort(Map.keys(hooks["hooks"])) ==
             ~w(Notification PreToolUse SessionEnd SessionStart Stop UserPromptSubmit)

    assert hooks["hooks"]["PreToolUse"] |> hd() |> Map.get("matcher") == "*"

    stop_command = hooks["hooks"]["Stop"] |> hd() |> get_in(["hooks", Access.at(0), "command"])
    assert stop_command =~ "devide-agent-state.sh"

    # The hook must resolve from the workspace staging home (checkout-independent),
    # and the script must actually be staged there — not left in <checkout>/scripts.
    assert stop_command =~ "DEVIDE_AGENT_MCP_HOME"
    assert File.regular?(Path.join(staging, "devide-agent-state.sh"))
    assert File.regular?(Path.join(staging, "devide-codex-notify.sh"))

    sidechat = Jason.decode!(File.read!(Path.join(staging, "claude-sidechat-settings.json")))
    assert sidechat["permissions"]["deny"] == ["Edit", "Write", "Bash"]
    assert Map.has_key?(sidechat, "hooks")

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "export DEV_IDE_API_TOKEN='scoped-ws-abc-token'"

    assert env_sh =~
             "export DEVIDE_ARTIFACT_MCP_URL='http://127.0.0.1:4000/api/artifacts/mcp?workspace_id=ws-abc'"

    refute env_sh =~ "secret-token"

    # No signed-in owner profile: env.sh keeps the host global provider login.
    refute env_sh =~ "CLAUDE_CONFIG_DIR"
    refute env_sh =~ "CODEX_HOME"
    refute File.dir?(Path.join([auth_root, "profiles", "test", "claude"]))
    refute File.dir?(Path.join([auth_root, "profiles", "test", "codex"]))
  end

  test "materialize writes signed-in owner provider auth profiles to env.sh", %{
    staging: staging
  } do
    claude_dir = AuthProfile.ensure_named_profile_dir!("test", :claude)
    codex_dir = AuthProfile.ensure_named_profile_dir!("test", :codex)
    File.write!(Path.join(claude_dir, ".credentials.json"), "{}")
    File.write!(Path.join(codex_dir, "auth.json"), "{}")

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "export CLAUDE_CONFIG_DIR='#{claude_dir}'"
    assert env_sh =~ "export CODEX_HOME='#{codex_dir}'"
  end

  test "materialize omits owner auth profiles that never signed in", %{staging: staging} do
    AuthProfile.ensure_named_profile_dir!("test", :claude)
    AuthProfile.ensure_named_profile_dir!("test", :codex)

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    env_sh = File.read!(Path.join(staging, "env.sh"))
    refute env_sh =~ "CLAUDE_CONFIG_DIR"
    refute env_sh =~ "CODEX_HOME"
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
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"'quoted-token'" => "ws-abc"})

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    mcp_json = File.read!(Path.join(staging, ".mcp.json"))
    assert mcp_json =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute mcp_json =~ "Bearer quoted-token"
    refute mcp_json =~ "Bearer '"

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert env_sh =~ "export DEV_IDE_API_TOKEN='quoted-token'"
    assert env_sh =~ "DEVIDE_WORKSPACE_ID"
    assert env_sh =~ "DEVIDE_PREVIEW_MCP_URL"
    assert env_sh =~ "DEVIDE_ARTIFACT_MCP_URL"
  end

  test "materialize mints a scoped token for an unregistered workspace", %{staging: staging} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{})

    assert {:ok, ^staging} = MCPMaterializer.materialize(@workspace, staging_home: staging)

    env_sh = File.read!(Path.join(staging, "env.sh"))
    assert [_, token] = Regex.run(~r/export DEV_IDE_API_TOKEN='([0-9a-f]{64})'/, env_sh)
    refute token == "secret-token"

    # the minted token is registered so the MCP endpoints accept it immediately
    assert Application.get_env(:dev_ide, :workspace_api_tokens)[token] == "ws-abc"
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
    assert mcp_json =~ "devide-artifact-test-ws"
  end

  test "desktop Grok materialization merges project MCP servers without writing the token", %{
    staging: staging
  } do
    checkout = Path.join(staging, "checkout")
    File.mkdir_p!(checkout)

    File.write!(
      Path.join(checkout, ".mcp.json"),
      Jason.encode!(%{
        "projectSetting" => true,
        "mcpServers" => %{"user-server" => %{"url" => "http://example.test/mcp"}}
      })
    )

    assert {:ok, ^staging} =
             MCPMaterializer.materialize(@workspace,
               staging_home: staging,
               checkout: checkout,
               copy_grok_to_checkout: true
             )

    merged = Jason.decode!(File.read!(Path.join(checkout, ".mcp.json")))
    assert merged["projectSetting"]
    assert merged["mcpServers"]["user-server"]["url"] == "http://example.test/mcp"
    assert merged["mcpServers"]["devide-terminal-test-ws"]
    assert merged["mcpServers"]["devide-preview-test-ws"]
    assert merged["mcpServers"]["devide-artifact-test-ws"]

    contents = File.read!(Path.join(checkout, ".mcp.json"))
    assert contents =~ "Bearer ${DEV_IDE_API_TOKEN}"
    refute contents =~ "scoped-ws-abc-token"
  end

  defp restore_workspace_tokens(nil), do: Application.delete_env(:dev_ide, :workspace_api_tokens)

  defp restore_workspace_tokens(value),
    do: Application.put_env(:dev_ide, :workspace_api_tokens, value)

  defp restore_preview_home(nil), do: Application.delete_env(:dev_ide, :preview_env_home)
  defp restore_preview_home(value), do: Application.put_env(:dev_ide, :preview_env_home, value)
  defp restore_auth_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)

  defp restore_auth_root(value),
    do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)
end
