defmodule DevIDE.Fleet.RemoteSubstrateTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.AssignmentRequirements
  alias DevIDE.Fleet.ExecutionBackend.SshTmux
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    WorkspaceState.clear()
    TmuxCtl.Test.FakeState.put(:fake_tmux_test_pid, self())

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()
      TmuxCtl.Test.FakeState.delete(:fake_tmux_test_pid)
    end)

    :ok
  end

  @tag :tmp_dir
  test "runner identities support pools, maintenance, draining, and revocation", %{
    tmp_dir: tmp_dir
  } do
    seed_workspace(tmp_dir)

    runner_id = Ecto.UUID.generate()

    {:ok, runner} =
      Fleet.register(%{
        id: runner_id,
        hostname: "pool-a",
        capabilities: ["workspace-command:v1", "pool:blue"],
        metadata: %{"pool" => "blue", "workspaces" => ["ws-substrate"]}
      })

    assert {:ok, identity} = Fleet.runner_identity(runner.id)
    assert identity.trust_state == :authorized

    {:ok, maintenance} = Fleet.set_runner_trust_state(runner.id, :maintenance)
    assert maintenance.trust_state == :maintenance
    assert {:ok, %{state: :maintenance}} = Fleet.get_runner(runner.id)

    {:ok, _authorized} = Fleet.set_runner_trust_state(runner.id, :authorized)

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-substrate",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    requirements =
      AssignmentRequirements.new(
        capabilities: ["workspace-command:v1"],
        runner_pool: "blue",
        workspace_affinity: "ws-substrate"
      )

    :ok = DevIDE.Fleet.Queue.enqueue(assignment.id, requirements)

    plan = Fleet.scheduler_plan()
    assert [%{assignment_id: assignment_id, selected_runner: ^runner_id}] = plan.entries
    assert assignment_id == assignment.id
    assert plan.runner_pools["blue"] == [runner_id]

    {:ok, _draining} = Fleet.set_runner_trust_state(runner.id, :draining)
    assert {:ok, %{state: :draining}} = Fleet.get_runner(runner.id)

    {:ok, _revoked} = Fleet.set_runner_trust_state(runner.id, :revoked)

    assert {:error, :runner_revoked} =
             Fleet.register(%{id: runner_id, hostname: "pool-a", capabilities: []})
  end

  @tag :tmp_dir
  test "attach packets, timelines, and ssh/tmux backend are read-only infrastructure",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-substrate"})

    projection = %ExecutionProjection{
      id: "exec-substrate",
      assignment_id: assignment.id,
      runner_id: "runner-substrate",
      lease_id: "lease-substrate",
      state: :started,
      workspace_id: "ws-substrate",
      worktree_path: tmp_dir,
      tmux_session: "alive-session",
      started_at: DateTime.utc_now()
    }

    :ok = ExecutionProjectionStore.create(projection)
    :ok = ArtifactStore.append_chunk("exec-substrate", "stdout", "hello\n", DateTime.utc_now())

    assert {:ok, packet} = Fleet.attach_packet("exec-substrate", subscribe: true)
    assert packet.execution == projection
    assert [%{data: "hello\n"}] = packet.historical_chunks
    assert packet.dossier.workspace_id == "ws-substrate"

    assert {:ok, timeline} = Fleet.execution_timeline("exec-substrate")
    assert timeline.execution.id == "exec-substrate"
    assert [%{data: "hello\n"}] = timeline.artifacts

    assert {:ok, workspace} = SshTmux.prepare_workspace("ws-substrate")

    assert {:ok, session} =
             SshTmux.start_session("exec-substrate-2", workspace,
               tmux_adapter: DevIDE.Test.FakeTmuxAdapter
             )

    assert session.attach_command == "tmux attach -t session-exec-substrate-2"

    assert {:ok, attach} =
             SshTmux.attach("exec-substrate", tmux_adapter: DevIDE.Test.FakeTmuxAdapter)

    assert attach.attach_command == "tmux attach -t alive-session"
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: "ws-substrate",
        name: "Substrate",
        user: "operator",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => "ws-substrate", "branch" => "main", "git_sha" => "abc123"}
      })
  end
end
