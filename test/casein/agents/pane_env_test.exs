defmodule Casein.Agents.PaneEnvTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentShims
  alias Casein.Agents.AuthProfile
  alias Casein.Agents.PaneEnv

  @workspace %{
    id: "ws-123",
    name: "dalexandre-casein",
    path: "/tmp/casein-checkout"
  }

  setup do
    prev_token = Application.get_env(:casein, :api_token)
    prev_base = Application.get_env(:casein, :agent_mcp_base_url)
    prev_api_base = Application.get_env(:casein, :api_base_url)
    prev_auth_root = Application.get_env(:casein, :agent_auth_profile_root)
    prev_env_token = System.get_env("CASEIN_API_TOKEN")
    prev_ws_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_env_ws_tokens = System.get_env("CASEIN_WORKSPACE_API_TOKENS")
    System.delete_env("CASEIN_API_TOKEN")
    System.delete_env("CASEIN_WORKSPACE_API_TOKENS")

    Application.put_env(:casein, :api_token, "test-token")
    Application.put_env(:casein, :workspace_api_tokens, %{"scoped-ws-123-token" => "ws-123"})
    Application.put_env(:casein, :agent_mcp_base_url, "http://127.0.0.1:4000")

    tmp = System.tmp_dir!() |> Path.join("pane-env-#{System.unique_integer([:positive])}")

    auth_root =
      System.tmp_dir!() |> Path.join("pane-env-auth-#{System.unique_integer([:positive])}")

    Application.put_env(:casein, :agent_auth_profile_root, auth_root)

    on_exit(fn ->
      Application.put_env(:casein, :api_token, prev_token)
      Application.put_env(:casein, :agent_mcp_base_url, prev_base)
      restore_workspace_tokens(prev_ws_tokens)
      restore_api_base(prev_api_base)
      restore_auth_root(prev_auth_root)

      if prev_env_token,
        do: System.put_env("CASEIN_API_TOKEN", prev_env_token),
        else: System.delete_env("CASEIN_API_TOKEN")

      if prev_env_ws_tokens,
        do: System.put_env("CASEIN_WORKSPACE_API_TOKENS", prev_env_ws_tokens),
        else: System.delete_env("CASEIN_WORKSPACE_API_TOKENS")

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
               tmux_session: "casein_dalexandre-casein_wt-agent"
             )

    assert vars["CASEIN_API_TOKEN"] == "scoped-ws-123-token"
    assert vars["CASEIN_WORKSPACE_ID"] == "ws-123"
    assert vars["CASEIN_API_BASE_URL"] == "http://127.0.0.1:4000"
    assert vars["CASEIN_TERMINAL_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["CASEIN_TERMINAL_MCP_URL"] =~ "tmux_session=casein_dalexandre-casein_wt-agent"
    assert vars["CASEIN_PREVIEW_MCP_URL"] =~ "workspace_id=ws-123"
    assert vars["CASEIN_PREVIEW_MCP_URL"] =~ "tmux_session=casein_dalexandre-casein_wt-agent"
    assert vars["CASEIN_ARTIFACT_MCP_URL"] =~ "workspace_id=ws-123"
    refute vars["CASEIN_ARTIFACT_MCP_URL"] =~ "tmux_session="
    assert vars["CASEIN_TMUX_SESSION"] == "casein_dalexandre-casein_wt-agent"
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
    Application.put_env(:casein, :workspace_api_tokens, %{})

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    refute vars["CASEIN_API_TOKEN"] == "test-token"
    assert vars["CASEIN_API_TOKEN"] =~ ~r/^[0-9a-f]{64}$/
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
    Application.put_env(:casein, :api_base_url, "https://casein.example.test")

    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["CASEIN_API_BASE_URL"] == "https://casein.example.test"
    assert vars["CASEIN_TERMINAL_MCP_URL"] =~ "http://127.0.0.1:4000/api/terminals/mcp"
  end

  test "vars_for_workspace includes env.sh path", %{staging: staging} do
    assert {:ok, vars} =
             PaneEnv.vars_for_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path
             )

    assert vars["CASEIN_AGENT_ENV_FILE"] == Path.join(staging, "env.sh")
    assert File.exists?(vars["CASEIN_AGENT_ENV_FILE"])
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

  test "rebind_workspace rotates the bearer and pushes session env", %{staging: staging} do
    Application.put_env(:casein, :workspace_api_tokens, %{"old-ws-token" => "ws-123"})
    Application.put_env(:casein, :workspace_api_tokens_retired, %{})

    parent = self()

    fake =
      start_supervised!({
        Agent,
        fn -> %{sessions: ["casein_dalexandre-casein_wt-agent"], envs: []} end
      })

    Application.put_env(:casein, :tmux_adapter, __MODULE__.FakeTmux)
    Process.put({__MODULE__.FakeTmux, :agent}, fake)
    Process.put({__MODULE__.FakeTmux, :parent}, parent)

    on_exit(fn ->
      Application.delete_env(:casein, :tmux_adapter)
      Process.delete({__MODULE__.FakeTmux, :agent})
      Process.delete({__MODULE__.FakeTmux, :parent})
    end)

    assert {:ok, result} =
             PaneEnv.rebind_workspace(@workspace,
               staging_home: staging,
               checkout: @workspace.path,
               tmux_session: "casein_dalexandre-casein_wt-agent"
             )

    assert result.token != "old-ws-token"
    assert result.previous_token == "old-ws-token"
    assert result.sessions == ["casein_dalexandre-casein_wt-agent"]
    assert result.rebound
    assert Casein.Agents.WorkspaceTokens.stale_grant?("old-ws-token")
    assert Casein.Agents.WorkspaceTokens.token_for("ws-123") == result.token

    assert_receive {:set_environments, "casein_dalexandre-casein_wt-agent", vars}
    assert vars["CASEIN_API_TOKEN"] == result.token
  end

  defmodule FakeTmux do
    def list_sessions do
      case Process.get({Casein.Agents.PaneEnvTest.FakeTmux, :agent}) do
        nil -> []
        agent -> Agent.get(agent, & &1.sessions)
      end
    end

    def set_environments(session, vars) do
      parent = Process.get({Casein.Agents.PaneEnvTest.FakeTmux, :parent})
      if is_pid(parent), do: send(parent, {:set_environments, session, vars})
      :ok
    end
  end

  defp restore_workspace_tokens(nil), do: Application.delete_env(:casein, :workspace_api_tokens)

  defp restore_workspace_tokens(value),
    do: Application.put_env(:casein, :workspace_api_tokens, value)

  defp restore_auth_root(nil), do: Application.delete_env(:casein, :agent_auth_profile_root)

  defp restore_auth_root(value),
    do: Application.put_env(:casein, :agent_auth_profile_root, value)

  defp restore_api_base(nil), do: Application.delete_env(:casein, :api_base_url)
  defp restore_api_base(value), do: Application.put_env(:casein, :api_base_url, value)
end
