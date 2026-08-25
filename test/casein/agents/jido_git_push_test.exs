defmodule Casein.Agents.JidoGitPushTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.{Activity, JidoActions, JidoLifecycle}
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.DbIsolation
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-jido-git-push"

  setup do
    previous = %{
      flag: Application.get_env(:casein, :jido_headless),
      workspaces: Application.get_env(:casein, :jido_headless_workspaces),
      state: Application.get_env(:casein, :workspace_state_adapter),
      runtimes: Application.get_env(:casein, :runtimes_adapter),
      git_push: Application.get_env(:casein, :jido_git_push)
    }

    base = Path.join(System.tmp_dir!(), "jido-git-push-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")

    Application.put_env(:casein, :jido_headless, true)
    Application.put_env(:casein, :jido_headless_workspaces, %{})
    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)

    MemoryAdapter.clear()
    Runtimes.clear()
    Activity.clear()

    init_repo!(repo)
    git!(repo, ["checkout", "-b", "worker/feature"])
    seed_workspace!(@workspace_id, repo)

    {:ok, _record} =
      State.persist_isolation(
        @workspace_id,
        %DbIsolation{
          isolation: :ephemeral,
          source: :default,
          summary: "isolated test workspace",
          detected_at: DateTime.utc_now()
        }
      )

    sha = git_output!(repo, ["rev-parse", "HEAD"])

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Activity.clear()
      File.rm_rf!(base)
      restore(:jido_headless, previous.flag)
      restore(:jido_headless_workspaces, previous.workspaces)
      restore(:workspace_state_adapter, previous.state)
      restore(:runtimes_adapter, previous.runtimes)
      restore(:jido_git_push, previous.git_push)
    end)

    %{repo: repo, ctx: trusted(repo), handoff: handoff(sha), sha: sha}
  end

  test "pushes the exact clean worker commit and records a Dash handoff", %{
    repo: repo,
    ctx: ctx,
    handoff: handoff,
    sha: sha
  } do
    test_pid = self()

    Application.put_env(:casein, :jido_git_push, fn path, args ->
      send(test_pid, {:push_called, path, args})
      :ok
    end)

    assert {:ok, result} =
             JidoActions.invoke("git_push", %{handoff: handoff}, ctx)

    assert result.result == :ok
    assert result.pushed
    assert result.head_sha == sha
    assert result.remote == "origin"
    assert result.remote_branch == "worker/feature"
    assert result.idempotency_key == "owner/repo:pr:42:#{sha}"
    assert result.handoff.handoff_status == "ready"

    assert_receive {:push_called, ^repo, ["origin", "HEAD:refs/heads/worker/feature"]}

    snapshot = JidoLifecycle.replay(@workspace_id, "attempt-jido-git-push")
    assert snapshot.handoff["head_sha"] == sha
    assert snapshot.last_progress.pushed?
    assert snapshot.last_progress.head_sha == sha
    assert snapshot.last_progress.idempotency_key == result.idempotency_key
  end

  test "denies a dirty tree or mismatched commit before the push boundary", %{
    repo: repo,
    ctx: ctx,
    handoff: handoff
  } do
    test_pid = self()

    Application.put_env(:casein, :jido_git_push, fn _path, _args ->
      send(test_pid, :push_called)
      :ok
    end)

    File.write!(Path.join(repo, "uncommitted.txt"), "must block")

    assert {:error, %{result: :denied, error: :dirty_worktree}} =
             JidoActions.invoke("git_push", %{handoff: handoff}, ctx)

    refute_receive :push_called

    File.rm!(Path.join(repo, "uncommitted.txt"))

    mismatched = %{handoff | head_sha: String.duplicate("b", 40)}

    assert {:error, %{result: :denied, error: :head_sha_mismatch}} =
             JidoActions.invoke("git_push", %{handoff: mismatched}, ctx)

    refute_receive :push_called
  end

  defp handoff(sha) do
    %{
      handoff_id: "handoff-jido-git-push",
      worker_run_id: "run-jido-git-push",
      repository: "owner/repo",
      base_branch: "develop",
      head_branch: "worker/feature",
      head_sha: sha,
      pr_number: 42,
      tests: [%{command: "mix test", status: "passed"}]
    }
  end

  defp trusted(repo) do
    %{
      workspace_id: @workspace_id,
      task_id: "task-jido-git-push",
      attempt_id: "attempt-jido-git-push",
      worktree_path: repo,
      actor: "ws:#{@workspace_id}",
      correlation_id: "attempt-jido-git-push"
    }
  end

  defp seed_workspace!(id, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: "jido-git-push",
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => "jido-git-push"}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "casein-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Jido git push\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git_output!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
