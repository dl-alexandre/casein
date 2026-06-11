defmodule DevIDE.Workspaces.SessionSummaryTest do
  use ExUnit.Case, async: false

  alias DevIDE.Runtimes
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.SessionSummary

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_windows = Application.get_env(:dev_ide, :fake_tmux_windows)
    prev_git_adapter = Application.get_env(:dev_ide, :git_adapter)

    Runtimes.clear()
    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :git_adapter, git_stub("git-branch", 2))

    on_exit(fn ->
      Runtimes.clear()
      restore(:tmux_adapter, prev_tmux_adapter)
      restore(:fake_tmux_windows, prev_windows)
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

    Application.put_env(:dev_ide, :fake_tmux_windows, %{
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

    {:ok, runtime} =
      Runtimes.request_runtime(ws.id, %{
        "runtime_id" => "rt-summary",
        "branch" => "feature/runtime"
      })

    {:ok, _runtime} = Runtimes.provision_runtime(runtime.id)

    summary = SessionSummary.build(ws)

    assert summary.branch == "git-branch"
    assert summary.path_label == "alice/summary"
    assert summary.dirty_count == 2
    assert summary.session_count == 1
    assert [%{id: "u-alice", label: "Shell", href: href}] = summary.sessions
    assert href =~ "/workspaces/summary-ws"
    assert href =~ "session=u-alice"
    assert summary.runtime_count == 1
    assert summary.active_runtime_count == 1
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

  defp git_stub(branch, dirty_count) do
    name = :"DevIDE.Test.SessionSummaryGit#{System.unique_integer([:positive])}"

    entries =
      for idx <- 1..dirty_count do
        %{x: "M", y: " ", path: "file#{idx}.ex"}
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

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
