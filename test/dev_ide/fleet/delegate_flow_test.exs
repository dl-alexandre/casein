defmodule DevIDE.Fleet.DelegateFlowTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
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

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)
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
  test "delegate_task executes an approved command sequence and returns reviewable evidence",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, runner} =
      Fleet.register(%{hostname: "delegate-runner", capabilities: ["workspace-command:v1"]})

    assert {:ok, result} =
             Fleet.delegate_task("ws-delegate", ["format", "compile"],
               actor_id: "operator-1",
               task_id: "task-1",
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]}
    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "compile"]}

    assert result.task_id == "task-1"
    assert result.workspace_id == "ws-delegate"
    assert result.command_sequence == ["format", "compile"]
    assert result.status == :completed
    assert length(result.steps) == 2
    assert Enum.map(result.steps, & &1.command_id) == ["format", "compile"]
    assert Enum.all?(result.steps, &(&1.status == :completed))
    assert Enum.all?(result.steps, &(&1.runner_id == runner.id))

    assignments = Assignments.list_by_workspace("ws-delegate")
    assert length(assignments) == 2
    assert Enum.all?(assignments, &(&1.state == "completed"))
    assert Enum.all?(assignments, &(&1.metadata.task_id == "task-1"))

    for step <- result.steps do
      assert [%{stream: "stdout", data: "ok\n"}] = ArtifactStore.chunks(step.execution_id)
    end

    assert length(result.dossier.assignment_history) == 2
    assert length(result.dossier.command_history) == 2
    assert length(result.dossier.executions) == 2

    for execution <- result.dossier.executions do
      assert execution.assignment_id
      assert execution.execution_id
      assert execution.runner_id == runner.id
      assert execution.workspace_id == "ws-delegate"
      assert execution.lease_id
      assert execution.command.id in ["format", "compile"]
      assert execution.command.safe_action_id in ["command:format", "command:compile"]
      assert execution.exit_status == "succeeded"
      assert execution.exit_code == 0
      assert [%{stream: "stdout", data: "ok\n", exit_status: "succeeded"}] = execution.artifacts
      assert execution.recovery_actions == []
    end

    assert result.dossier.failures == []
  end

  @tag :tmp_dir
  test "delegate_task validates the whole command sequence before creating assignments",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, _runner} =
      Fleet.register(%{hostname: "delegate-runner", capabilities: ["workspace-command:v1"]})

    assert {:error, {:command_not_allowed, "rm"}} =
             Fleet.delegate_task("ws-delegate", ["format", "rm"],
               actor_id: "operator-1",
               task_id: "task-denied"
             )

    assert Assignments.list_by_workspace("ws-delegate") == []
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-delegate",
        name: "Delegate",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: path,
        raw: %{"id" => "ws-delegate", "branch" => "main"}
      })
  end
end
