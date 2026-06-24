defmodule DevIDE.Integrations.Manager.ClientTest do
  # async: false — these tests mutate application env (:manager_url,
  # :manager_user_email) which is global process state.
  use ExUnit.Case, async: false

  alias DevIDE.Integrations.Manager.Client
  alias DevIDE.Integrations.Manager.Workspace

  setup do
    bypass = Bypass.open()

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_email = Application.get_env(:dev_ide, :manager_user_email)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    # Clear any static fallback email so default auth-header tests are deterministic.
    Application.delete_env(:dev_ide, :manager_user_email)

    on_exit(fn ->
      restore(:manager_url, prev_manager)
      restore(:manager_user_email, prev_email)
    end)

    {:ok, bypass: bypass}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  describe "base_url/0" do
    test "returns the configured :manager_url", %{bypass: bypass} do
      assert Client.base_url() == "http://localhost:#{bypass.port}"
    end

    test "falls back to the default localhost URL when unconfigured and no env" do
      Application.delete_env(:dev_ide, :manager_url)
      # Ensure the System env override is not set during this assertion.
      prev = System.get_env("MILC_DEVBOX_MANAGER_URL")
      System.delete_env("MILC_DEVBOX_MANAGER_URL")

      try do
        assert Client.base_url() == "http://localhost:9000"
      after
        if prev, do: System.put_env("MILC_DEVBOX_MANAGER_URL", prev)
      end
    end

    test "prefers the MILC_DEVBOX_MANAGER_URL env over the default" do
      Application.delete_env(:dev_ide, :manager_url)
      prev = System.get_env("MILC_DEVBOX_MANAGER_URL")
      System.put_env("MILC_DEVBOX_MANAGER_URL", "http://example.test:1234")

      try do
        assert Client.base_url() == "http://example.test:1234"
      after
        if prev,
          do: System.put_env("MILC_DEVBOX_MANAGER_URL", prev),
          else: System.delete_env("MILC_DEVBOX_MANAGER_URL")
      end
    end
  end

  describe "list/2" do
    test "200 with a JSON array decodes to Workspace structs", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        # opts are sent as query params
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["user"] == "alice"

        json(conn, 200, [
          %{"id" => "ws-1", "name" => "one", "status" => "running", "type" => "v3"},
          %{"id" => "ws-2", "name" => "two", "status" => "stopped", "type" => "legacy"}
        ])
      end)

      assert {:ok, [%Workspace{} = a, %Workspace{} = b]} = Client.list(user: "alice")
      assert a.id == "ws-1"
      assert a.name == "one"
      assert a.status == :running
      assert a.type == :v3
      assert b.id == "ws-2"
      assert b.status == :stopped
      assert b.type == :legacy
    end

    test "200 with a non-list JSON body returns {:error, {:unexpected, _}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        json(conn, 200, %{"not" => "a list"})
      end)

      assert {:error, {:unexpected, %{"not" => "a list"}}} = Client.list()
    end

    test "500 returns {:error, {:http, 500, body}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:http, 500, %{"error" => "boom"}}} = Client.list()
    end

    test "connection refused returns {:error, {:transport, _}}", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, {:transport, _reason}} = Client.list()
    end
  end

  describe "get/2" do
    test "200 with a JSON object decodes to a Workspace struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces/ws-9/status", fn conn ->
        json(conn, 200, %{
          "id" => "ws-9",
          "name" => "nine",
          "user" => "bob",
          "status" => "creating",
          "type" => "v3",
          "branch" => "main",
          "path" => "/srv/ws-9",
          "slot" => 3,
          "domainBase" => "example.dev",
          "ports" => %{"web" => 8080},
          "createdAt" => "2026-01-01T00:00:00Z",
          "lastStarted" => "2026-01-02T00:00:00Z"
        })
      end)

      assert {:ok, %Workspace{} = ws} = Client.get("ws-9")
      assert ws.id == "ws-9"
      assert ws.user == "bob"
      assert ws.status == :creating
      assert ws.slot == 3
      assert ws.domain_base == "example.dev"
      assert ws.ports == %{"web" => 8080}
      assert ws.created_at == "2026-01-01T00:00:00Z"
      assert ws.last_started == "2026-01-02T00:00:00Z"
    end

    test "200 with a non-map JSON body returns {:error, {:unexpected, _}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces/ws-x/status", fn conn ->
        json(conn, 200, ["not", "a", "map"])
      end)

      assert {:error, {:unexpected, ["not", "a", "map"]}} = Client.get("ws-x")
    end

    test "404 returns {:error, {:http, 404, body}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces/missing/status", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, {:http, 404, %{"error" => "not found"}}} = Client.get("missing")
    end
  end

  describe "create/2" do
    test "201 with a JSON object decodes to a Workspace struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"name" => "fresh", "branch" => "topic"}

        json(conn, 201, %{"id" => "ws-new", "name" => "fresh", "status" => "queued"})
      end)

      assert {:ok, %Workspace{} = ws} = Client.create(%{"name" => "fresh", "branch" => "topic"})
      assert ws.id == "ws-new"
      assert ws.status == :queued
    end

    test "200 with a non-map JSON body returns {:error, {:unexpected, _}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces", fn conn ->
        json(conn, 200, [1, 2, 3])
      end)

      assert {:error, {:unexpected, [1, 2, 3]}} = Client.create(%{"name" => "x"})
    end

    test "422 returns {:error, {:http, 422, body}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces", fn conn ->
        json(conn, 422, %{"error" => "invalid"})
      end)

      assert {:error, {:http, 422, %{"error" => "invalid"}}} = Client.create(%{"name" => ""})
    end
  end

  describe "start/2 and stop/2" do
    test "start/2 returns the raw 200 body (no Workspace wrapping)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/start", fn conn ->
        json(conn, 200, %{"ok" => true, "status" => "starting"})
      end)

      assert {:ok, %{"ok" => true, "status" => "starting"}} = Client.start("ws-1")
    end

    test "stop/2 returns the raw 200 body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/stop", fn conn ->
        json(conn, 200, %{"ok" => true, "status" => "stopped"})
      end)

      assert {:ok, %{"ok" => true, "status" => "stopped"}} = Client.stop("ws-1")
    end

    test "start/2 surfaces an HTTP error tuple", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/start", fn conn ->
        json(conn, 409, %{"error" => "conflict"})
      end)

      assert {:error, {:http, 409, %{"error" => "conflict"}}} = Client.start("ws-1")
    end

    test "stop/2 surfaces a transport error when the manager is down", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, {:transport, _reason}} = Client.stop("ws-1")
    end
  end

  describe "delete/3" do
    test "200 returns the raw body and forwards opts as query params", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/api/workspaces/ws-1", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["purge"] == "true"
        json(conn, 200, %{"deleted" => true})
      end)

      assert {:ok, %{"deleted" => true}} = Client.delete("ws-1", purge: true)
    end

    test "404 returns {:error, {:http, 404, body}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/api/workspaces/gone", fn conn ->
        json(conn, 404, %{"error" => "gone"})
      end)

      assert {:error, {:http, 404, %{"error" => "gone"}}} = Client.delete("gone")
    end
  end

  describe "auth headers" do
    test "explicit email is sent as x-auth-request-email", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["carol@example.com"]
        json(conn, 200, [])
      end)

      assert {:ok, []} = Client.list([], "carol@example.com")
    end

    test "nil auth with no static config sends no auth header", %{bypass: bypass} do
      Application.delete_env(:dev_ide, :manager_user_email)
      prev = System.get_env("DEV_IDE_DEVBOX_USER_EMAIL")
      System.delete_env("DEV_IDE_DEVBOX_USER_EMAIL")

      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == []
        json(conn, 200, [])
      end)

      try do
        assert {:ok, []} = Client.list([], nil)
      after
        if prev, do: System.put_env("DEV_IDE_DEVBOX_USER_EMAIL", prev)
      end
    end

    test "nil auth falls back to the static :manager_user_email config", %{bypass: bypass} do
      Application.put_env(:dev_ide, :manager_user_email, "static@example.com")

      Bypass.expect_once(bypass, "GET", "/api/workspaces", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["static@example.com"]
        json(conn, 200, [])
      end)

      assert {:ok, []} = Client.list([], nil)
    end
  end

  describe "stream_logs/3" do
    test "streams SSE 'data:' lines to the caller and signals done", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/workspaces/ws-1/logs/web", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "data: hello\n")
        {:ok, conn} = Plug.Conn.chunk(conn, "data: world\n")
        # Non-data lines (e.g. SSE comments / blank lines) must be ignored.
        {:ok, conn} = Plug.Conn.chunk(conn, ": keep-alive\n\n")
        conn
      end)

      {:ok, ref, task} = Client.stream_logs("ws-1", "web", self())

      assert_receive {:source_log, ^ref, "hello"}, 2_000
      assert_receive {:source_log, ^ref, "world"}, 2_000
      assert_receive {:source_log_done, ^ref}, 2_000

      # The async task should finish cleanly.
      Task.await(task, 2_000)
    end
  end
end
