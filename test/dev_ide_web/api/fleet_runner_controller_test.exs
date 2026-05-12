defmodule DevIdeWeb.API.FleetRunnerControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Assignments
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.AssignmentRequirements
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  @token "fleet-runner-token"
  @runner_token "narrow-runner-token"

  setup %{conn: conn} do
    previous_token = Application.get_env(:dev_ide, :api_token)
    previous_runner_token = Application.get_env(:dev_ide, :runner_token)

    Application.put_env(:dev_ide, :api_token, @token)

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

      if previous_token do
        Application.put_env(:dev_ide, :api_token, previous_token)
      else
        Application.delete_env(:dev_ide, :api_token)
      end

      if previous_runner_token do
        Application.put_env(:dev_ide, :runner_token, previous_runner_token)
      else
        Application.delete_env(:dev_ide, :runner_token)
      end
    end)

    seed_workspace()

    {:ok, conn: conn}
  end

  test "fleet transport endpoints require bearer auth", %{conn: conn} do
    conn =
      post(conn, "/api/fleet/v1/runners/register", %{
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert conn.status == 401
  end

  test "runner token is least privilege for fleet transport only", %{conn: conn} do
    Application.put_env(:dev_ide, :runner_token, @runner_token)

    register =
      conn
      |> runner_authed()
      |> post("/api/fleet/v1/runners/register", %{
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert register.status == 201

    denied =
      conn
      |> runner_authed()
      |> get("/api/workspaces")

    assert denied.status == 401
  end

  test "HTTP long-poll transport offers work and accepts runner protocol envelopes", %{
    conn: conn
  } do
    runner_id = Ecto.UUID.generate()

    register =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/register", %{
        "id" => runner_id,
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })
      |> json_response(201)

    assert register["transport"] == "devide.fleet.http.v1"
    assert register["runner"]["id"] == runner_id

    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-remote",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    :ok =
      DevIDE.Fleet.Queue.enqueue(
        assignment.id,
        AssignmentRequirements.new(capabilities: ["workspace-command:v1"], max_runtime_ms: 30_000)
      )

    offer =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/offers/poll", %{"timeout_ms" => 0})
      |> json_response(200)

    assert offer["transport"] == "devide.fleet.http.v1"
    assert offer["envelope"]["runner_id"] == runner_id
    assert offer["envelope"]["payload_type"] == "AssignmentOffered"
    assert offer["envelope"]["payload"]["assignment_id"] == assignment.id
    assert offer["envelope"]["payload"]["safe_action_id"] == "command:format"
    assert offer["assignment"]["state"] == "claimed"

    lease_id = offer["lease"]["id"]
    execution_id = Ecto.UUID.generate()

    started =
      %Messages.ExecutionStarted{
        assignment_id: assignment.id,
        execution_id: execution_id,
        started_at: DateTime.utc_now()
      }
      |> Protocol.wrap(runner_id: runner_id, lease_id: lease_id)
      |> Protocol.serialize()

    start_response =
      conn
      |> authed()
      |> post("/api/fleet/v1/messages", %{"envelope" => started})
      |> json_response(200)

    assert start_response["result"]["assignment"]["state"] == "running"

    output =
      %Messages.OutputChunk{
        assignment_id: assignment.id,
        execution_id: execution_id,
        stream: "stdout",
        chunk: "remote output\n",
        timestamp: DateTime.utc_now()
      }
      |> Protocol.wrap(runner_id: runner_id, lease_id: lease_id)
      |> Protocol.serialize()

    output_response =
      conn
      |> authed()
      |> post("/api/fleet/v1/messages", %{"envelope" => output})
      |> json_response(200)

    assert output_response["result"] == %{"accepted" => true, "kind" => "observational"}

    completed =
      %Messages.ExecutionCompleted{
        assignment_id: assignment.id,
        execution_id: execution_id,
        completed_at: DateTime.utc_now(),
        evidence: %{exit_code: 0}
      }
      |> Protocol.wrap(runner_id: runner_id, lease_id: lease_id)
      |> Protocol.serialize()

    complete_response =
      conn
      |> authed()
      |> post("/api/fleet/v1/messages", %{"envelope" => completed})
      |> json_response(200)

    assert complete_response["result"]["assignment"]["state"] == "completed"

    assert {:ok, final} = Assignments.get(assignment.id)
    assert final.state == "completed"

    assert :error = Fleet.get_lease(assignment.id)

    assert {:ok, projection} = ExecutionProjectionStore.get(execution_id)
    assert projection.state == :completed
    assert projection.runner_id == runner_id

    assert [%{stream: "stdout", data: "remote output\n"}] =
             ArtifactStore.chunks(execution_id)

    assert [%{stream: "stdout", chunk: "remote output\n"}] =
             OutputStream.chunks(execution_id)
  end

  test "offer poll returns 204 when no eligible assignment is available", %{conn: conn} do
    runner_id = Ecto.UUID.generate()

    _ =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/register", %{
        "id" => runner_id,
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })
      |> json_response(201)

    response =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/offers/poll", %{"timeout_ms" => 0})

    assert response.status == 204
  end

  test "offer poll rejects unknown runner", %{conn: conn} do
    response =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{Ecto.UUID.generate()}/offers/poll", %{"timeout_ms" => 0})

    assert response.status == 404
    assert json_response(response, 404) == %{"error" => "not_found"}
  end

  test "revoked runner is rejected on register, heartbeat, and poll", %{conn: conn} do
    runner_id = Ecto.UUID.generate()

    _ =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/register", %{
        "id" => runner_id,
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })
      |> json_response(201)

    {:ok, _identity} = Fleet.set_runner_trust_state(runner_id, :revoked)

    heartbeat =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/heartbeat", %{})

    assert heartbeat.status == 403
    assert json_response(heartbeat, 403) == %{"error" => "runner_revoked"}

    poll =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/offers/poll", %{"timeout_ms" => 0})

    assert poll.status == 403
    assert json_response(poll, 403) == %{"error" => "runner_revoked"}

    register =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/register", %{
        "id" => runner_id,
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert register.status == 403
    assert json_response(register, 403) == %{"error" => "runner_revoked"}
  end

  test "runner can drain and report graceful shutdown", %{conn: conn} do
    runner_id = Ecto.UUID.generate()

    _ =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/register", %{
        "id" => runner_id,
        "hostname" => "remote-a",
        "capabilities" => ["workspace-command:v1"]
      })
      |> json_response(201)

    drain =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/drain", %{})
      |> json_response(200)

    assert drain["identity"]["trust_state"] == "draining"
    assert {:ok, %{state: :draining}} = Fleet.get_runner(runner_id)

    shutdown =
      conn
      |> authed()
      |> post("/api/fleet/v1/runners/#{runner_id}/shutdown", %{})
      |> json_response(200)

    assert shutdown["runner"]["state"] == "offline"
    assert {:ok, %{state: :offline}} = Fleet.get_runner(runner_id)
  end

  test "message endpoint rejects invalid runner envelope", %{conn: conn} do
    envelope =
      %Messages.ExecutionStarted{
        assignment_id: Ecto.UUID.generate(),
        execution_id: Ecto.UUID.generate(),
        started_at: DateTime.utc_now()
      }
      |> Protocol.wrap(runner_id: "not-a-runner-id", lease_id: Ecto.UUID.generate())
      |> Protocol.serialize()

    response =
      conn
      |> authed()
      |> post("/api/fleet/v1/messages", %{"envelope" => envelope})

    assert response.status == 400
    assert json_response(response, 400) == %{"error" => "invalid_runner_id"}
  end

  defp authed(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  defp runner_authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @runner_token)

  defp seed_workspace do
    {:ok, _record} =
      State.sync_from_manager(%Workspace{
        id: "ws-remote",
        name: "Remote",
        user: "operator",
        branch: "main",
        type: :v3,
        status: :running,
        path: System.tmp_dir!(),
        raw: %{"id" => "ws-remote", "branch" => "main"}
      })
  end
end
