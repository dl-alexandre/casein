defmodule DevIDE.Fleet.DossierExportTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.DossierExport
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    ArtifactStore.clear()
    ExecutionProjectionStore.clear()
    WorkspaceState.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      ArtifactStore.clear()
      ExecutionProjectionStore.clear()
      WorkspaceState.clear()
    end)

    :ok
  end

  @tag :tmp_dir
  test "exports assignment, execution, runner, workspace, artifacts, recovery, and timeline",
       %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)

    {:ok, runner} =
      Fleet.register(%{
        hostname: "export-runner",
        capabilities: ["workspace-command:v1"],
        metadata: %{"pool" => "dogfood"}
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-export",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, _claimed} = Assignments.claim(assignment.id, runner.id)
    {:ok, _running} = Assignments.start(assignment.id)
    {:ok, lease} = Fleet.acquire_lease(runner.id, assignment.id)

    execution_id = Ecto.UUID.generate()

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: execution_id,
        assignment_id: assignment.id,
        runner_id: runner.id,
        lease_id: lease.id,
        state: :failed,
        workspace_id: "ws-export",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        failure_reason: "dogfood failure"
      })

    :ok =
      ArtifactStore.append_chunk(execution_id, "stderr", "dogfood failure\n", DateTime.utc_now())

    assert {:ok, bundle} = DossierExport.for_assignment(assignment.id)

    assert bundle["assignment"]["id"] == assignment.id
    assert bundle["workspace_id"] == "ws-export"
    assert [%{"execution" => %{"id" => ^execution_id}}] = bundle["executions"]
    assert bundle["runners"][runner.id]["identity"]["trust_state"] == "authorized"
    assert [%{"data" => "dogfood failure\n"}] = bundle["artifacts"]
    assert is_list(bundle["recovery_actions"])
    assert bundle["timeline"]["assignment_id"] == assignment.id

    output = Path.join(tmp_dir, "dossier.json")
    assert {:ok, ^output} = DossierExport.write_assignment(assignment.id, output)
    assert {:ok, decoded} = output |> File.read!() |> Jason.decode()
    assert decoded["assignment_id"] == assignment.id
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-export",
        name: "Export",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: path,
        raw: %{"id" => "ws-export", "branch" => "main", "git_sha" => "abc123"}
      })
  end
end
