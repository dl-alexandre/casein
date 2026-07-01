defmodule DevIDE.Agents.PaneEnvTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.AuthProfile
  alias DevIDE.Agents.PaneEnv

  @workspace %{
    id: "ws-123",
    name: "dalexandre-devide",
    path: "/tmp/devide-checkout"
  }

  setup do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    prev_auth_root = Application.get_env(:dev_ide, :agent_auth_profile_root)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_API_TOKEN")

    Application.put_env(:dev_ide, :api_token, "test-token")
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("pane-env-#{System.unique_integer([:positive])}")

    auth_root =
      System.tmp_dir!() |> Path.join("pane-env-auth-#{System.unique_integer([:positive])}")

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

  test "vars_for_workspace includes pre-scoped MCP URLs", %{staging: staging} do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path,
               tmux_session: "devide_dalexandre-devide_wt-agent"
             )

    assert vars["DEV_IDE_API_TOKEN"] == "test-token"
    assert vars["DEVIDE_WORKSPACE_ID"] == "ws-123"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "tmux_session=devide_dalexandre-devide_wt-agent"
    assert vars["DEVIDE_PREVIEW_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["DEVIDE_PREVIEW_MCP_URL"] =~ "tmux_session=devide_dalexandre-devide_wt-agent"
    assert vars["DEVIDE_TMUX_SESSION"] == "devide_dalexandre-devide_wt-agent"
    refute Map.has_key?(vars, "GROK_HOME")
    refute Map.has_key?(vars, "CODEX_HOME")
    refute Map.has_key?(vars, "CLAUDE_CONFIG_DIR")
  end

  test "launch_command returns bare runtime (PATH shims inject MCP)" do
    assert PaneEnv.launch_command("grok", @workspace) == "grok"
    assert PaneEnv.launch_command("claude", @workspace) == "claude"
    assert PaneEnv.launch_command("codex", @workspace) == "codex"
  end

  test "vars_for_workspace includes env.sh path", %{staging: staging} do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["DEVIDE_AGENT_ENV_FILE"] == Path.join(staging, "env.sh")
    assert File.exists?(vars["DEVIDE_AGENT_ENV_FILE"])
    assert vars["PATH"] =~ ".local/bin"
  end

  test "vars_for_workspace includes opt-in provider auth profiles", %{staging: staging} do
    workspace = %{@workspace | name: "sconde-test"}
    claude_dir = AuthProfile.ensure_named_profile_dir!("sconde", :claude)
    codex_dir = AuthProfile.ensure_named_profile_dir!("sconde", :codex)

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(workspace,
               staging_home: staging,
               checkout: workspace.path
             )

    assert vars["CLAUDE_CONFIG_DIR"] == claude_dir
    assert vars["CODEX_HOME"] == codex_dir
  end

  defp restore_auth_root(nil), do: Application.delete_env(:dev_ide, :agent_auth_profile_root)

  defp restore_auth_root(value),
    do: Application.put_env(:dev_ide, :agent_auth_profile_root, value)
end
