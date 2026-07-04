defmodule DevIDE.Agents.TerminalToolsTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.TerminalTools
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:dev_ide, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes),
      fake_tmux_scrollback: TmuxCtl.Test.FakeState.get(:fake_tmux_scrollback),
      fake_tmux_test_pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid),
      api_token: Application.get_env(:dev_ide, :api_token),
      agent_mcp_base_url: Application.get_env(:dev_ide, :agent_mcp_base_url),
      env_api_token: System.get_env("DEV_IDE_API_TOKEN"),
      env_agent_mcp_home: System.get_env("DEVIDE_AGENT_MCP_HOME"),
      env_home: System.get_env("HOME")
    }

    MemoryAdapter.clear()
    Runtimes.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:dev_ide, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:dev_ide, :tmux_adapter)

      restore_app_env(:api_token, previous.api_token)
      restore_app_env(:agent_mcp_base_url, previous.agent_mcp_base_url)
      restore_system_env("DEV_IDE_API_TOKEN", previous.env_api_token)
      restore_system_env("DEVIDE_AGENT_MCP_HOME", previous.env_agent_mcp_home)
      restore_system_env("HOME", previous.env_home)

      MemoryAdapter.clear()
      Runtimes.clear()
      DevIDE.Audit.MemoryAdapter.clear()
    end)

    :ok
  end

  test "workspace_id scopes session listing" do
    prefix = Tmux.workspace_session_prefix("alpha")

    assert {:ok, %{sessions: sessions}} =
             TerminalTools.list_sessions(%{"workspace_id" => "alpha"})

    assert Enum.all?(sessions, &String.starts_with?(&1.session, prefix))
  end

  test "workspace_id rejects mismatched session" do
    assert {:error, :workspace_mismatch} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => "alpha",
               "session" => "devide_other_u-dev"
             })
  end

  test "definitions include workspace_id on every tool" do
    for tool <- TerminalTools.definitions() do
      assert Map.has_key?(tool.parameters.properties, :workspace_id)
    end
  end

  test "definitions use shared McpCtl terminal workspace_id schema" do
    tool = Enum.find(TerminalTools.definitions(), &(&1.name == "terminal_list_sessions"))
    assert tool.parameters.properties.workspace_id.description =~ "Scopes session discovery"
  end

  test "list_sessions omits workspace_id when it was not supplied" do
    assert {:ok, result} = TerminalTools.list_sessions(%{})
    refute Map.has_key?(result, :workspace_id)
  end

  test "report_worktree refreshes session-scoped MCP env for reported tmux session" do
    root = tmp_repo!("report-worktree-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = Tmux.session_name("runtime", "wt-agent")

    git!(root, ["worktree", "add", "-b", "agent-branch", worktree, "main"])
    seed_workspace("ws-report-worktree", root)

    # staging_home/2 only honors an inherited DEVIDE_AGENT_MCP_HOME when it
    # already matches the workspace-name-derived default (see
    # MCPMaterializer), so isolate this test's MCP staging dir via a fake
    # HOME rather than DEVIDE_AGENT_MCP_HOME directly.
    home = tmp_dir!("report-worktree-home")
    staging = Path.join([home, ".devide", "agent-mcp", "runtime"])
    previous_home = System.get_env("HOME")

    System.put_env("HOME", home)
    System.delete_env("DEVIDE_AGENT_MCP_HOME")

    on_exit(fn ->
      restore_system_env("HOME", previous_home)
    end)

    Application.put_env(:dev_ide, :api_token, "terminal-tools-token")
    Application.put_env(:dev_ide, :agent_mcp_base_url, "http://127.0.0.1:4000")
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    assert {:ok, %{worktree: %{tmux_session_id: ^tmux_session}}} =
             TerminalTools.invoke("terminal_report_worktree", %{
               "workspace_id" => "ws-report-worktree",
               "worktree_path" => worktree,
               "agent" => "codex",
               "tmux_session_id" => tmux_session
             })

    assert_receive {:fake_tmux_set_environments, ^tmux_session, env}

    assert env["DEVIDE_WORKSPACE_ID"] == "ws-report-worktree"
    assert env["DEVIDE_WORKSPACE_NAME"] == "runtime"
    assert env["DEVIDE_CHECKOUT"] == worktree
    assert env["DEVIDE_TMUX_SESSION"] == tmux_session
    assert env["DEVIDE_TERMINAL_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    assert env["DEVIDE_TERMINAL_MCP_URL"] =~ "tmux_session=#{tmux_session}"
    assert env["DEVIDE_PREVIEW_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    assert env["DEVIDE_PREVIEW_MCP_URL"] =~ "tmux_session=#{tmux_session}"
    assert env["DEVIDE_ARTIFACT_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    refute env["DEVIDE_ARTIFACT_MCP_URL"] =~ "tmux_session="
    assert File.read!(Path.join(staging, "env.sh")) =~ "DEVIDE_TMUX_SESSION='#{tmux_session}'"
  end

  test "agent pane shortcuts target only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "work",
          active: true,
          panes: 3,
          activity: 10,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          left: 80,
          top: 0,
          width: 80,
          height: 20,
          current_command: "bash",
          current_path: "/workspace"
        },
        %{
          id: "%3",
          window_id: "@1",
          index: 2,
          active: false,
          left: 80,
          top: 20,
          width: 80,
          height: 20,
          current_command: "git",
          current_path: "/workspace"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok, %{session: ^session, pane: "%2"}} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})

    assert {:ok, %{target: "%2", status: "sent"}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "command" => "mix test"
             })

    assert_receive {:fake_tmux_send_command, ^session, "%2", "mix test", _opts}
  end

  test "terminal_context returns safe agent-pane next step" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 10}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"},
        %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "bash"}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok,
            %{
              recommended_session: ^session,
              recommended_agent_pane: "%2",
              safe_to_mutate: true,
              next_tool: "terminal_send_agent_command",
              next_arguments: %{session: ^session}
            }} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => "alpha"})
  end

  test "terminal_paste_agent_text targets only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 10}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"},
        %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "bash"}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok,
            %{
              target: "%2",
              status: "sent",
              next_tool: "terminal_capture_agent",
              safe_to_mutate: true
            }} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "text" => "one\ntwo",
               "submit" => true
             })

    assert_receive {:fake_tmux_paste_text, ^session, "%2", "one\ntwo", opts}
    assert opts[:submit] == true
  end

  test "capture strips ANSI escapes by default" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{session => "\e[31merror\e[0m\n"})

    assert {:ok, %{output: "error\n"}} =
             TerminalTools.invoke("terminal_capture", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  test "read-only agent pane discovery prefers marker over earlier agent process pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "claude",
          current_path: "/workspace"
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# DevIDE agent pane\n"
    })

    assert {:ok, %{pane: "%2", reason: "agent_pair_marker"}} =
             TerminalTools.invoke("terminal_agent_pane", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  test "send_agent_command requires the agent_pair marker" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "claude",
          current_path: "/workspace"
        }
      ]
    })

    assert {:error, %{error: :agent_pane_not_found}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "command" => "mix test"
             })
  end

  test "default session selection is ambiguous when multiple workspace sessions exist" do
    prefix = Tmux.workspace_session_prefix("alpha")
    session_a = prefix <> "_a"
    session_b = prefix <> "_b"

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session_a => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 1}],
      session_b => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 2}]
    })

    assert {:error,
            %{
              error: :ambiguous_workspace_sessions,
              ambiguous: true,
              candidate_sessions: candidates
            }} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})

    assert length(candidates) == 2
    assert Enum.any?(candidates, &(&1.session == session_a))
    assert Enum.any?(candidates, &(&1.session == session_b))
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "runtime",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "dev_ide", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  defp tmp_repo!(name) do
    path = tmp_dir!(name)
    init_repo!(path)
    path
  end

  defp init_repo!(path) do
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(path, "README.md"), "# Test\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "init"])
    :ok
  end

  defp tmp_dir!(name) do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "devide-terminal-tools-#{System.unique_integer([:positive])}-#{name}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_app_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
