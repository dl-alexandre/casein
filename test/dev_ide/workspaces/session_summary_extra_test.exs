defmodule DevIDE.Workspaces.SessionSummaryExtraTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Runtimes
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.SessionSummary
  alias DevIDE.Workspaces.State.WorkspaceRecord

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_git_adapter = Application.get_env(:dev_ide, :git_adapter)

    Runtimes.clear()
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    # No git_adapter is set by default here; individual tests that care about
    # branch/dirty_count override it. Without a configured workspace path the
    # git helpers short-circuit to nil before any adapter call.

    on_exit(fn ->
      Runtimes.clear()
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_windows, prev_windows)
      restore(:fake_tmux_panes, prev_panes)
      restore(:git_adapter, prev_git_adapter)
    end)

    :ok
  end

  describe "path_label/1" do
    test "returns nil for nil and empty string" do
      assert SessionSummary.path_label(nil) == nil
      assert SessionSummary.path_label("") == nil
    end

    test "returns nil for non-binary input" do
      assert SessionSummary.path_label(:not_a_path) == nil
      assert SessionSummary.path_label(123) == nil
    end

    test "returns the single segment when the path has only one component" do
      assert SessionSummary.path_label("solo") == "solo"
      # Leading/trailing slashes are trimmed, so this is still a single segment.
      assert SessionSummary.path_label("/solo/") == "solo"
    end

    test "joins the last two segments with a slash for ordinary deep paths" do
      assert SessionSummary.path_label("/data/workspaces/alice/summary") == "alice/summary"
      assert SessionSummary.path_label("a/b/c") == "b/c"
    end

    test "compacts a workspaces/<name> tail to just the workspace name" do
      assert SessionSummary.path_label("/home/devbox/workspaces/twenty-one") == "twenty-one"
    end
  end

  describe "build/1 path and label derivation" do
    test "falls back to host_path when path is absent and derives the label" do
      summary =
        SessionSummary.build(%WorkspaceRecord{
          id: Ecto.UUID.generate(),
          external_id: "host-path-ws",
          name: "host-path-ws",
          host_path: "/data/workspaces/bob/hpw"
        })

      assert summary.path == "/data/workspaces/bob/hpw"
      assert summary.path_label == "bob/hpw"
    end

    test "nil path yields nil path_label, dirty_count, and git branch" do
      # Set a git adapter to prove it is never consulted for a nil path.
      Application.put_env(:dev_ide, :git_adapter, git_stub("should-not-be-used", 5))

      summary =
        SessionSummary.build(%Workspace{
          id: "no-path-ws",
          name: "no-path-ws"
        })

      assert summary.path == nil
      assert summary.path_label == nil
      assert summary.dirty_count == nil
      assert summary.branch == nil
    end
  end

  describe "build/1 status and host derivation" do
    test "uses :status when present" do
      summary =
        SessionSummary.build(%Workspace{
          id: "status-ws",
          name: "status-ws",
          status: :running
        })

      assert summary.status == :running
    end

    test "falls back to :mode when :status is nil" do
      summary =
        SessionSummary.build(%WorkspaceRecord{
          id: Ecto.UUID.generate(),
          external_id: "mode-ws",
          name: "mode-ws",
          status: nil,
          mode: "isolated"
        })

      assert summary.status == "isolated"
    end

    test "defaults host_id to \"local\" when no host is given" do
      summary =
        SessionSummary.build(%Workspace{
          id: "local-host-ws",
          name: "local-host-ws"
        })

      assert summary.host_id == "local"
    end

    test "reads host_id from a :host_id key map" do
      summary =
        SessionSummary.build(%{
          id: "explicit-host-ws",
          name: "explicit-host-ws",
          host_id: "remote-a"
        })

      assert summary.host_id == "remote-a"
    end

    test "reads host_id from a :host key when :host_id is absent" do
      summary =
        SessionSummary.build(%{
          id: "host-key-ws",
          name: "host-key-ws",
          host: "remote-b"
        })

      assert summary.host_id == "remote-b"
    end
  end

  describe "build/1 user and id derivation" do
    test "reads user directly from the :user field" do
      summary =
        SessionSummary.build(%Workspace{
          id: "user-direct",
          name: "user-direct",
          user: "carol"
        })

      assert summary.user == "carol"
    end

    test "reads user from a top-level metadata key" do
      summary =
        SessionSummary.build(%{
          id: "user-meta",
          name: "user-meta",
          metadata: %{"user" => "dave"}
        })

      assert summary.user == "dave"
    end

    test "reads user from nested manager_payload raw metadata" do
      summary =
        SessionSummary.build(%WorkspaceRecord{
          id: Ecto.UUID.generate(),
          external_id: "user-raw",
          name: "user-raw",
          manager_payload: %{"raw" => %{"user" => "erin"}}
        })

      assert summary.user == "erin"
    end

    test "user is nil when no source provides one" do
      summary =
        SessionSummary.build(%{
          id: "user-none",
          name: "user-none"
        })

      assert summary.user == nil
    end

    test "name falls back to the workspace id when no name is present" do
      summary = SessionSummary.build(%{id: "id-only-ws"})

      assert summary.id == "id-only-ws"
      assert summary.name == "id-only-ws"
    end

    test "external_id wins over id for the route id" do
      summary =
        SessionSummary.build(%{
          id: "internal-uuid",
          external_id: "manager-id",
          name: "ext-id-ws"
        })

      assert summary.id == "manager-id"
    end
  end

  describe "build/1 branch derivation" do
    test "branch comes from manager_payload raw metadata when no :branch field" do
      summary =
        SessionSummary.build(%WorkspaceRecord{
          id: Ecto.UUID.generate(),
          external_id: "branch-raw",
          name: "branch-raw",
          host_path: "/data/workspaces/frank/branch-raw",
          manager_payload: %{"raw" => %{"branch" => "raw-feature"}}
        })

      assert summary.branch == "raw-feature"
    end

    test "git branch fallback is used when the manager provides none" do
      Application.put_env(:dev_ide, :git_adapter, git_stub("git-derived", 3))

      summary =
        SessionSummary.build(%Workspace{
          id: "git-branch-ws",
          name: "git-branch-ws",
          path: "/data/workspaces/grace/git-branch-ws"
        })

      assert summary.branch == "git-derived"
      assert summary.dirty_count == 3
    end

    test "empty git branch is treated as no branch" do
      Application.put_env(:dev_ide, :git_adapter, git_stub("", 0))

      summary =
        SessionSummary.build(%Workspace{
          id: "empty-branch-ws",
          name: "empty-branch-ws",
          path: "/data/workspaces/heidi/empty-branch-ws"
        })

      assert summary.branch == nil
      assert summary.dirty_count == 0
    end

    test "git adapter error yields nil branch and nil dirty_count" do
      Application.put_env(:dev_ide, :git_adapter, git_error_stub())

      summary =
        SessionSummary.build(%Workspace{
          id: "git-error-ws",
          name: "git-error-ws",
          path: "/data/workspaces/ivan/git-error-ws"
        })

      assert summary.branch == nil
      assert summary.dirty_count == nil
    end
  end

  describe "build/1 runtime counting" do
    test "counts runtimes and active runtimes by status" do
      ws = %Workspace{id: "rt-counts-ws", name: "rt-counts-ws"}

      {:ok, _} =
        RuntimeSeed.seed_runtime(ws.id, runtime_id: "rt-active", status: "active")

      {:ok, _} =
        RuntimeSeed.seed_runtime(ws.id, runtime_id: "rt-bound", status: "bound")

      {:ok, _} =
        RuntimeSeed.seed_runtime(ws.id, runtime_id: "rt-idle", status: "stopped")

      summary = SessionSummary.build(ws)

      assert summary.runtime_count == 3
      assert summary.active_runtime_count == 2
    end

    test "workspace with no runtimes reports zero counts" do
      summary = SessionSummary.build(%Workspace{id: "no-rt-ws", name: "no-rt-ws"})

      assert summary.runtime_count == 0
      assert summary.active_runtime_count == 0
      assert summary.session_count == 0
      assert summary.sessions == []
    end
  end

  describe "build/1 host query param in session hrefs" do
    test "non-local host_id is encoded into the session href" do
      ws = %Workspace{
        id: "summary-ws",
        name: "summary",
        path: "/data/workspaces/alice/summary"
      }

      ws = Map.put(ws, :host_id, "remote-host")

      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "devide_summary_u-alice" => [
          %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 0}
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

      summary = SessionSummary.build(ws)

      assert [%{href: href}] = summary.sessions
      assert href =~ "host=remote-host"
      assert href =~ "session=u-alice"
    end
  end

  describe "orphan_tmux_sessions/1" do
    test "ignores non-devide tmux sessions and string sessions list" do
      # "other_tmux" is not a devide session, so it produces no orphan even
      # though it is unknown to every summary.
      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "other_tmux" => [
          %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 5}
        ]
      })

      assert SessionSummary.orphan_tmux_sessions([]) == []
    end

    test "ignores devide sessions whose suffix cannot be parsed" do
      # "devide_lonely" splits into a single part, failing the >= 2 guard.
      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "devide_lonely" => [
          %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 5}
        ]
      })

      assert SessionSummary.orphan_tmux_sessions([]) == []
    end

    test "sorts multiple orphans by descending activity" do
      TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
        "devide_alpha_sid-1" => [
          %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 3}
        ],
        "devide_beta_sid-2" => [
          %{id: "@1", index: 0, name: "shell", active: true, panes: 1, activity: 99}
        ]
      })

      orphans = SessionSummary.orphan_tmux_sessions([])

      assert Enum.map(orphans, & &1.label) == ["beta", "alpha"]
      assert Enum.map(orphans, & &1.detail) == ["sid-2", "sid-1"]
    end
  end

  describe "build_many/1 alias collapsing" do
    test "keeps distinct workspaces with different names and hosts" do
      a = %WorkspaceRecord{
        id: Ecto.UUID.generate(),
        external_id: "ws-a",
        name: "ws-a",
        host_path: "/data/workspaces/ws-a"
      }

      b = %WorkspaceRecord{
        id: Ecto.UUID.generate(),
        external_id: "ws-b",
        name: "ws-b",
        host_path: "/data/workspaces/ws-b"
      }

      summaries = SessionSummary.build_many([a, b])

      assert length(summaries) == 2
      assert Enum.map(summaries, & &1.id) |> Enum.sort() == ["ws-a", "ws-b"]
    end

    test "collapses two records sharing the same host and path" do
      shared_path = "/data/workspaces/shared-path"

      sparse = %WorkspaceRecord{
        id: Ecto.UUID.generate(),
        external_id: "sparse-id",
        name: "sparse-name",
        host_path: shared_path
      }

      rich = %WorkspaceRecord{
        id: Ecto.UUID.generate(),
        external_id: "rich-id",
        name: "rich-name",
        host_path: shared_path,
        status: "running",
        manager_payload: %{"branch" => "main", "user" => "judy"}
      }

      assert [summary] = SessionSummary.build_many([sparse, rich])
      # The richer summary (more populated score fields) wins.
      assert summary.id == "rich-id"
      assert summary.branch == "main"
      assert summary.user == "judy"
    end
  end

  defp git_stub(branch, dirty_count) do
    name = :"DevIDE.Test.SessionSummaryExtraGit#{System.unique_integer([:positive])}"

    entries =
      if dirty_count == 0 do
        []
      else
        for idx <- 1..dirty_count do
          %{x: "M", y: " ", path: "file#{idx}.ex"}
        end
      end

    contents =
      quote do
        @behaviour DevIDE.Git.Adapter
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

  defp git_error_stub do
    name = :"DevIDE.Test.SessionSummaryExtraGitErr#{System.unique_integer([:positive])}"

    contents =
      quote do
        @behaviour DevIDE.Git.Adapter
        @impl true
        def branch(_root), do: {:error, :not_a_repo}
        @impl true
        def status_short(_root), do: {:error, :not_a_repo}
        @impl true
        def diff(_root, _rel), do: {:error, :not_a_repo}
        @impl true
        def diff_all(_root), do: {:error, :not_a_repo}
      end

    {:module, mod, _, _} = Module.create(name, contents, Macro.Env.location(__ENV__))
    mod
  end

  @fake_state_keys ~w(fake_tmux_windows fake_tmux_panes)a

  defp restore(key, value) when key in @fake_state_keys,
    do: TmuxCtl.Test.FakeState.restore(key, value)

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
