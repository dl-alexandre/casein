defmodule DevIdeWeb.API.WorkspaceControllerTest do
  use DevIdeWeb.ConnCase, async: false

  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Devbox.Workspace
  alias DevIDE.Commands.History

  @token "test-token"

  setup %{conn: conn} do
    MemoryAdapter.clear()
    DevIDE.Audit.MemoryAdapter.clear()
    DevIDE.Commands.History.MemoryAdapter.clear()
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_commands_adapter = Application.get_env(:dev_ide, :commands_adapter)
    prev_fake_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :api_token, @token)
    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    on_exit(fn ->
      MemoryAdapter.clear()
      DevIDE.Audit.MemoryAdapter.clear()
      DevIDE.Commands.History.MemoryAdapter.clear()

      if prev_token,
        do: Application.put_env(:dev_ide, :api_token, prev_token),
        else: Application.delete_env(:dev_ide, :api_token)

      if prev_commands_adapter,
        do: Application.put_env(:dev_ide, :commands_adapter, prev_commands_adapter),
        else: Application.delete_env(:dev_ide, :commands_adapter)

      if prev_fake_pid,
        do: Application.put_env(:dev_ide, :fake_command_test_pid, prev_fake_pid),
        else: Application.delete_env(:dev_ide, :fake_command_test_pid)
    end)

    {:ok, conn: conn}
  end

  defp authed(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  defp seed_workspace(opts \\ []) do
    root = Keyword.get(opts, :root)
    db_isolation = Keyword.get(opts, :db_isolation)

    {:ok, _} =
      State.sync_from_manager(%Workspace{
        id: "ws-1",
        name: "alpha",
        user: "alice",
        branch: "main",
        type: :v3,
        status: :running,
        path: root,
        raw: %{
          "id" => "ws-1",
          "name" => "alpha",
          "DATABASE_URL" => "postgres://u:hunter2@stage.rds.amazonaws.com/app",
          "password" => "hunter2",
          "ports" => %{"app" => 4000}
        }
      })

    if db_isolation do
      {:ok, _} =
        State.persist_isolation("ws-1", %DbIsolation{
          isolation: db_isolation,
          source: :env_file,
          summary: Atom.to_string(db_isolation),
          detected_at: DateTime.utc_now()
        })
    end
  end

  test "401 without token", %{conn: conn} do
    conn = get(conn, "/api/workspaces")
    assert conn.status == 401
  end

  test "503 when token is unset", %{conn: conn} do
    Application.delete_env(:dev_ide, :api_token)
    conn = get(conn, "/api/workspaces")
    assert conn.status == 503
    assert json_response(conn, 503) == %{"error" => "api_token_not_configured"}
  end

  test "/api/workspaces lists synced records", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces") |> json_response(200)
    assert is_list(body)
    [ws] = body
    assert ws["id"] == "ws-1"
    assert ws["name"] == "alpha"
    assert ws["status"] == "running"
  end

  test "/api/workspaces/:id/status returns mode + isolation + recent fields", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/status") |> json_response(200)

    assert body["workspace"]["id"] == "ws-1"
    assert body["mode"]["value"]
    assert body["mode"]["source"]
    assert body["db_isolation"]
    assert is_list(body["recent_runs"])
    assert is_list(body["recent_proposals"])
    assert is_list(body["recent_audit"])
  end

  test "/api/workspaces/:id/runs", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/runs") |> json_response(200)
    assert is_list(body)
  end

  test "POST /api/workspaces/:id/runs starts an allowlisted command through DevIDE", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :local)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{"command_id" => "test"})
      |> json_response(201)

    assert %{"id" => run_id, "command_id" => "test", "status" => status} = body
    assert is_binary(run_id)
    assert status in ["running", "succeeded"]

    assert_receive {:fake_command_spawned, ^root, ["mix", "test", "--color"]}
    refute_received {:fake_command_spawned, _root, ["test"]}

    assert [%{actor_id: "jx", command_id: "test", argv: ["mix", "test", "--color"]}] =
             History.recent_for("ws-1", 10)

    assert [%{action: "command.started", decision: :allow, target_ref: "test"}] =
             DevIDE.Audit.recent_for("ws-1", 10)
  end

  test "POST /api/workspaces/:id/runs requires bearer auth", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :local)

    conn = post(conn, "/api/workspaces/ws-1/runs", %{"command_id" => "test"})
    assert conn.status == 401
    refute_received {:fake_command_spawned, ^root, _argv}
  end

  test "POST /api/workspaces/:id/runs rejects unsupported command_id", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :local)

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{"command_id" => "deploy"})
      |> json_response(400)

    assert body == %{"error" => "command_not_allowed"}
    refute_received {:fake_command_spawned, _root, _argv}

    assert [%{action: "policy.blocked", decision: :deny, reason: :not_allowed}] =
             DevIDE.Audit.recent_for("ws-1", 10)
  end

  test "POST /api/workspaces/:id/runs rejects unsafe and shared-stage DB", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :unsafe)

    unsafe =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{"command_id" => "compile"})
      |> json_response(403)

    assert unsafe == %{"error" => "unsafe_db_isolation"}

    MemoryAdapter.clear()
    seed_workspace(root: root, db_isolation: :shared_stage)

    shared =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{"command_id" => "compile"})
      |> json_response(403)

    assert shared == %{"error" => "unsafe_db_isolation"}
    refute_received {:fake_command_spawned, _root, _argv}
  end

  test "POST /api/workspaces/:id/runs requires command_id and does not accept argv", %{conn: conn} do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :local)

    missing =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{})
      |> json_response(400)

    assert missing == %{"error" => "command_id_required"}

    body =
      conn
      |> authed()
      |> post("/api/workspaces/ws-1/runs", %{
        "command_id" => "format",
        "argv" => ["rm", "-rf", "/"]
      })
      |> json_response(201)

    assert body["command_id"] == "format"
    assert_receive {:fake_command_spawned, ^root, ["mix", "format", "--check-formatted"]}
    refute_received {:fake_command_spawned, ^root, ["rm", "-rf", "/"]}
  end

  test "POST /api/workspaces/:id/runs can enqueue runner protocol assignments without argv", %{
    conn: conn
  } do
    root = temp_workspace_root!()
    seed_workspace(root: root, db_isolation: :local)

    body =
      conn
      |> authed()
      |> Plug.Conn.put_req_header("x-jx-correlation-id", "corr-jx-runner")
      |> post("/api/workspaces/ws-1/runs", %{
        "execution_protocol" => "jx.runner.v1",
        "command_id" => "test",
        "jx_assignment_id" => "asgn-jx",
        "jx_action_id" => "act-jx",
        "argv" => ["rm", "-rf", "/"]
      })
      |> json_response(201)

    assert body["protocol"] == "jx.runner.v1"
    assert body["assignment"]["safe_action_id"] == "command:test"
    assert body["assignment"]["action"]["argv"] == ["mix", "test", "--color"]
    assert body["assignment"]["metadata"]["correlation_id"] == "corr-jx-runner"
    assert body["assignment"]["metadata"]["jx_assignment_id"] == "asgn-jx"
    refute body["assignment"]["claim_token"]

    refute_received {:fake_command_spawned, _root, _argv}
  end

  test "/api/workspaces/:id/proposals", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/proposals") |> json_response(200)
    assert is_list(body)
  end

  test "/api/workspaces/:id/audit", %{conn: conn} do
    seed_workspace()
    body = conn |> authed() |> get("/api/workspaces/ws-1/audit") |> json_response(200)
    assert is_list(body)
  end

  test "404 for unknown workspace", %{conn: conn} do
    Application.put_env(:dev_ide, :api_token, @token)
    conn = conn |> authed() |> get("/api/workspaces/no-such/status")
    assert conn.status == 404
  end

  test "no secrets leak in /status response", %{conn: conn} do
    seed_workspace()
    raw = conn |> authed() |> get("/api/workspaces/ws-1/status") |> response(200)

    refute raw =~ "hunter2"
    refute raw =~ "DATABASE_URL"
    refute raw =~ "postgres://u:"
  end

  test "other workspace writes are not exposed on /api/* routes", %{conn: conn} do
    seed_workspace()
    base = authed(conn)

    assert_no_route = fn fun ->
      try do
        result = fun.(base)
        assert result.status in [404, 405]
      rescue
        Phoenix.Router.NoRouteError -> :ok
      end
    end

    assert_no_route.(fn c -> post(c, "/api/workspaces") end)
    assert_no_route.(fn c -> put(c, "/api/workspaces/ws-1/status") end)
    assert_no_route.(fn c -> delete(c, "/api/workspaces/ws-1") end)
    assert_no_route.(fn c -> patch(c, "/api/workspaces/ws-1/status") end)
  end

  defp temp_workspace_root! do
    root = Path.join(System.tmp_dir!(), "devide-api-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
