defmodule DevIDE.Fleet.LocalExecutorTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Workspace
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

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      Assignments.clear()
      OutputStream.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()

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
  test "runs one safe command through assignment, placement, protocol, workspace, output, and completion",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, runner} =
      Fleet.register(%{hostname: "local-runner", capabilities: ["workspace-command:v1"]})

    assert {:ok, result} =
             Fleet.run_safe_command("ws-m45", "format",
               actor_id: "operator-1",
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]}

    assert result.runner_id == runner.id
    assert result.workspace_id == "ws-m45"
    assert result.safe_action_id == "command:format"
    assert result.status == :completed
    assert result.exit_code == 0
    assert result.output_bytes == byte_size("ok\n")

    assert {:ok, assignment} = Assignments.get(result.assignment_id)
    assert assignment.state == "completed"
    assert assignment.metadata.safe_action_id == "command:format"

    assert :error = Fleet.get_lease(result.assignment_id)

    assert {:ok, projection} = ExecutionProjectionStore.get(result.execution_id)
    assert projection.state == :completed
    assert projection.assignment_id == result.assignment_id
    assert projection.runner_id == runner.id
    assert projection.evidence.exit_code == 0

    assert [%{stream: "stdout", data: "ok\n"}] = ArtifactStore.chunks(result.execution_id)
    assert [%{stream: "stdout", chunk: "ok\n"}] = OutputStream.chunks(result.execution_id)
  end

  @tag :tmp_dir
  test "drives failed command executions to failed state with durable stderr evidence",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeFailingCommandAdapter)
    seed_workspace(tmp_dir)

    {:ok, _runner} =
      Fleet.register(%{hostname: "local-runner", capabilities: ["workspace-command:v1"]})

    assert {:ok, result} =
             Fleet.run_safe_command("ws-m45", "compile",
               actor_id: "operator-1",
               timeout_ms: 1_000
             )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "compile"]}

    assert result.status == :failed
    assert result.exit_code == 2
    assert result.output_bytes == byte_size("boom\n")

    assert {:ok, assignment} = Assignments.get(result.assignment_id)
    assert assignment.state == "failed"
    assert assignment.failure_reason == "exit_code=2"

    assert :error = Fleet.get_lease(result.assignment_id)

    assert {:ok, projection} = ExecutionProjectionStore.get(result.execution_id)
    assert projection.state == :failed
    assert projection.failure_reason == "exit_code=2"
    assert projection.evidence.exit_code == 2

    assert [%{stream: "stderr", data: "boom\n"}] = ArtifactStore.chunks(result.execution_id)
    assert [%{stream: "stderr", chunk: "boom\n"}] = OutputStream.chunks(result.execution_id)
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: "ws-m45",
        name: "M45",
        user: "operator",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => "ws-m45"}
      })
  end
end
