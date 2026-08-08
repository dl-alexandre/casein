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
    assert {:error, :workspace_mismatch} =
             TerminalTools.invoke("terminal_topology", %{
               "workspace_id" => "alpha",
               "session" => "casein_other_u-dev"
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

    assert {:ok, %{target: "%2", status: "sent"}} =
             TerminalTools.invoke("terminal_send_agent_command", %{
               "workspace_id" => "alpha",
               "command" => "mix test"
             })

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
                 "command" => "git reset --hard origin/master"
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
                 "command" => "git reset --hard origin/master"
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
                 "command" => "git status --porcelain"
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
                 "allow_shared_worktree" => true
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
                 "command" => "git -C #{own} commit -m x"
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
                 "command" => "git -C #{shared} reset --hard"
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
                 "command" => "git commit -am wip"
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
                 "command" => "git commit -am wip"
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
               "submit" => true
             })

    assert_receive {:fake_tmux_paste_text, ^session, "%2", "one\ntwo", opts}
    assert opts[:submit] == true
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

    test "returns no_transcript when the pane has no pointer" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:error, :no_transcript} =
               TerminalTools.invoke("terminal_agent_transcript", %{
                 "workspace_id" => "alpha",
                 "session" => session
               })
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

    test "send_agent_command reports a dispatch working state for the agent pane" do
      session = agent_pair_session!()
      Casein.Terminals.AgentState.clear()

      assert {:ok, %{target: "%2", status: "sent"}} =
               TerminalTools.invoke("terminal_send_agent_command", %{
                 "workspace_id" => "alpha",
                 "session" => session,
                 "command" => "mix test"
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
                 "submit" => true
               })

      entry = Casein.Terminals.AgentState.get(session, "%2")
      assert entry.state == :working
      assert entry.source == :dispatch
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
