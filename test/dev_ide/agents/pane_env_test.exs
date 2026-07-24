defmodule Casein.Agents.PaneEnvTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentShims
  alias Casein.Agents.AuthProfile
  alias Casein.Agents.PaneEnv

  @workspace %{
    id: "ws-123",
    name: "dalexandre-devide",
    path: "/tmp/devide-checkout"
  }

  setup do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    prev_api_base = Application.get_env(:dev_ide, :api_base_url)
    prev_auth_root = Application.get_env(:dev_ide, :agent_auth_profile_root)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    prev_ws_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    prev_env_ws_tokens = System.get_env("DEV_IDE_WORKSPACE_API_TOKENS")
    System.delete_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_WORKSPACE_API_TOKENS")

    Application.put_env(:dev_ide, :api_token, "test-token")
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"scoped-ws-123-token" => "ws-123"})
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("pane-env-#{System.unique_integer([:positive])}")

    auth_root =
      System.tmp_dir!() |> Path.join("pane-env-auth-#{System.unique_integer([:positive])}")

    Application.put_env(:dev_ide, :agent_auth_profile_root, auth_root)

    on_exit(fn ->
      Application.put_env(:dev_ide, :api_token, prev_token)
      Application.put_env(:dev_ide, :agent_mcp_base_url, prev_base)
      restore_workspace_tokens(prev_ws_tokens)
      restore_api_base(prev_api_base)
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

  test "vars_for_workspace includes pre-scoped MCP URLs and owner auth homes", %{
    staging: staging,
    auth_root: auth_root
  } do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path,
               tmux_session: "devide_dalexandre-devide_wt-agent"
             )

    assert vars["DEV_IDE_API_TOKEN"] == "scoped-ws-123-token"
    assert vars["DEVIDE_WORKSPACE_ID"] == "ws-123"
    assert vars["DEVIDE_API_BASE_URL"] == "http://127.0.0.1:4000"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "tmux_session=devide_dalexandre-devide_wt-agent"
    assert vars["DEVIDE_PREVIEW_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["DEVIDE_PREVIEW_MCP_URL"] =~ "tmux_session=devide_dalexandre-devide_wt-agent"
    assert vars["DEVIDE_ARTIFACT_MCP_URL"] =~ "workspace_id=ws-123"
    refute vars["DEVIDE_ARTIFACT_MCP_URL"] =~ "tmux_session="
    assert vars["DEVIDE_TMUX_SESSION"] == "devide_dalexandre-devide_wt-agent"
    refute Map.has_key?(vars, "GROK_HOME")
    # No signed-in owner profile: stay on the host global provider login.
    refute Map.has_key?(vars, "CLAUDE_CONFIG_DIR")
    refute Map.has_key?(vars, "CODEX_HOME")
    refute File.dir?(Path.join([auth_root, "profiles", "dalexandre", "claude"]))
    refute File.dir?(Path.join([auth_root, "profiles", "dalexandre", "codex"]))
  end

  test "vars_for_workspace never pushes the global admin token into tmux env", %{
    staging: staging
  } do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{})

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    refute vars["DEV_IDE_API_TOKEN"] == "test-token"
    assert vars["DEV_IDE_API_TOKEN"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "launch_command returns bare runtime (PATH shims inject MCP)" do
    assert PaneEnv.launch_command("grok", @workspace) == "grok"
    assert PaneEnv.launch_command("claude", @workspace) == "claude"
    assert PaneEnv.launch_command("codex", @workspace) == "codex"
  end

  test "launch_command maps clauded alias to claude (no bash-alias dependency)" do
    assert PaneEnv.launch_command("clauded", @workspace) == "claude"
    assert PaneEnv.launch_command("  clauded  ", @workspace) == "claude"
  end

  test "vars_for_workspace can expose a plain API base distinct from MCP URLs", %{
    staging: staging
  } do
    Application.put_env(:dev_ide, :api_base_url, "https://devide.example.test")

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["DEVIDE_API_BASE_URL"] == "https://devide.example.test"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "http://127.0.0.1:4000/api/terminals/mcp"
  end

  test "vars_for_workspace includes env.sh path", %{staging: staging} do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["DEVIDE_AGENT_ENV_FILE"] == Path.join(staging, "env.sh")
    assert File.exists?(vars["DEVIDE_AGENT_ENV_FILE"])
    # Assert the agent bin dir PaneEnv deterministically prepends, not a literal
    # ".local/bin": that string only appeared via the ambient $PATH, so the test
    # passed in an interactive/runner shell but failed under the deploy poller's
    # systemd env (no ~/.local/bin) — blocking every master deploy. Mirror the
    # npm_bin_dir assertion below and test the guarantee PaneEnv actually makes.
    assert vars["PATH"] =~ AgentShims.bin_dir()
    assert vars["PATH"] =~ AgentShims.npm_bin_dir()
  end

  test "vars_for_workspace includes signed-in owner provider auth profiles", %{staging: staging} do
    workspace = %{@workspace | name: "sconde-test"}
    claude_dir = AuthProfile.ensure_named_profile_dir!("sconde", :claude)
    codex_dir = AuthProfile.ensure_named_profile_dir!("sconde", :codex)
    File.write!(Path.join(claude_dir, ".credentials.json"), "{}")
    File.write!(Path.join(codex_dir, "auth.json"), "{}")

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(workspace,
               staging_home: staging,
               checkout: workspace.path
             )

    assert vars["CLAUDE_CONFIG_DIR"] == claude_dir
    assert vars["CODEX_HOME"] == codex_dir
  end

  test "vars_for_workspace skips owner auth profiles that never signed in", %{staging: staging} do
    workspace = %{@workspace | name: "sconde-test"}
    AuthProfile.ensure_named_profile_dir!("sconde", :claude)
    AuthProfile.ensure_named_profile_dir!("sconde", :codex)

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(workspace,
               staging_home: staging,
               checkout: workspace.path
             )

    refute Map.has_key?(vars, "CLAUDE_CONFIG_DIR")
    refute Map.has_key?(vars, "CODEX_HOME")
  end

  defp restore_workspace_tokens(nil), do: Application.delete_env(:dev_ide, :workspace_api_tokens)

  defp restore_workspace_tokens(value),
    do: Application.put_env(:dev_ide, :workspace_api_tokens, value)

  defp restore_auth_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)

  defp restore_auth_root(value),
    do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)

  defp restore_api_base(nil), do: Application.delete_env(:dev_ide, :api_base_url)
  defp restore_api_base(value), do: Application.put_env(:dev_ide, :api_base_url, value)
end
