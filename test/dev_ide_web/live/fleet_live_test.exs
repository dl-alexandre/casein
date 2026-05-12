defmodule DevIdeWeb.FleetLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Assignments
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
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

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()
    end)

    :ok
  end

  test "runner detail page shows identity, leases, execution links, failures, and dossier", %{
    conn: conn
  } do
    seed_workspace()

    {:ok, runner} =
      Fleet.register(%{
        hostname: "dogfood-runner",
        capabilities: ["workspace-command:v1"],
        metadata: %{"pool" => "dogfood"}
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-fleet-live",
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
        workspace_id: "ws-fleet-live",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        failure_reason: "exit_code=1"
      })

    :ok =
      ArtifactStore.append_chunk(execution_id, "stdout", "failed output\n", DateTime.utc_now())

    {:ok, view, _html} = live(conn, ~p"/fleet/runners/#{runner.id}")

    assert has_element?(view, "#runner-identity")
    assert has_element?(view, "#runner-active-leases")
    assert has_element?(view, "#runner-current-execution")
    assert has_element?(view, "#runner-recent-failures")
    assert has_element?(view, "#execution-#{execution_id}")
    assert has_element?(view, "#runner-dossier-#{assignment.id}")
    assert has_element?(view, "a[href='/assignments/#{assignment.id}']")
  end

  defp seed_workspace do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-fleet-live",
        name: "Fleet Live",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: System.tmp_dir!(),
        raw: %{"id" => "ws-fleet-live", "branch" => "main"}
      })
  end
end
