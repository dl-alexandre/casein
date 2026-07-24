defmodule Casein.Workspaces.SessionSummaryTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Runtimes
  alias Casein.Terminals.AgentState
  alias Casein.Test.RuntimeSeed
  alias Casein.Workspace
  alias Casein.Workspaces.SessionSummary
  alias Casein.Workspaces.State.WorkspaceRecord

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_session_meta = TmuxCtl.Test.FakeState.get(:fake_tmux_session_meta)
    prev_git_adapter = Application.get_env(:dev_ide, :git_adapter)

    Runtimes.clear()
    Activity.clear()
    AgentState.clear()
    Application.put_env(:dev_ide, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :git_adapter, git_stub("git-branch", 2))

    on_exit(fn ->
      Runtimes.clear()
      Activity.clear()
      AgentState.clear()
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_windows, prev_windows)
      restore(:fake_tmux_panes, prev_panes)
      restore(:fake_tmux_session_meta, prev_session_meta)
      restore(:git_adapter, prev_git_adapter)
    end)

    :ok
  end

  test "builds compact workspace context from git, runtime, and tmux sessions" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      user: "alice",
      status: :running,
      path: "/data/workspaces/alice/summary"
    }

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_summary_u-alice" => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "devide_summary_u-alice" => [
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
          current_path: "/data/workspaces/alice/summary"
        }
      ]
    })

    {:ok, _runtime} =
      RuntimeSeed.seed_runtime(ws.id,
        runtime_id: "rt-summary",
        status: "provisioned",
        branch: "feature/runtime"
      )

    summary = SessionSummary.build(ws)

    assert summary.branch == "git-branch"
    assert summary.path_label == "alice/summary"
    assert summary.dirty_count == 2
    assert summary.session_count == 1

    assert [%{id: "u-alice", label: "summary", cwd: "/data/workspaces/alice/summary", href: href}] =
             summary.sessions

    assert href =~ "/workspaces/summary-ws"
    assert href =~ "session=u-alice"
    refute href =~ "host=local"
    assert summary.agent_layout.status == "missing_agent_pane"
    assert summary.agent_layout.ready == false
    assert summary.agent_layout.suggested_template == "agent_pair"
    refute inspect(summary.agent_layout) =~ "/data/workspaces/alice/summary"
    assert summary.runtime_count == 1
    assert summary.active_runtime_count == 1
  end

  test "session links prefer active pane cwd and newest activity" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      path: "/data/workspaces/alice/summary"
    }

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_summary_u-alice-old" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 10}
      ],
      "devide_summary_u-alice-new" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 99}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      "devide_summary_u-alice-old" => [
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
          current_path: "/data/workspaces/alice/summary"
        }
      ],
      "devide_summary_u-alice-new" => [
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
          current_path: "/data/workspaces/alice/summary/apps/web"
        }
      ]
    })

    summary = SessionSummary.build(ws)

    assert Enum.map(summary.sessions, & &1.label) == ["apps/web", "summary"]
    assert hd(summary.sessions).cwd == "/data/workspaces/alice/summary/apps/web"
  end

  test "newest_shell_sid resumes the most-recently-active shell" do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_summary_u-alice-old" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 10}
      ],
      "devide_summary_u-alice-new" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 99}
      ]
    })

    assert SessionSummary.newest_shell_sid("summary-ws", "summary") == "u-alice-new"
  end

  test "newest_shell_sid returns nil when the workspace has no shells" do
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{})

    assert SessionSummary.newest_shell_sid("summary-ws", "summary") == nil
  end

  test "session links expose prompt aliases and latest agent prompt status" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      path: "/data/workspaces/alice/summary"
    }

    tmux_session = "devide_summary_agent"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 42}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%2",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "codex",
          current_path: "/data/workspaces/alice/summary",
          role: "agent"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_session_meta, %{
      tmux_session => %{session_alias: "Fix MCP auth"}
    })

    Activity.record(%{
      workspace_id: "summary-ws",
      source: :terminal_mcp,
      tool: "send_agent_prompt",
      summary: "done: Fix MCP auth",
      status: :ok,
      metadata: %{
        "session" => tmux_session,
        "pane" => "%2",
        "status" => "done",
        "title" => "Fix MCP auth"
      }
    })

    summary = SessionSummary.build(ws)

    assert [
             %{
               label: "Fix MCP auth",
               title: title,
               agent_title: "Fix MCP auth",
               agent_pane: "%2",
               agent_status: "done"
             }
           ] = summary.sessions

    assert title =~ "Fix MCP auth"
    assert title =~ tmux_session
    assert summary.agent_layout.status == "ready"
    assert summary.agent_layout.ready == true

    assert [%{id: "%2", role: "agent", current_command: "codex"}] =
             summary.agent_layout.agent_panes

    refute inspect(summary.agent_layout) =~ "/data/workspaces/alice/summary"
  end

  test "a reported agent state beats newer generic MCP activity" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      path: "/data/workspaces/alice/summary"
    }

    tmux_session = "devide_summary_reported"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 42}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%2",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "claude",
          current_path: "/data/workspaces/alice/summary",
          role: "agent"
        }
      ]
    })

    # A later generic capture reports "done" — without the AgentState guard this
    # would clobber a real blocked report.
    Activity.record(%{
      workspace_id: "summary-ws",
      source: :terminal_mcp,
      tool: "terminal_capture",
      summary: "capture",
      status: :ok,
      metadata: %{"session" => tmux_session, "pane" => "%2", "status" => "done"}
    })

    :ok = AgentState.report("summary-ws", tmux_session, "%2", :blocked, "needs input")

    summary = SessionSummary.build(ws)

    assert [%{agent_status: "attention"}] = summary.sessions
  end

  test "transcript activity enriches agent_title when hooks report working" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      path: "/data/workspaces/alice/summary"
    }

    tmux_session = "devide_summary_transcript"
    path = transcript_fixture!()

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      tmux_session => [
        %{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 42}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      tmux_session => [
        %{
          id: "%2",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "claude",
          current_path: "/data/workspaces/alice/summary",
          role: "agent"
        }
      ]
    })

    :ok =
      AgentState.report("summary-ws", tmux_session, "%2", :working, nil, transcript_path: path)

    summary = SessionSummary.build(ws)
    session = hd(summary.sessions)

    assert session.agent_title == "editing show.ex"
  end

  test "manager branch wins over git fallback" do
    summary =
      SessionSummary.build(%Workspace{
        id: "summary-branch",
        name: "summary-branch",
        branch: "manager-main",
        path: "/data/workspaces/alice/summary-branch"
      })

    assert summary.branch == "manager-main"
  end

  test "cached workspace records use external_id as the route id" do
    summary =
      SessionSummary.build(%WorkspaceRecord{
        id: Ecto.UUID.generate(),
        external_id: "manager-workspace-id",
        name: "cached-summary",
        host_path: "/data/workspaces/alice/cached-summary",
        manager_payload: %{"branch" => "cached-main"}
      })

    assert summary.id == "manager-workspace-id"
    assert summary.path_label == "alice/cached-summary"
    assert summary.branch == "cached-main"
  end

  test "build_many collapses sparse cached aliases for the same workspace name" do
    sparse_alias = %WorkspaceRecord{
      id: Ecto.UUID.generate(),
      external_id: "dalexandre-twenty-one",
      name: "dalexandre-twenty-one"
    }

    observed_workspace = %WorkspaceRecord{
      id: Ecto.UUID.generate(),
      external_id: "manager-twenty-one-id",
      name: "dalexandre-twenty-one",
      host_path: "/data/workspaces/dalexandre-twenty-one",
      status: "running",
      manager_payload: %{"branch" => "develop", "user" => "dalexandre"}
    }

    assert [summary] = SessionSummary.build_many([sparse_alias, observed_workspace])
    assert summary.id == "manager-twenty-one-id"
    assert summary.branch == "develop"
    assert summary.path_label == "dalexandre-twenty-one"
  end

  test "build_many marks a workspace live only when it has a live tmux session" do
    alive = %Workspace{id: "alive-ws", name: "alive", path: "/data/workspaces/alice/alive"}
    dead = %Workspace{id: "dead-ws", name: "dead", path: "/data/workspaces/alice/dead"}

    # Only `alive` has a live tmux session; `dead` is a leftover worktree
    # directory with nothing running in it.
    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_alive_u-alice" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 5}
      ]
    })

    summaries = SessionSummary.build_many([alive, dead])

    assert %{live?: true} = Enum.find(summaries, &(&1.id == "alive-ws"))
    assert %{live?: false} = Enum.find(summaries, &(&1.id == "dead-ws"))
  end

  test "build_many keeps a workspace live via an active runtime even with no tmux session" do
    ws = %Workspace{id: "rt-live-ws", name: "rtlive", path: "/data/workspaces/alice/rtlive"}

    {:ok, _runtime} =
      RuntimeSeed.seed_runtime(ws.id, runtime_id: "rt-live", status: "provisioned")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{})

    assert [%{live?: true}] = SessionSummary.build_many([ws])
  end

  test "orphan_tmux_sessions mirrors devide tmux sessions outside known workspaces" do
    ws = %Workspace{
      id: "summary-ws",
      name: "summary",
      path: "/data/workspaces/alice/summary"
    }

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      "devide_summary_u-alice" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 10}
      ],
      "devide_ws-adapter_sid-adapter" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 99}
      ],
      "other_tmux" => [
        %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 100}
      ]
    })

    summary = SessionSummary.build(ws)

    assert [orphan] = SessionSummary.orphan_tmux_sessions([summary])
    assert orphan.id == "tmux:devide_ws-adapter_sid-adapter"
    assert orphan.label == "ws-adapter"
    assert orphan.detail == "sid-adapter"
    assert orphan.href == nil
    assert orphan.tmux_session == "devide_ws-adapter_sid-adapter"
  end

  defp git_stub(branch, dirty_count) do
    name = :"Casein.Test.SessionSummaryGit#{System.unique_integer([:positive])}"

    entries =
      for idx <- 1..dirty_count do
        %{x: "M", y: " ", path: "file#{idx}.ex"}
      end

    contents =
      quote do
        @behaviour Casein.Git.Adapter
        @impl true
        def branch(_root), do: {:ok, unquote(branch)}
        @impl true
        def status_short(_root), do: {:ok, unquote(Macro.escape(entries))}
        @impl true
        def diff(_root, _rel), do: {:ok, ""}
        @impl true
        def diff_all(_root), do: {:ok, ""}
      end

    {:module, mod, _, _} = Module.create(name, contents, Macro.Env.location(__ENV__))
    mod
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes fake_tmux_session_meta)a

  defp restore(key, value) when key in @fake_state_keys,
    do: TmuxCtl.Test.FakeState.restore(key, value)

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp transcript_fixture! do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()

    auth_root =
      Path.join([root, "summary-transcript-#{System.unique_integer([:positive])}", "auth"])

    Application.put_env(:dev_ide, :agent_auth_profile_root, auth_root)

    path =
      Path.join([
        auth_root,
        "profiles",
        "alice",
        "claude",
        "projects",
        "summary",
        "session.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))

    lines = [
      %{
        "uuid" => "u1",
        "parentUuid" => nil,
        "type" => "user",
        "timestamp" => "2026-07-06T10:00:00.000Z",
        "message" => %{"role" => "user", "content" => "Fix the bug"}
      },
      %{
        "uuid" => "a1",
        "parentUuid" => "u1",
        "type" => "assistant",
        "timestamp" => "2026-07-06T10:00:01.000Z",
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "I'll read that file."},
            %{
              "type" => "tool_use",
              "id" => "tool-1",
              "name" => "Edit",
              "input" => %{"file_path" => "/tmp/show.ex"}
            }
          ]
        }
      }
    ]

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
    path
  end
end
