defmodule Casein.Agents.TerminalToolsTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Runtimes
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
      env_agent_mcp_home: System.get_env("DEVIDE_AGENT_MCP_HOME"),
      env_home: System.get_env("HOME")
    }

    MemoryAdapter.clear()
    Runtimes.clear()
    Casein.Audit.MemoryAdapter.clear()

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
      restore_system_env("DEVIDE_AGENT_MCP_HOME", previous.env_agent_mcp_home)
      restore_system_env("HOME", previous.env_home)

      MemoryAdapter.clear()
      Runtimes.clear()
      Casein.Audit.MemoryAdapter.clear()
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
    stale = prefix <> "_stale"
    live = prefix <> "_live"

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
    older = prefix <> "_older"
    newer = prefix <> "_newer"

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
      other = prefix <> "_other"
      mine = prefix <> "_mine"

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
    session_a = prefix <> "_a"
    session_b = prefix <> "_b"

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
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "devide-terminal-tools-#{System.unique_integer([:positive])}-#{name}")
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

    session
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
