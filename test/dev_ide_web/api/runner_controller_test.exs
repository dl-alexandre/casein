defmodule DevIdeWeb.API.RunnerControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  @token "runner-token"

  setup %{conn: conn} do
    MemoryAdapter.clear()
    Runners.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_runner = Application.get_env(:dev_ide, :runner_protocol_adapter)

    Application.put_env(:dev_ide, :api_token, @token)
    Application.put_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      DevIDE.Audit.MemoryAdapter.clear()

      if prev_token,
        do: Application.put_env(:dev_ide, :api_token, prev_token),
        else: Application.delete_env(:dev_ide, :api_token)

      if prev_runner,
        do: Application.put_env(:dev_ide, :runner_protocol_adapter, prev_runner),
        else: Application.delete_env(:dev_ide, :runner_protocol_adapter)
    end)

    seed_workspace()
    {:ok, conn: conn}
  end

  test "runner endpoints require bearer auth", %{conn: conn} do
    conn =
      post(conn, "/api/runner/v1/assignments/poll", %{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })

    assert conn.status == 401
  end

  test "poll claims one assignment and complete produces replayable evidence", %{conn: conn} do
    {:ok, queued} = Runners.enqueue_command("ws-1", "format")

    body =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/poll", %{
        "protocol" => Runners.protocol(),
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"],
        "workspace_ids" => ["ws-1"]
      })
      |> json_response(200)

    assignment = body["assignment"]
    assert assignment["id"] == queued.id
    assert assignment["status"] == "claimed"
    assert assignment["claim_token"]
    assert assignment["action"]["argv"] == ["mix", "format", "--check-formatted"]

    no_work =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/poll", %{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"],
        "workspace_ids" => ["ws-1"]
      })

    assert no_work.status == 204

    report =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/#{assignment["id"]}/reports", %{
        "claim_token" => assignment["claim_token"],
        "event" => "progress",
        "message" => "formatting"
      })
      |> json_response(201)

    assert report["report"]["position"] == 1

    complete =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/#{assignment["id"]}/complete", %{
        "claim_token" => assignment["claim_token"],
        "message" => "ok",
        "evidence" => %{"exit_code" => 0, "output_sha256" => "abc"}
      })
      |> json_response(200)

    assert complete["assignment"]["status"] == "succeeded"
    assert complete["report"]["event"] == "completed"

    replay =
      conn
      |> authed()
      |> get("/api/runner/v1/assignments/#{assignment["id"]}")
      |> json_response(200)

    assert replay["assignment"]["status"] == "succeeded"
    refute Map.has_key?(replay["assignment"], "claim_token")
    assert Enum.map(replay["reports"], & &1["position"]) == [1, 2]
  end

  test "runner HTTP surface cannot create assignments or proxy arbitrary payloads", %{conn: conn} do
    assert_no_route(fn ->
      conn
      |> authed()
      |> post("/api/runner/v1/assignments", %{
        "workspace_id" => "ws-1",
        "safe_action_id" => "command:test",
        "argv" => ["rm", "-rf", "/"]
      })
    end)

    {:ok, _queued} = Runners.enqueue_command("ws-1", "test")

    body =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/poll", %{
        "runner_id" => "runner-a",
        "capabilities" => ["workspace-command:v1"]
      })
      |> json_response(200)

    assignment = body["assignment"]

    forbidden =
      conn
      |> authed()
      |> post("/api/runner/v1/assignments/#{assignment["id"]}/reports", %{
        "claim_token" => assignment["claim_token"],
        "event" => "progress",
        "evidence" => %{"method" => "POST", "url" => "https://example.test"}
      })
      |> json_response(400)

    assert forbidden == %{
             "error" => "forbidden_payload",
             "failure_class" => "report_rejected"
           }
  end

  defp authed(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  defp assert_no_route(fun) do
    try do
      conn = fun.()
      assert conn.status in [404, 405]
    rescue
      Phoenix.Router.NoRouteError -> :ok
    end
  end

  defp seed_workspace do
    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-1",
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: "/tmp/ws-1",
        metadata: %{"id" => "ws-1"}
      })

    {:ok, _} =
      State.persist_isolation("ws-1", %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end
end
