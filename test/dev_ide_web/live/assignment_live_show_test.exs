defmodule DevIdeWeb.AssignmentLiveShowTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Assignments
  alias DevIDE.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.Notification
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    WorkspaceState.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      WorkspaceState.clear()
    end)

    :ok
  end

  test "lease_renewed updates projection expiry without full refresh", %{conn: conn} do
    seed_workspace()

    {:ok, runner} =
      Fleet.register(%{
        hostname: "assignment-show-runner",
        capabilities: ["workspace-command:v1"]
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-assignment-show",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, _} = Assignments.claim(assignment.id, runner.id)
    {:ok, lease} = Fleet.acquire_lease(runner.id, assignment.id)

    {:ok, view, _html} = live(conn, ~p"/assignments/#{assignment.id}")

    renewed_expires = DateTime.add(DateTime.utc_now(), 30 * 60, :second)
    renewed = %{lease | expires_at: renewed_expires}

    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      "fleet:assignments:#{assignment.id}",
      {DevIDE.Fleet.Registry,
       %Notification{
         kind: :lease_renewed,
         assignment_id: assignment.id,
         lease_id: lease.id,
         runner_id: runner.id,
         payload: %{lease: renewed},
         occurred_at: DateTime.utc_now()
       }}
    )

    assert render(view) =~ Calendar.strftime(renewed_expires, "%Y-%m-%d %H:%M:%S")
  end

  test "assignment claim updates projection and appends event incrementally", %{conn: conn} do
    seed_workspace()

    {:ok, runner} =
      Fleet.register(%{
        hostname: "assignment-show-runner",
        capabilities: ["workspace-command:v1"]
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-assignment-show",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, view, html} = live(conn, ~p"/assignments/#{assignment.id}")
    assert html =~ ~s(state</dt><dd class="font-mono text-amber-700 font-medium">requested</dd>)
    assert html =~ "Event Timeline (1 events)"

    {:ok, claimed} = Assignments.claim(assignment.id, runner.id)

    rendered = render(view)

    assert rendered =~
             ~s(state</dt><dd class="font-mono text-amber-700 font-medium">claimed</dd>)

    assert rendered =~ "Event Timeline (2 events)"
    assert rendered =~ "claimed"
    assert rendered =~ claimed.lease_owner
    assert has_element?(view, "#assignment-event-2")
  end

  test "assignment notification preserves execution timeline stream", %{conn: conn} do
    seed_workspace()

    {:ok, runner} =
      Fleet.register(%{
        hostname: "assignment-show-runner",
        capabilities: ["workspace-command:v1"]
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-assignment-show",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, _} = Assignments.claim(assignment.id, runner.id)

    {:ok, view, _html} = live(conn, ~p"/assignments/#{assignment.id}")

    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      "fleet:assignments:#{assignment.id}",
      {DevIDE.Fleet.LocalRunnerAdapter,
       %Notification{
         kind: :execution_started,
         assignment_id: assignment.id,
         runner_id: runner.id,
         execution_id: "exec-1",
         payload: %{},
         occurred_at: DateTime.utc_now()
       }}
    )

    assert render(view) =~ "execution_started"

    {:ok, _} = Assignments.start(assignment.id)

    rendered = render(view)
    assert rendered =~ "execution_started"
    assert rendered =~ ~s(state</dt><dd class="font-mono text-amber-700 font-medium">running</dd>)
    assert has_element?(view, "#assignment-execution-timeline")
  end

  test "lease_released clears projection lease fields incrementally", %{conn: conn} do
    seed_workspace()

    {:ok, runner} =
      Fleet.register(%{
        hostname: "assignment-show-runner",
        capabilities: ["workspace-command:v1"]
      })

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-assignment-show",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    {:ok, claimed} = Assignments.claim(assignment.id, runner.id)
    {:ok, _} = Fleet.acquire_lease(runner.id, assignment.id)

    {:ok, view, html} = live(conn, ~p"/assignments/#{assignment.id}")
    assert html =~ claimed.lease_owner

    Phoenix.PubSub.broadcast(
      DevIde.PubSub,
      "fleet:assignments:#{assignment.id}",
      {DevIDE.Fleet.Registry,
       %Notification{
         kind: :lease_released,
         assignment_id: assignment.id,
         runner_id: runner.id,
         payload: %{lease_id: "lease-1"},
         occurred_at: DateTime.utc_now()
       }}
    )

    rendered = render(view)

    assert rendered =~
             ~s(lease owner</dt><dd class="font-mono">—</dd>)
  end

  defp seed_workspace do
    {:ok, _record} =
      State.sync(%Workspace{
        id: "ws-assignment-show",
        name: "Assignment Show",
        user: "operator",
        branch: "main",
        status: :running,
        path: System.tmp_dir!(),
        metadata: %{"id" => "ws-assignment-show", "branch" => "main"}
      })
  end
end
