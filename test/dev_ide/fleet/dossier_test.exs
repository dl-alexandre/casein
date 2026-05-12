defmodule DevIDE.Fleet.DossierTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Commands.History
  alias DevIDE.Commands.History.MemoryAdapter, as: CommandHistory
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    previous_adapter = Application.get_env(:dev_ide, :commands_adapter)
    previous_test_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeFailingCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    Assignments.clear()
    OutputStream.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    WorkspaceState.clear()
    CommandHistory.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      Assignments.clear()
      OutputStream.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()
      CommandHistory.clear()

      if previous_adapter do
        Application.put_env(:dev_ide, :commands_adapter, previous_adapter)
      else
        Application.delete_env(:dev_ide, :commands_adapter)
      end

      if previous_test_pid do
        Application.put_env(:dev_ide, :fake_command_test_pid, previous_test_pid)
      else
        Application.delete_env(:dev_ide, :fake_command_test_pid)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "dossier assembles workspace identity, histories, artifacts, failures, and recovery actions",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, _runner} =
      Fleet.register(%{hostname: "dossier-runner", capabilities: ["workspace-command:v1"]})

    assert {:ok, result} =
             Fleet.run_safe_command("ws-dossier", "compile",
               actor_id: "operator-1",
               run_id: "run-dossier",
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "compile"]}

    assert {:ok, dossier} = Fleet.dossier("ws-dossier")

    assert dossier.workspace_id == "ws-dossier"
    assert dossier.git_sha == "abc123"
    assert dossier.branch == "main"
    assert dossier.worktree_path == tmp_dir

    assert [%{assignment: assignment, events: events, executions: [execution]}] =
             dossier.assignment_history

    assert assignment.id == result.assignment_id
    assert Enum.map(events, & &1.type) == [:created, :claimed, :started, :failed]
    assert execution.id == result.execution_id

    assert [%{execution_id: execution_id, stream: "stderr", data: "boom\n"}] = dossier.artifacts
    assert execution_id == result.execution_id

    assert [
             %{
               assignment_id: assignment_id,
               execution_id: ^execution_id,
               runner_id: runner_id,
               workspace_id: "ws-dossier",
               lease_id: lease_id,
               command: %{
                 id: "compile",
                 safe_action_id: "command:compile",
                 argv: ["mix", "compile"]
               },
               exit_status: "failed",
               exit_code: 2,
               artifacts: [%{stream: "stderr", data: "boom\n", exit_status: "failed"}],
               recovery_actions: recovery_actions
             }
           ] = dossier.executions

    assert assignment_id == result.assignment_id
    assert is_binary(runner_id)
    assert is_binary(lease_id)

    assert Enum.any?(recovery_actions, fn
             %{type: :proposal, action: %{kind: :retry_assignment}} -> true
             _ -> false
           end)

    assert Enum.any?(dossier.failures, &(&1.type == :assignment and &1.state == "failed"))
    assert Enum.any?(dossier.failures, &(&1.type == :execution and &1.state == :failed))

    assert Enum.any?(dossier.recovery_actions, fn
             %{type: :proposal, action: %{kind: :retry_assignment}} -> true
             _ -> false
           end)

    [history] = History.recent_for("ws-dossier", 5)
    assert history.id == "run-dossier"
    assert history.status == "failed"
    assert history.output == "boom\n"
    assert [^history] = dossier.command_history
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-dossier",
        name: "Dossier",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: path,
        raw: %{"id" => "ws-dossier", "branch" => "main", "git_sha" => "abc123"}
      })
  end
end
