defmodule DevIDE.Agents.PaneEnvTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.PaneEnv

  @workspace %{
    id: "ws-123",
    name: "dalexandre-devide",
    path: "/tmp/devide-checkout"
  }

  setup do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_base = Application.get_env(:dev_ide, :agent_mcp_base_url)
    prev_env_token = System.get_env("DEV_IDE_API_TOKEN")
    System.delete_env("DEV_IDE_API_TOKEN")

    Application.put_env(:dev_ide, :api_token, "test-token")
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("pane-env-#{System.unique_integer([:positive])}")

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

  test "vars_for_workspace includes pre-scoped MCP URLs", %{staging: staging} do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["DEV_IDE_API_TOKEN"] == "test-token"
    assert vars["DEVIDE_WORKSPACE_ID"] == "ws-123"
    assert vars["DEVIDE_TERMINAL_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["DEVIDE_PREVIEW_MCP_URL"] =~ "workspace_id=ws-123"
    refute Map.has_key?(vars, "GROK_HOME")
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
end
