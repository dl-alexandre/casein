defmodule Casein.Agents.TerminalToolsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Agents.AgentEvents
  alias Casein.Runtimes
  alias Casein.Terminals.SharedWorktreeGuard
  alias Casein.Terminals.Tmux
  alias Casein.Workspace
  alias Casein.Workspaces.DbIsolation
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes),
      fake_tmux_scrollback: TmuxCtl.Test.FakeState.get(:fake_tmux_scrollback),
      fake_tmux_test_pid: TmuxCtl.Test.FakeState.get(:fake_tmux_test_pid),
      api_token: Application.get_env(:casein, :api_token),
      agent_mcp_base_url: Application.get_env(:casein, :agent_mcp_base_url),
      env_api_token: System.get_env("CASEIN_API_TOKEN"),
      env_agent_mcp_home: System.get_env("CASEIN_AGENT_MCP_HOME"),
      env_home: System.get_env("HOME")
    }

    MemoryAdapter.clear()
    Runtimes.clear()
    Casein.Audit.MemoryAdapter.clear()
    AgentEvents.clear()
    Casein.Terminals.AgentState.clear()

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)

      restore_app_env(:api_token, previous.api_token)
      restore_app_env(:agent_mcp_base_url, previous.agent_mcp_base_url)
      restore_system_env("CASEIN_API_TOKEN", previous.env_api_token)
      restore_system_env("CASEIN_AGENT_MCP_HOME", previous.env_agent_mcp_home)
      restore_system_env("HOME", previous.env_home)

      MemoryAdapter.clear()
      Runtimes.clear()
      Casein.Audit.MemoryAdapter.clear()
      AgentEvents.clear()
      Casein.Terminals.AgentState.clear()
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
    assert {:error, %{error: :workspace_mismatch} = err} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => "alpha",
               "session" => "casein_other_u-dev"
             })

    assert err.workspace.arg == "alpha"
    assert err.workspace.kind == :slug
    assert err.session.name == "casein_other_u-dev"
    assert err.session.workspace == "other"
  end

  test "persisted workspace identity keeps list, topology, and capture in one scope" do
    workspace_id = "ws-persisted"
    session = Tmux.session_name("stable-name", "main")

    # The suite's manager stub returns 404 for this id. A previously observed,
    # persisted UUID/name mapping must still scope every terminal read alike.
    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: "stable-name",
               path: "/workspace",
               status: :running
             })

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

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
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{"%1" => "ready\n"})

    assert {:ok, %{sessions: sessions}} =
             TerminalTools.list_sessions(%{"workspace_id" => workspace_id})

    assert Enum.map(sessions, & &1.session) == [session]

    assert {:ok, %{panes: [%{id: "%1"}]}} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => workspace_id,
               "session" => session
             })

    assert {:ok, %{target: "%1", output: "ready\n"}} =
             TerminalTools.invoke("terminal_capture", %{
               "workspace_id" => workspace_id,
               "session" => session,
               "pane" => "%1"
             })
  end

  test "next_arguments from list_sessions is accepted by next_tool and topology" do
    workspace_id = "69ab354b-0157-4344-88db-40b751773eec"
    session = Tmux.session_name("mbaldin-v3-design-c", "wt-next")

    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: "mbaldin-v3-design-c",
               path: "/workspace",
               status: :running
             })

    seed_live_session!(session)

    assert {:ok, listed} = TerminalTools.list_sessions(%{"workspace_id" => workspace_id})
    assert listed.recommended_session == session
    assert listed.next_tool == "terminal_context"
    assert listed.next_arguments == %{workspace_id: workspace_id, session: session}

    next_args =
      Map.new(listed.next_arguments, fn {key, value} -> {to_string(key), value} end)

    assert {:ok, _context} = TerminalTools.invoke(listed.next_tool, next_args)

    assert {:ok, %{panes: [%{id: "%1"}]}} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => workspace_id,
               "session" => session
             })
  end

  test "slug and omitted workspace_id resolve or fail fast without manager HTTP" do
    workspace_id = "69ab354b-0157-4344-88db-40b751773eec"
    slug = "mbaldin-v3-design-c"
    session = Tmux.session_name(slug, "wt-fast")

    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: slug,
               path: "/workspace",
               status: :running
             })

    seed_live_session!(session)
    hang_workspace_source!()

    {slug_elapsed, slug_result} =
      timed_ms(fn ->
        TerminalTools.invoke("terminal_topology", %{"workspace_id" => slug, "session" => session})
      end)

    {uuid_elapsed, uuid_result} =
      timed_ms(fn ->
        TerminalTools.invoke("terminal_topology", %{
          "workspace_id" => workspace_id,
          "session" => session,
          "include_transcript" => true
        })
      end)

    {omitted_elapsed, omitted_result} =
      timed_ms(fn ->
        TerminalTools.invoke("terminal_topology", %{"session" => session})
      end)

    assert {:ok, %{panes: [%{id: "%1"}]}} = slug_result
    assert {:ok, %{panes: [%{id: "%1"}]}} = uuid_result
    assert {:ok, %{panes: [%{id: "%1"}]}} = omitted_result
    assert slug_elapsed < 5_000
    assert uuid_elapsed < 5_000
    assert omitted_elapsed < 5_000
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

  test "unscoped list_sessions filters out synthetic scratch sessions" do
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    real_session = Tmux.session_name("alpha", "u-dev")
    scratch_session = Tmux.session_name("__scratch__", "u-dev")
    foreign_session = "foreign_session"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      real_session => [%{id: "@1", index: 0, name: "main", active: true, panes: 1, activity: 1}],
      scratch_session => [
        %{id: "@2", index: 0, name: "main", active: true, panes: 1, activity: 1}
      ],
      foreign_session => [
        %{id: "@3", index: 0, name: "main", active: true, panes: 1, activity: 1}
      ]
    })

    assert {:ok, %{sessions: sessions}} = TerminalTools.list_sessions(%{})
    names = Enum.map(sessions, & &1.session)

    assert real_session in names
    refute scratch_session in names
    refute foreign_session in names
  end

  test "report_worktree refreshes session-scoped MCP env for reported tmux session" do
    root = tmp_repo!("report-worktree-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = Tmux.session_name("runtime", "wt-agent")

    git!(root, ["worktree", "add", "-b", "agent-branch", worktree, "main"])
    seed_workspace("ws-report-worktree", root)

    # staging_home/2 only honors an inherited CASEIN_AGENT_MCP_HOME when it
    # already matches the workspace-name-derived default (see
    # MCPMaterializer), so isolate this test's MCP staging dir via a fake
    # HOME rather than CASEIN_AGENT_MCP_HOME directly.
    home = tmp_dir!("report-worktree-home")
    staging = Path.join([home, ".casein", "agent-mcp", "runtime"])
    previous_home = System.get_env("HOME")

    System.put_env("HOME", home)
    System.delete_env("CASEIN_AGENT_MCP_HOME")

    on_exit(fn ->
      restore_system_env("HOME", previous_home)
    end)

    Application.put_env(:casein, :api_token, "terminal-tools-token")
    Application.put_env(:casein, :agent_mcp_base_url, "http://127.0.0.1:4000")
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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

    assert env["CASEIN_WORKSPACE_ID"] == "ws-report-worktree"
    assert env["CASEIN_WORKSPACE_NAME"] == "runtime"
    assert env["CASEIN_CHECKOUT"] == worktree
    assert env["CASEIN_TMUX_SESSION"] == tmux_session
    assert env["CASEIN_TERMINAL_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    assert env["CASEIN_TERMINAL_MCP_URL"] =~ "tmux_session=#{tmux_session}"
    assert env["CASEIN_PREVIEW_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    assert env["CASEIN_PREVIEW_MCP_URL"] =~ "tmux_session=#{tmux_session}"
    assert env["CASEIN_ARTIFACT_MCP_URL"] =~ "workspace_id=ws-report-worktree"
    refute env["CASEIN_ARTIFACT_MCP_URL"] =~ "tmux_session="
    assert File.read!(Path.join(staging, "env.sh")) =~ "CASEIN_TMUX_SESSION='#{tmux_session}'"
  end

  test "agent pane shortcuts target only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
      {session, "%2"} => "# Casein agent pane\n"
    })

    assert {:ok, %{session: ^session, pane: "%2"}} =
             TerminalTools.invoke("terminal_agent_pane", %{"workspace_id" => "alpha"})

    assert {:ok, %{target: "%2", status: "sent", write_id: write_id, receipt: receipt}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "command" => "mix test",
               "confirm" => false
             })

    assert is_binary(write_id)
    assert receipt.write_id == write_id
    assert receipt.pane_id == "%2"
    assert receipt.observed in [true, "unknown"]
    assert_receive {:fake_tmux_send_command, ^session, "%2", "mix test", _opts}
  end

  test "terminal_context returns safe agent-pane next step" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
      {session, "%2"} => "# Casein agent pane\n"
    })

    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => "alpha"})

    assert payload.recommended_session == session
    assert payload.recommended_agent_pane == "%2"
    assert payload.safe_to_mutate == true
    assert payload.next_tool == "terminal_send_agent_command"
    assert payload.next_arguments == %{workspace_id: "alpha", session: session}
    assert payload.agent_pane.status == "dedicated_pane_present"
    assert payload.agent_pane.ready == false
    assert payload.agent_pane.safe_to_target == true
  end

  test "session discovery exposes stable dev_ide identity metadata" do
    workspace_id = "ws-dev-ide"
    workspace_path = "/data/workspaces/dalexandre/dev_ide"
    session = Tmux.session_name("dev_ide", "wt-coordinator")

    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: "dev_ide",
               path: workspace_path,
               status: :running
             })

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "operator", active: true, panes: 2, activity: 10}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: workspace_path,
          role: "operator"
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          current_command: "opencode",
          current_path: "/data/casein-agent-worktrees/dev-ide-worker",
          role: "agent"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{
      session => %{attached: true, session_alias: "dev_ide coordinator"}
    })

    on_exit(fn -> TmuxCtl.Test.FakeState.delete(:fake_tmux_session_meta) end)

    assert {:ok, payload} =
             TerminalTools.list_sessions(%{
               "workspace_id" => workspace_id,
               "session" => session
             })

    assert payload.recommended_session == session
    refute Map.get(payload, :ambiguous, false)

    assert [candidate] = payload.sessions
    assert candidate.session == session
    assert candidate.session_alias == "dev_ide coordinator"
    assert candidate.workspace_name == "dev_ide"
    assert candidate.workspace_path == workspace_path

    assert candidate.paths == [
             "/data/casein-agent-worktrees/dev-ide-worker",
             workspace_path
           ]

    assert candidate.pane_roles == ["agent", "operator"]
    assert candidate.operator_pane_id == "%1"
    assert candidate.agent_pane_id == "%2"
    assert candidate.role == "operator"
    assert candidate.role_source == "pane_role"
  end

  test "terminal_context identifies the operator and gives an actionable absent-agent step" do
    workspace_id = "ws-dev-ide-missing-agent"
    workspace_path = "/data/workspaces/dalexandre/dev_ide"
    session = Tmux.session_name("dev_ide", "wt-operator")

    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: "dev_ide",
               path: workspace_path,
               status: :running
             })

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "operator", active: true, panes: 1, activity: 10}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "bash",
          current_path: workspace_path
        }
      ]
    })

    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{
               "workspace_id" => workspace_id,
               "session" => session
             })

    assert payload.operator_pane == %{
             pane_id: "%1",
             role: "operator_candidate",
             role_marked: false,
             role_source: "workspace_root_single_pane",
             status: "identified"
           }

    assert payload.session_identity.session == session
    assert payload.session_identity.workspace_name == "dev_ide"
    assert payload.session_identity.workspace_path == workspace_path
    assert payload.session_identity.path == workspace_path
    assert payload.session_identity.role == "operator_candidate"

    assert payload.agent_pane.status == "absent"
    assert payload.agent_pane.ready == false
    assert payload.agent_pane.safe_to_target == false
    assert payload.agent_pane.suggested_template == "agent_pair"
    assert payload.agent_pane.next_step =~ "worker_launch"
    assert payload.reason == "dedicated_agent_pane_absent"
    assert payload.safe_to_mutate == false
    assert payload.next_tool == "worker_launch"
    assert payload.next_arguments == %{workspace_id: workspace_id, session: session}
    assert payload.next_required_arguments == ["runtime", "task_slug", "initial_prompt"]
  end

  test "terminal_topology identifies the unique workspace-root operator beside worker windows" do
    workspace_id = "ws-dev-ide-workers"
    workspace_path = "/data/workspaces/dalexandre/dev_ide"
    session = Tmux.session_name("dev_ide", "wt-workers")

    assert {:ok, _record} =
             State.sync(%Workspace{
               id: workspace_id,
               name: "dev_ide",
               path: workspace_path,
               status: :running
             })

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "operator", active: true, panes: 1, activity: 10},
        %{id: "@2", index: 1, name: "worker-task", active: false, panes: 1, activity: 9}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "opencode",
          current_path: workspace_path
        },
        %{
          id: "%2",
          window_id: "@2",
          index: 0,
          active: true,
          current_command: "opencode",
          current_path: "/data/casein-agent-worktrees/worker-task"
        }
      ]
    })

    assert {:ok, payload} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => workspace_id,
               "session" => session
             })

    assert payload.operator_pane == %{
             pane_id: "%1",
             role: "operator_candidate",
             role_marked: false,
             role_source: "workspace_root_unique_pane",
             status: "identified"
           }

    assert payload.session_identity.operator_pane_id == "%1"
    assert payload.session_identity.role == "operator_candidate"
    assert payload.agent_pane.status == "absent"
    assert payload.safe_to_mutate == false
  end

  test "terminal_context recommends the attached session when ambiguous" do
    prefix = Tmux.workspace_session_prefix("alpha")
    stale = prefix <> "stale"
    live = prefix <> "live"

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      stale => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 900}],
      live => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 5}]
    })

    # The detached session is more recent; the operator's attached one must win.
    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{live => %{attached: true}})
    on_exit(fn -> TmuxCtl.Test.FakeState.delete(:fake_tmux_session_meta) end)

    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => "alpha"})

    assert payload.ambiguous
    refute payload.safe_to_mutate
    assert payload.recommended_session == live
    assert payload.recommendation_reason == "only_attached_session"
    assert payload.next_tool == "terminal_context"
    assert payload.next_arguments == %{workspace_id: "alpha", session: live}
  end

  test "terminal_context recommends the most recent session when none is attached" do
    prefix = Tmux.workspace_session_prefix("alpha")
    older = prefix <> "older"
    newer = prefix <> "newer"

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      older => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 10}],
      newer => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 20}]
    })

    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => "alpha"})

    assert payload.ambiguous
    assert payload.recommended_session == newer
    assert payload.recommendation_reason == "most_recent_activity"
    assert payload.next_arguments == %{workspace_id: "alpha", session: newer}
  end

  describe "caller-pane anchoring" do
    setup do
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())
      :ok
    end

    test "terminal_context resolves ambiguous sessions to the caller's session" do
      prefix = Tmux.workspace_session_prefix("alpha")
      other = prefix <> "other"
      mine = prefix <> "mine"

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        # The other session is more recent AND attached — both heuristics
        # would pick it; the caller's own pane must win over both.
        other => [%{id: "@1", index: 0, name: "a", active: true, panes: 1, activity: 900}],
        mine => [%{id: "@1", index: 0, name: "b", active: true, panes: 1, activity: 5}]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{other => %{attached: true}})
      on_exit(fn -> TmuxCtl.Test.FakeState.delete(:fake_tmux_session_meta) end)

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        other => [%{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"}],
        mine => [%{id: "%9", window_id: "@1", index: 0, active: true, current_command: "bash"}]
      })

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_context", %{
                 "workspace_id" => "alpha",
                 "caller_pane" => "%9"
               })

      refute Map.get(payload, :ambiguous)
      assert payload.recommended_session == mine
    end

    test "terminal_topology returns the caller anchor with adjacent panes" do
      session = Tmux.session_name("alpha", "main")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{id: "@1", index: 0, name: "work", active: false, panes: 2, activity: 10},
          %{id: "@2", index: 1, name: "focus", active: true, panes: 1, activity: 20}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: false,
            current_command: "claude",
            left: 0,
            top: 0,
            width: 100,
            height: 50
          },
          %{
            id: "%2",
            window_id: "@1",
            index: 1,
            active: true,
            current_command: "bash",
            left: 101,
            top: 0,
            width: 100,
            height: 50
          },
          # The operator is focused here; it must NOT leak into the caller
          # anchor of a caller living in window @1.
          %{id: "%3", window_id: "@2", index: 0, active: true, current_command: "vim"}
        ]
      })

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "caller_pane" => "%1"
               })

      assert payload.caller.pane == "%1"
      assert payload.caller.window_id == "@1"
      assert [%{id: "%2", direction: "right"}] = payload.caller.adjacent_panes
      assert payload.window_active_panes == %{"@1" => "%2", "@2" => "%3"}
      assert payload.active_pane_note =~ "operator"
    end

    test "terminal_topology warns when panes share one git worktree" do
      session = Tmux.session_name("alpha", "main")
      shared = tmp_repo!("shared")
      own = tmp_repo!("own")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{id: "@1", index: 0, name: "w1", active: true, panes: 1, activity: 10},
          %{id: "@2", index: 1, name: "w2", active: false, panes: 1, activity: 10},
          %{id: "@3", index: 2, name: "w3", active: false, panes: 1, activity: 10}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          agent_pane_at("%1", "@1", shared),
          agent_pane_at("%2", "@2", shared),
          agent_pane_at("%3", "@3", own)
        ]
      })

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      # Three agents in one worktree corrupt each other's git index rather than
      # failing cleanly; the operator should not have to discover that by hand.
      assert %{paths: paths, note: note} = payload.shared_worktrees
      assert Map.keys(paths) == [shared]
      assert Enum.sort(paths[shared]) == ["%1", "%2"]
      assert note =~ "same git worktree"

      by_id = Map.new(payload.panes, &{&1.id, &1})
      assert by_id["%1"].worktree_shared_with == ["%2"]
      assert by_id["%3"].worktree_path == own
      refute Map.has_key?(by_id["%3"], :worktree_shared_with)
    end

    test "terminal_topology omits the warning when every pane has its own worktree" do
      session = Tmux.session_name("alpha", "main")
      a = tmp_repo!("solo-a")
      b = tmp_repo!("solo-b")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{id: "@1", index: 0, name: "w1", active: true, panes: 1, activity: 10},
          %{id: "@2", index: 1, name: "w2", active: false, panes: 1, activity: 10}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [agent_pane_at("%1", "@1", a), agent_pane_at("%2", "@2", b)]
      })

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      refute Map.has_key?(payload, :shared_worktrees)
    end

    # The topology warning reaches whoever asked for the topology — not the
    # caller about to run `git reset --hard` in the shared tree. These cover the
    # same signal answering at the moment of the write.
    test "terminal_send_command refuses a git write into a shared worktree" do
      %{session: session, shared: shared} = shared_worktree_session!()

      assert {:error, error} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git reset --hard origin/master",
                 "confirm" => false
               })

      assert error.error == :shared_worktree_mutation
      assert error.refused
      assert error.worktree_path == shared
      assert error.shared_with == ["%2"]
      assert error.git_subcommand == "reset"
      # The message has to name the tree and the other occupants, or the caller
      # needs a second round trip to act on it.
      assert error.message =~ shared
      assert error.message =~ "%2"
      assert error.remedy =~ "spawn-agent-worker.sh"
      assert error.remedy =~ "allow_shared_worktree"

      refute_receive {:fake_tmux_send_command, _, _, _, _}
    end

    test "terminal_send_command allows the same write in an unshared worktree" do
      %{session: session} = shared_worktree_session!()

      assert {:ok, _payload} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%3",
                 "command" => "git reset --hard origin/master",
                 "confirm" => false
               })

      assert_receive {:fake_tmux_send_command, _, "%3", "git reset --hard origin/master", _}
    end

    test "terminal_send_command allows a read-only git command in a shared worktree" do
      %{session: session} = shared_worktree_session!()

      assert {:ok, _payload} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git status --porcelain",
                 "confirm" => false
               })

      assert_receive {:fake_tmux_send_command, _, "%1", "git status --porcelain", _}
    end

    # Sharing a worktree is a deliberate mode (agent_worktree_ensure adopts one
    # on purpose), so the block is soft — its job is to make the sharing known.
    test "allow_shared_worktree lets a deliberate share through" do
      %{session: session} = shared_worktree_session!()

      assert {:ok, _payload} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git commit -am wip",
                 "allow_shared_worktree" => true,
                 "confirm" => false
               })

      assert_receive {:fake_tmux_send_command, _, "%1", "git commit -am wip", _}
    end

    # The tree that matters is the one being written, not the one the pane sits
    # in. Casein's own scripts run `git -C <primary>` from inside a worktree
    # constantly; refusing those would get the guard switched off.
    test "a git -C write aimed at an unshared tree passes from a shared pane" do
      %{session: session, own: own} = shared_worktree_session!()

      assert {:ok, _payload} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git -C #{own} commit -m x",
                 "confirm" => false
               })

      assert_receive {:fake_tmux_send_command, _, "%1", _, _}
    end

    test "a git -C write aimed at the shared tree is refused from an unshared pane" do
      %{session: session, shared: shared} = shared_worktree_session!()

      assert {:error, error} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%3",
                 "command" => "git -C #{shared} reset --hard",
                 "confirm" => false
               })

      assert error.error == :shared_worktree_mutation
      assert error.worktree_path == shared
      # %3 is not in that tree, so both of its occupants are named.
      assert Enum.sort(error.shared_with) == ["%1", "%2"]
    end

    # Casein runs one agent per window, so panes sharing a worktree *inside* one
    # window are that agent's own surfaces — its shell plus a file pane or a
    # preview split, all inheriting its cwd. On the live box that is roughly half
    # of all shared-worktree hits, and refusing them would refuse an agent its own
    # commits. The topology warning still reports them, which is right for a
    # warning; a refusal has to be sure.
    test "panes sharing a worktree inside one window are one agent, not a conflict" do
      session = Tmux.session_name("alpha", "main")
      shared = tmp_repo!("one-window")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [%{id: "@1", index: 0, name: "w1", active: true, panes: 2, activity: 10}]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          agent_pane_at("%1", "@1", shared),
          agent_pane_at("%2", "@1", shared)
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      assert {:ok, _payload} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git commit -am wip",
                 "confirm" => false
               })

      assert_receive {:fake_tmux_send_command, _, "%1", "git commit -am wip", _}
    end

    # ...but a third window in that same tree is the incident this exists for,
    # and the refusal names only the other windows.
    test "a pane in another window makes the same tree a conflict" do
      session = Tmux.session_name("alpha", "main")
      shared = tmp_repo!("two-windows")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{id: "@1", index: 0, name: "w1", active: true, panes: 2, activity: 10},
          %{id: "@2", index: 1, name: "w2", active: false, panes: 1, activity: 10}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          agent_pane_at("%1", "@1", shared),
          agent_pane_at("%2", "@1", shared),
          agent_pane_at("%3", "@2", shared)
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

      assert {:error, error} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "command" => "git commit -am wip",
                 "confirm" => false
               })

      assert error.error == :shared_worktree_mutation
      # %2 is this agent's own second pane; only the other window is named.
      assert error.shared_with == ["%3"]
    end

    # send_keys is the same command line, typed one keystroke short of Enter.
    test "terminal_send_keys is guarded too" do
      %{session: session} = shared_worktree_session!()

      assert {:error, %{error: :shared_worktree_mutation}} =
               TerminalTools.invoke("terminal_send_keys", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "keys" => "git clean -fdx"
               })

      # The pass-through half is asserted against the guard rather than the tool:
      # the fake adapter answers a two-arity send_keys with :session_not_alive
      # regardless of session, so no terminal_send_keys call can succeed under it.
      assert :ok = SharedWorktreeGuard.check(session, "%1", "C-c")
      assert :ok = SharedWorktreeGuard.check(session, "%1", "git status")
    end

    test "terminal_agent_pane never resolves to the caller's own pane" do
      session = Tmux.session_name("alpha", "main")

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
        {session, "%2"} => "# Casein agent pane\n"
      })

      assert {:error, %{error: :caller_is_only_agent_pane, caller_pane: "%2"}} =
               TerminalTools.invoke("terminal_agent_pane", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "caller_pane" => "%2"
               })
    end

    test "terminal_agent_pane prefers a peer in the caller's window" do
      session = Tmux.session_name("alpha", "main")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [
          %{id: "@1", index: 0, name: "first", active: true, panes: 1, activity: 10},
          %{id: "@2", index: 1, name: "second", active: false, panes: 2, activity: 20}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          # Listed first: an agent pane in another window. Without the caller
          # anchor, first-match would (wrongly) pick it.
          %{id: "%2", window_id: "@1", index: 0, active: true, current_command: "bash"},
          %{id: "%4", window_id: "@2", index: 0, active: false, current_command: "bash"},
          %{id: "%5", window_id: "@2", index: 1, active: true, current_command: "bash"}
        ]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
        {session, "%2"} => "# Casein agent pane\n",
        {session, "%4"} => "# Casein agent pane\n"
      })

      assert {:ok, %{pane: "%4"}} =
               TerminalTools.invoke("terminal_agent_pane", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "caller_pane" => "%5"
               })
    end

    test "terminal_capture without pane early-binds the active pane and warns" do
      session = Tmux.session_name("alpha", "main")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 10}]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"}
        ]
      })

      assert {:ok, payload} =
               TerminalTools.invoke("terminal_capture", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      assert payload.target == "%1"
      assert payload.target_was_active_pane
      assert payload.targeting_warning =~ "operator"
    end

    test "terminal_report_agent_state without pane defaults to the caller's own pane" do
      session = Tmux.session_name("alpha", "main")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [%{id: "@1", index: 0, name: "work", active: true, panes: 2, activity: 10}]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          %{id: "%1", window_id: "@1", index: 0, active: true, current_command: "bash"},
          %{id: "%2", window_id: "@1", index: 1, active: false, current_command: "claude"}
        ]
      })

      assert {:ok, %{target: "%1", state: "done"}} =
               TerminalTools.invoke("terminal_report_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "caller_pane" => "%1",
                 "state" => "done"
               })
    end
  end

  test "terminal_paste_agent_text targets only the marked agent pane" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
      {session, "%2"} => "# Casein agent pane\n"
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
               "submit" => true,
               "confirm" => false
             })

    assert_receive {:fake_tmux_paste_text, ^session, "%2", "one\ntwo", opts}
    # Enter must not ride with the paste — that is the OpenCode double-Enter race.
    refute opts[:submit]
    assert_receive {:fake_tmux_keys, ^session, "%2", "Enter", _}
  end

  test "terminal_paste_agent_text accepts an explicit pane without agent_pair" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 10}]
    })

    # No role-marked agent pane — only an ordinary worker pane id.
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%9", window_id: "@1", index: 0, active: true, current_command: "opencode"}
      ]
    })

    assert {:ok, %{target: "%9", status: "sent"}} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "pane" => "%9",
               "text" => "fleet brief\nline two",
               "submit" => true,
               "confirm" => false
             })

    assert_receive {:fake_tmux_paste_text, ^session, "%9", "fleet brief\nline two", opts}
    refute opts[:submit]
    # PaneSubmit owns Enter after the paste settles.
    assert_receive {:fake_tmux_keys, ^session, "%9", "Enter", _}
  end

  test "terminal_paste_agent_text with submit:true does not fold Enter into paste" do
    session = agent_pair_session!()
    Casein.Terminals.AgentState.clear()

    assert {:ok, result} =
             TerminalTools.invoke("terminal_paste_agent_text", %{
               "workspace_id" => "alpha",
               "session" => session,
               "text" => "long fleet brief\nwith\nmany\nlines",
               "submit" => true,
               "confirm" => false
             })

    assert result.status == "sent"
    assert_receive {:fake_tmux_paste_text, ^session, "%2", text, opts}
    assert text =~ "long fleet brief"
    # Race contract: paste-buffer must not carry Enter; PaneSubmit presses it.
    refute Keyword.get(opts, :submit)
    assert_receive {:fake_tmux_keys, ^session, "%2", "Enter", _}
  end

  test "capture strips ANSI escapes by default" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
      {session, "%2"} => "# Casein agent pane\n"
    })

    assert {:ok, %{pane: "%2", reason: "agent_pair_marker"}} =
             TerminalTools.invoke("terminal_agent_pane", %{
               "workspace_id" => "alpha",
               "session" => session
             })
  end

  test "send_agent_command requires the agent_pair marker" do
    session = Tmux.session_name("alpha", "main")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
    session_a = prefix <> "a"
    session_b = prefix <> "b"

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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

  defp seed_live_session!(session) do
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

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
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/workspace"
        }
      ]
    })
  end

  defp hang_workspace_source! do
    previous = Application.get_env(:casein, :workspace_source)
    Application.put_env(:casein, :workspace_source, __MODULE__.HangingWorkspaceSource)

    on_exit(fn -> restore_app_env(:workspace_source, previous) end)
  end

  defp timed_ms(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
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
        metadata: %{"id" => id, "repo" => "casein", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  # Two panes in one worktree, one pane in its own — the shape the shared-worktree
  # guard exists for.
  defp shared_worktree_session! do
    session = Tmux.session_name("alpha", "main")
    shared = tmp_repo!("guard-shared")
    own = tmp_repo!("guard-own")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "w1", active: true, panes: 1, activity: 10},
        %{id: "@2", index: 1, name: "w2", active: false, panes: 1, activity: 10},
        %{id: "@3", index: 2, name: "w3", active: false, panes: 1, activity: 10}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        agent_pane_at("%1", "@1", shared),
        agent_pane_at("%2", "@2", shared),
        agent_pane_at("%3", "@3", own)
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    %{session: session, shared: shared, own: own}
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
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "casein-terminal-tools-#{System.unique_integer([:positive])}-#{name}")
    make_tree_writable(path)
    File.rm_rf!(path)
    File.mkdir_p!(path)

    on_exit(fn ->
      make_tree_writable(path)
      File.rm_rf!(path)
    end)

    path
  end

  defp make_tree_writable(path) do
    if File.exists?(path) do
      _ = File.chmod(path, 0o700)

      case File.ls(path) do
        {:ok, names} ->
          Enum.each(names, fn name ->
            child = Path.join(path, name)

            if File.dir?(child) do
              make_tree_writable(child)
            else
              _ = File.chmod(child, 0o600)
            end
          end)

        _ ->
          :ok
      end
    end

    :ok
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  describe "terminal_agent_transcript" do
    test "reads normalized entries from the pane's reported transcript_path" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      path = write_claude_fixture!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, nil,
          transcript_path: path
        )

      assert {:ok, result} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "tail" => 5
               })

      assert result.target == "%2"
      assert result.transcript_path == path
      assert is_list(result.entries)
      assert result.cursor
      assert result.total_on_branch >= 1
    end

    test "returns no_transcript with a machine-readable reason when the pane has no pointer" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:error, %{error: :no_transcript, reason: :no_hook}} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })
    end

    test "re-resolves from agent_session_id after the cached path is gone" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      {path, session_id} = write_claude_session_fixture!("/workspace")
      stale = path <> ".gone"

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, nil,
          transcript_path: stale,
          agent_session_id: session_id
        )

      assert {:ok, result} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "tail" => 5
               })

      assert result.transcript_path == path
      assert result.entries != []
    end

    test "keeps resolving after a later report omits transcript_path" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      path = write_claude_fixture!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, nil,
          transcript_path: path,
          agent_session_id: "sess-keep"
        )

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, "still going",
          agent_session_id: "sess-keep"
        )

      assert {:ok, result} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      assert result.transcript_path == path
    end

    test "returns path_missing when the session file is not on disk" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, nil,
          agent_session_id: "missing-session-id"
        )

      assert {:error, %{error: :no_transcript, reason: :path_missing}} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })
    end

    test "returns unsupported_runtime for hook-less panes" do
      session = Tmux.session_name("alpha", "wait")
      Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        session => [%{id: "@1", index: 0, name: "work", active: true, panes: 1, activity: 1}]
      })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [agent_pane_at("%2", "@1", "/workspace")]
      })

      Casein.Terminals.AgentState.clear()

      assert {:error, %{error: :no_transcript, reason: :unsupported_runtime}} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%2"
               })
    end

    test "exposes transcript_path on terminal_topology" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      path = write_claude_fixture!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :working, nil,
          transcript_path: path,
          agent_session_id: "topo-session"
        )

      assert {:ok, topology} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      by_id = Map.new(topology.panes, &{&1.id, &1})
      assert by_id["%2"].transcript_path == path
      refute Map.has_key?(by_id["%1"], :transcript_path)
    end
  end

  describe "terminal_report_agent_state" do
    test "records a report against the dedicated agent pane" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, result} =
               TerminalTools.invoke("terminal_report_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "state" => "blocked",
                 "message" => "awaiting permission",
                 "agent_session_id" => "grok-session-123"
               })

      assert result.target == "%2"
      assert result.state == "blocked"
      assert result.agent_session_id == "grok-session-123"
      assert result.status == "reported"
      entry = Casein.Terminals.AgentState.get(session, "%2")
      assert entry.state == :blocked
      assert entry.agent_session_id == "grok-session-123"
    end

    test "reports pending mail so a pull-only mailbox does not need to be guessed at" do
      # OB#20478: mail is never pushed into a pane, so an agent had no way to
      # learn it had been steered mid-flight. The count rides the call every
      # agent already makes.
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, result} =
               TerminalTools.invoke("terminal_report_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "state" => "working"
               })

      assert Map.has_key?(result, :pending_mail)
      # nil ("could not determine") and 0 ("nothing waiting") are different
      # answers and must not be collapsed.
      assert is_nil(result.pending_mail) or is_integer(result.pending_mail)
    end

    test "send_agent_command reports a dispatch working state for the agent pane" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, %{target: "%2", status: "sent"}} =
               TerminalTools.invoke("terminal_send_agent_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "command" => "mix test",
                 "confirm" => false
               })

      entry = Casein.Terminals.AgentState.get(session, "%2")
      assert entry.state == :working
      assert entry.source == :dispatch
      assert entry.message == "mix test"
    end

    test "paste_agent_text reports working only when submitting" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, %{target: "%2"}} =
               TerminalTools.invoke("terminal_paste_agent_text", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "text" => "draft, not submitted"
               })

      assert Casein.Terminals.AgentState.get(session, "%2") == nil

      assert {:ok, %{target: "%2"}} =
               TerminalTools.invoke("terminal_paste_agent_text", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "text" => "run the suite",
                 "submit" => true,
                 "confirm" => false
               })

      entry = Casein.Terminals.AgentState.get(session, "%2")
      assert entry.state == :working
      assert entry.source == :dispatch
    end

    test "terminal_send_command returns submitted fields after confirm" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      # Frozen screen → confirm does not retry Enter and fails the tool call; a
      # sent status must never be mistaken for a delivered prompt.
      TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
        {session, "%2"} => "> idle composer"
      })

      assert {:error, result} =
               TerminalTools.invoke("terminal_send_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%2",
                 "command" => "echo brief"
               })

      assert result.submitted == false
      assert result.delivery == "not_confirmed"
      assert result.enter_presses == 1
      # send_command targets the pane id as the tmux session arg when pane is explicit.
      assert_receive {:fake_tmux_send_command, "%2", "%2", "echo brief", _}
    end

    test "rejects an unknown state" do
      session = agent_pair_session!()

      assert {:error, :invalid_state} =
               TerminalTools.invoke("terminal_report_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "state" => "napping"
               })
    end

    test "rejects invalid Grok attachment metadata before persisting agent state" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:error, {:invalid_grok_attachment, :invalid_grok_attachment_metadata}} =
               TerminalTools.invoke("terminal_report_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "state" => "working",
                 "agent_runtime" => "grok",
                 "source" => "hook",
                 "agent_session_id" => "unverified-session"
               })

      assert Casein.Terminals.AgentState.get(session, "%2") == nil
    end
  end

  describe "terminal_request_clarification" do
    test "creates one durable request only for the explicit role-marked agent pane" do
      session = agent_pair_session!()
      prepare_local_workspace!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :blocked, nil,
          agent_session_id: "agent-task-123"
        )

      params = %{
        "workspace_id" => "alpha",
        "session" => session,
        "pane" => "%2",
        "request_id" => "clarification-request-1",
        "agent_session_id" => "agent-task-123",
        "question" => "Should I run the focused suite?"
      }

      assert {:ok, %{status: "created", target: "%2", target_role: "agent"} = first} =
               TerminalTools.invoke("terminal_request_clarification", params)

      assert {:ok, %{status: "duplicate", request_event_id: event_id}} =
               TerminalTools.invoke("terminal_request_clarification", params)

      assert event_id == first.request_event_id

      assert [event] =
               AgentEvents.recent_for("alpha")
               |> Enum.filter(&(&1.event_type == "agent.clarification_requested"))

      assert event.event_type == "agent.clarification_requested"
      assert event.payload["question"] == "Should I run the focused suite?"

      refute Map.has_key?(first, :question)
      refute Jason.encode!(first) =~ "focused suite"

      assert {:error, :intervention_target_role_mismatch} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{params | "pane" => "%1", "request_id" => "clarification-request-2"}
               )

      assert Enum.count(
               AgentEvents.recent_for("alpha"),
               &(&1.event_type == "agent.clarification_requested")
             ) == 1

      assert {:error, :agent_session_mismatch} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{params | "agent_session_id" => "invented-task"}
               )

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          %{id: "%1", window_id: "@1", active: false, role: "operator"},
          %{id: "%2", window_id: "@1", active: true, role: "agent"}
        ]
      })

      assert {:error, :intervention_target_focused} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{params | "request_id" => "clarification-request-focused"}
               )
    end

    test "rejects multiline, oversized, and malformed request data before persistence" do
      session = agent_pair_session!()
      prepare_local_workspace!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :blocked, nil,
          agent_session_id: "agent-task-456"
        )

      base = %{
        "workspace_id" => "alpha",
        "session" => session,
        "pane" => "%2",
        "request_id" => "clarification-request-3",
        "agent_session_id" => "agent-task-456",
        "question" => "Need a decision"
      }

      assert {:error, :question_invalid_characters} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{base | "question" => "first\nsecond"}
               )

      assert {:error, :question_too_long} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{base | "question" => String.duplicate("x", 201)}
               )

      assert {:error, :invalid_request_id} =
               TerminalTools.invoke(
                 "terminal_request_clarification",
                 %{base | "request_id" => "bad"}
               )

      refute Enum.any?(
               AgentEvents.recent_for("alpha"),
               &(&1.event_type == "agent.clarification_requested")
             )
    end
  end

  describe "terminal_request_human_input" do
    test "creates durable direction and blocker requests with declared actions" do
      session = agent_pair_session!()
      prepare_local_workspace!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :blocked, nil,
          agent_session_id: "agent-task-human-input"
        )

      direction = %{
        "workspace_id" => "alpha",
        "session" => session,
        "pane" => "%2",
        "request_id" => "human-direction-request-1",
        "agent_session_id" => "agent-task-human-input",
        "kind" => "direction",
        "prompt" => "Which compatible path should I take?",
        "choices" => ["Keep compatibility", "Migrate callers"]
      }

      assert {:ok, %{status: "created", kind: "direction"} = created} =
               TerminalTools.invoke("terminal_request_human_input", direction)

      assert {:ok, %{status: "duplicate", request_event_id: event_id}} =
               TerminalTools.invoke("terminal_request_human_input", direction)

      assert event_id == created.request_event_id

      assert [event] =
               AgentEvents.recent_for("alpha")
               |> Enum.filter(&(&1.event_type == "agent.clarification_requested"))

      assert event.payload["request_kind"] == "direction"
      assert event.payload["response_kind"] == "choice"
      assert event.payload["choices"] == ["Keep compatibility", "Migrate callers"]
      refute Map.has_key?(created, :prompt)
      refute Map.has_key?(created, :choices)

      assert {:error, :idempotency_key_reused} =
               TerminalTools.invoke(
                 "terminal_request_human_input",
                 %{direction | "choices" => ["Keep compatibility", "Stop work"]}
               )

      assert {:error, :choices_required} =
               TerminalTools.invoke(
                 "terminal_request_human_input",
                 %{
                   direction
                   | "request_id" => "human-blocker-request-1",
                     "kind" => "blocker",
                     "choices" => []
                 }
               )

      assert {:error, :duplicate_choices} =
               TerminalTools.invoke(
                 "terminal_request_human_input",
                 %{
                   direction
                   | "request_id" => "human-direction-request-2",
                     "choices" => ["Same", "Same"]
                 }
               )
    end

    test "clarification compatibility remains free-text and rejects choice injection" do
      session = agent_pair_session!()
      prepare_local_workspace!()

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :blocked, nil,
          agent_session_id: "agent-task-human-clarification"
        )

      assert {:error, :choices_not_allowed} =
               TerminalTools.invoke("terminal_request_human_input", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%2",
                 "request_id" => "human-clarification-request-1",
                 "agent_session_id" => "agent-task-human-clarification",
                 "kind" => "clarification",
                 "prompt" => "What value should I use?",
                 "choices" => ["client-injected-action"]
               })
    end
  end

  describe "terminal_wait_agent_state" do
    test "include_answer returns the final assistant message when done" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      path = write_claude_fixture!("Done.")

      :ok =
        Casein.Terminals.AgentState.report("alpha", session, "%2", :done, nil,
          transcript_path: path
        )

      assert {:ok, result} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["done"],
                 "include_answer" => true,
                 "timeout_ms" => 2_000
               })

      assert result.matched == true
      assert result.answer == "Done."
    end

    test "returns immediately when the pane is already in a target state" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      :ok = Casein.Terminals.AgentState.report("alpha", session, "%2", :blocked, "perm")

      assert {:ok, result} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["blocked"],
                 "timeout_ms" => 2_000
               })

      assert result.matched == true
      assert result.timed_out == false
      assert result.state == "blocked"
    end

    test "times out (not an error) when the state is never reached" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, result} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["done"],
                 "timeout_ms" => 60
               })

      assert result.matched == false
      assert result.timed_out == true
      assert is_binary(result.state)
      assert is_integer(result.waited_ms)
      assert result.waited_ms >= 0
    end

    test "advertised-max timeout_ms returns structured timed_out instead of hanging" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      previous = Application.get_env(:casein, :agent_state_wait_max_ms)
      Application.put_env(:casein, :agent_state_wait_max_ms, 80)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:casein, :agent_state_wait_max_ms, previous),
          else: Application.delete_env(:casein, :agent_state_wait_max_ms)
      end)

      started = System.monotonic_time(:millisecond)

      assert {:ok, result} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["done"],
                 "timeout_ms" => Casein.Agents.TerminalTools.Helpers.wait_timeout_default_ms()
               })

      elapsed = System.monotonic_time(:millisecond) - started

      assert result.matched == false
      assert result.timed_out == true
      assert is_binary(result.state)
      assert is_integer(result.waited_ms)
      assert result.waited_ms < 500
      assert elapsed < 500
    end

    test "unblocks when a report arrives mid-wait" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()
      parent = self()

      spawn(fn ->
        await_blocked(parent)
        Casein.Terminals.AgentState.report("alpha", session, "%2", :done, nil)
        send(parent, :reported)
      end)

      assert {:ok, %{matched: true, state: "done"}} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["done"],
                 "timeout_ms" => 3_000
               })

      assert_receive :reported, 1_000
    end

    test "rejects an unknown target state" do
      session = agent_pair_session!()

      assert {:error, :invalid_state} =
               TerminalTools.invoke("terminal_wait_agent_state", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "states" => ["done", "napping"]
               })
    end
  end

  # A single-window session whose non-active pane %2 carries the agent_pair
  # marker, so label_target_pane/find_agent_pane resolves to %2 by default.
  defp write_claude_fixture!(assistant_suffix \\ "hello") do
    root = tmp_dir!("transcript-fixture")
    auth_root = Path.join([root, "agent-auth"])
    Application.put_env(:casein, :agent_auth_profile_root, auth_root)

    path =
      Path.join([
        auth_root,
        "profiles",
        "alice",
        "claude",
        "projects",
        "fixture",
        "session.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))

    lines = [
      Jason.encode!(%{
        "uuid" => "u1",
        "parentUuid" => nil,
        "type" => "user",
        "timestamp" => "2026-07-06T10:00:00.000Z",
        "message" => %{"role" => "user", "content" => "hello"}
      }),
      Jason.encode!(%{
        "uuid" => "a1",
        "parentUuid" => "u1",
        "type" => "assistant",
        "timestamp" => "2026-07-06T10:00:01.000Z",
        "message" => %{"role" => "assistant", "content" => assistant_suffix}
      })
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp write_claude_session_fixture!(cwd, assistant_suffix \\ "hello") do
    session_id = "sess-#{System.unique_integer([:positive])}"
    home = tmp_dir!("transcript-home")
    System.put_env("HOME", home)

    path =
      Path.join([
        home,
        ".claude",
        "projects",
        Casein.Agents.Transcripts.Discovery.project_slug(cwd),
        session_id <> ".jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))

    lines = [
      Jason.encode!(%{
        "uuid" => "u1",
        "parentUuid" => nil,
        "type" => "user",
        "timestamp" => "2026-07-06T10:00:00.000Z",
        "message" => %{"role" => "user", "content" => "hello"}
      }),
      Jason.encode!(%{
        "uuid" => "a1",
        "parentUuid" => "u1",
        "type" => "assistant",
        "timestamp" => "2026-07-06T10:00:01.000Z",
        "message" => %{"role" => "assistant", "content" => assistant_suffix}
      })
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    {path, session_id}
  end

  describe "terminal_bind_issue" do
    setup do
      Casein.Terminals.IssueBinding.clear_all()
      on_exit(&Casein.Terminals.IssueBinding.clear_all/0)
      :ok
    end

    test "binds to the agent pane by default and shows up in terminal_topology" do
      session = agent_pair_session!()

      assert {:ok, bound} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "issue" => "#678"
               })

      # Defaults to the dedicated agent pane (%2), not the operator pane (%1).
      assert bound.target == "%2"
      assert bound.issue == 678
      assert bound.status == "bound"

      assert {:ok, topology} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      by_id = Map.new(topology.panes, &{&1.id, &1})
      assert by_id["%2"].issue == 678
      refute Map.has_key?(by_id["%1"], :issue)
      # The window carries it too, so a collapsed window still says what it is on.
      assert Enum.find(topology.windows, &(&1.id == "@1")).issue == 678
    end

    test "omitting the issue releases the binding" do
      session = agent_pair_session!()

      {:ok, _} =
        TerminalTools.invoke("terminal_bind_issue", %{
          "workspace_id" => "alpha",
          "session" => session,
          "issue" => "678"
        })

      assert {:ok, cleared} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      assert cleared.status == "cleared"
      assert cleared.issue == nil

      assert {:ok, topology} =
               TerminalTools.invoke("terminal_topology", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })

      refute Enum.any?(topology.panes, &Map.has_key?(&1, :issue))
    end

    test "a malformed issue is refused rather than bound to something wrong" do
      session = agent_pair_session!()

      assert {:error, _} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "issue" => "not-an-issue"
               })

      assert Casein.Terminals.IssueBinding.get(session, "%2") == nil
    end

    test "refuses a second live pane and names the holder" do
      session = agent_pair_session!()

      assert {:ok, _} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "issue" => "678"
               })

      assert {:error,
              %{
                error: :issue_already_bound,
                pane_id: "%2",
                window_id: "@1",
                issue: 678
              }} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "issue" => "678"
               })
    end

    test "allow_duplicate records both holders and issue_holders lists them" do
      session = agent_pair_session!()

      {:ok, _} =
        TerminalTools.invoke("terminal_bind_issue", %{
          "workspace_id" => "alpha",
          "session" => session,
          "issue" => "678"
        })

      assert {:ok, second} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "issue" => "678",
                 "allow_duplicate" => true
               })

      assert second.status == "bound"
      assert second.target == "%1"

      assert {:ok, listed} =
               TerminalTools.invoke("terminal_issue_holders", %{
                 "workspace_id" => "alpha",
                 "issue" => "#678"
               })

      assert listed.issue == 678
      assert listed.count == 2
      assert Enum.sort(Enum.map(listed.holders, & &1.pane_id)) == ["%1", "%2"]
      assert Enum.all?(listed.holders, &(&1.window_id == "@1" and &1.issue == 678))
    end

    test "a dead pane never blocks re-dispatch" do
      session = agent_pair_session!()

      {:ok, _} =
        TerminalTools.invoke("terminal_bind_issue", %{
          "workspace_id" => "alpha",
          "session" => session,
          "issue" => "678"
        })

      TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
        session => [
          %{
            id: "%1",
            window_id: "@1",
            index: 0,
            active: true,
            current_command: "claude",
            current_path: "/workspace",
            role: "operator"
          }
        ]
      })

      assert {:ok, rebound} =
               TerminalTools.invoke("terminal_bind_issue", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "pane" => "%1",
                 "issue" => "678"
               })

      assert rebound.status == "bound"
      assert rebound.target == "%1"
      assert Casein.Terminals.IssueBinding.get(session, "%2") == nil
    end
  end

  defp agent_pair_session! do
    session = Tmux.session_name("alpha", "wait")

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
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
          current_path: "/workspace",
          role: "operator"
        },
        %{
          id: "%2",
          window_id: "@1",
          index: 1,
          active: false,
          current_command: "bash",
          current_path: "/workspace",
          role: "agent"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {session, "%2"} => "# Casein agent pane\n"
    })

    session
  end

  defp prepare_local_workspace! do
    root =
      Path.join(
        System.tmp_dir!(),
        "casein-terminal-clarification-#{System.unique_integer([:positive])}"
      )

    previous_source = Application.get_env(:casein, :workspace_source)
    previous_root = Application.get_env(:casein, :workspaces_root)
    File.mkdir_p!(Path.join(root, "alpha"))
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :workspaces_root, root)

    on_exit(fn ->
      restore_app_env(:workspace_source, previous_source)
      restore_app_env(:workspaces_root, previous_root)
      File.rm_rf(root)
    end)
  end

  defp agent_pane_at(id, window_id, current_path) do
    %{
      id: id,
      window_id: window_id,
      index: 0,
      active: true,
      current_command: "opencode",
      current_path: current_path,
      role: "agent",
      left: 0,
      top: 0,
      width: 100,
      height: 50
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  # Poll until `pid` is blocked in receive (status :waiting), using receive-based
  # backoff instead of Process.sleep so the mid-wait report cannot race the waiter.
  defp await_blocked(pid) do
    case Process.info(pid, :status) do
      {:status, :waiting} ->
        :ok

      _ ->
        receive do
        after
          2 -> :ok
        end

        await_blocked(pid)
    end
  end
end

defmodule Casein.Agents.TerminalToolsTest.HangingWorkspaceSource do
  @moduledoc false
  @behaviour Casein.WorkspaceSource

  @impl true
  def get(id, _auth \\ nil) do
    raise "WorkspaceSource.get/2 must not be called from terminal tools (id=#{inspect(id)})"
  end

  @impl true
  def list(_opts \\ [], _auth \\ nil), do: {:ok, []}

  @impl true
  def create(_params, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def start(_id, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def stop(_id, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def delete(_id, _opts \\ [], _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def stream_logs(_id, _service, _pid), do: {:error, :unsupported}

  @impl true
  def safe_host_path(_), do: {:error, :unsupported}

  @impl true
  def safe_host_loc(_), do: {:error, :unsupported}
end
