defmodule DevIDE.Fleet.RemoteRunnerTest do
  use ExUnit.Case, async: false

  # These assert on messages from a fast polling/heartbeat runner (poll_ms: 10).
  # The bound is a ceiling, not a delay — assert_receive returns the instant the
  # message matches, so the happy path is unaffected. A tight 500ms (or the
  # implicit 100ms default) flakes only under full-suite scheduler contention
  # (hundreds of async tests + PTY-spawning terminal tests starving the BEAM
  # schedulers), never in isolation. Generous headroom removes the flake.
  @receive_timeout 5_000

  alias DevIDE.Assignments
  alias DevIDE.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.AssignmentRequirements
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.Notification
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.RemoteRunner
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    previous_adapter = Application.get_env(:dev_ide, :commands_adapter)
    previous_test_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    OutputStream.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    WorkspaceState.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
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
  test "standalone runner polls, executes, uploads artifacts, and completes", %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    assignment = enqueue_assignment("format")

    {:ok, _pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "remote-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        notify_pid: self()
      )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]},
                   @receive_timeout

    assignment_id = assignment.id

    assert_receive {:remote_runner_finished,
                    %{status: :completed, assignment_id: ^assignment_id}},
                   @receive_timeout

    assert {:ok, final} = Assignments.get(assignment.id)
    assert final.state == "completed"

    [execution] = ExecutionProjectionStore.for_assignment(assignment.id)
    assert execution.state == :completed
    assert [%{stream: "stdout", data: "ok\n"}] = ArtifactStore.chunks(execution.id)
  end

  @tag :tmp_dir
  test "runner renews a live lease while command is still executing", %{tmp_dir: tmp_dir} do
    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeSlowCommandAdapter)
    seed_workspace(tmp_dir)
    assignment = enqueue_assignment("compile", max_runtime_ms: 30_000)
    Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet:assignments:#{assignment.id}")

    {:ok, _pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "renew-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        renew_ms: 10,
        notify_pid: self()
      )

    assert_receive {:fake_slow_command_spawned, ^tmp_dir, ["mix", "compile"], command_pid, _ref},
                   @receive_timeout

    assert_receive {DevIDE.Fleet.Registry,
                    %Notification{kind: :lease_renewed, assignment_id: assignment_id}},
                   @receive_timeout

    assert assignment_id == assignment.id

    send(command_pid, {:finish, 0})

    assert_receive {:remote_runner_finished, %{status: :completed, assignment_id: assignment_id}},
                   @receive_timeout

    assert assignment_id == assignment.id
  end

  @tag :tmp_dir
  test "runner clears active_task when executor task crashes", %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    _assignment = enqueue_assignment("format")

    {:ok, pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "crash-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        executor: DevIDE.Fleet.RemoteRunnerTest.CrashingExecutor,
        notify_pid: self()
      )

    assert_receive {:remote_runner_failed, _reason}, @receive_timeout

    assert %{active_task: nil, active_offer: nil, active_lease_id: nil} =
             RemoteRunner.snapshot(pid)
  end

  @tag :tmp_dir
  test "runner drain stops polling new work and shutdown marks runner offline", %{
    tmp_dir: tmp_dir
  } do
    seed_workspace(tmp_dir)
    runner_id = Ecto.UUID.generate()

    {:ok, pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: runner_id,
        hostname: "drain-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        notify_pid: self()
      )

    assert {:ok, snapshot} = RemoteRunner.drain(pid)
    assert snapshot.draining == true
    assert {:ok, %{state: :draining}} = Fleet.get_runner(runner_id)

    _assignment = enqueue_assignment("format")
    refute_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]}, 100

    assert :ok = RemoteRunner.shutdown(pid)
    assert {:ok, %{state: :offline}} = Fleet.get_runner(runner_id)
  end

  defp enqueue_assignment(command_id, opts \\ []) do
    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-runner",
        metadata: %{
          safe_action_id: "command:#{command_id}",
          command_id: command_id,
          concurrency_group: Keyword.get(opts, :concurrency_group)
        }
      })

    :ok =
      DevIDE.Fleet.Queue.enqueue(
        assignment.id,
        AssignmentRequirements.new(
          capabilities: ["workspace-command:v1"],
          max_runtime_ms: Keyword.get(opts, :max_runtime_ms, 30_000)
        )
      )

    assignment
  end

  defmodule CrashingExecutor do
    def run(_offer, _report_fun, _opts), do: raise("executor crash")
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: "ws-runner",
        name: "Runner",
        user: "operator",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => "ws-runner", "branch" => "main"}
      })
  end
end
