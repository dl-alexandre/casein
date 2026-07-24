defmodule Casein.Integrations.Manager.ClientTest do
  use Casein.TestCase, async: true

  alias Casein.Integrations.Manager.Client
  alias Casein.Integrations.Manager.Workspace
  alias Casein.Test.ManagerStub

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end

  describe "list/2" do
    test "200 with a JSON array decodes to Workspace structs" do
      Req.Test.stub(Client, fn conn ->
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

    test "200 with a non-list JSON body returns {:error, {:unexpected, _}}" do
      Req.Test.stub(Client, fn conn ->
        json(conn, 200, %{"not" => "a list"})
      end)

      assert {:error, {:unexpected, %{"not" => "a list"}}} = Client.list()
    end

    test "500 returns {:error, {:http, 500, body}}" do
      Req.Test.stub(Client, fn conn ->
        json(conn, 500, %{"error" => "boom"})
      end)

      assert {:error, {:http, 500, %{"error" => "boom"}}} = Client.list()
    end

    test "connection refused returns {:error, {:transport, _}}" do
      ManagerStub.transport_error(:econnrefused)
      assert {:error, {:transport, _reason}} = Client.list()
    end
  end

  describe "get/2" do
    test "200 with a JSON object decodes to a Workspace struct" do
      ManagerStub.stub_get(%{
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

    test "200 with a non-map JSON body returns {:error, {:unexpected, _}}" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "GET", path_info: ["api", "workspaces", "ws-x", "status"]} = conn ->
          json(conn, 200, ["not", "a", "map"])

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:error, {:unexpected, ["not", "a", "map"]}} = Client.get("ws-x")
    end

    test "404 returns {:error, {:http, 404, body}}" do
      ManagerStub.stub_get_not_found("missing")
      assert {:error, {:http, 404, %{"error" => "not_found"}}} = Client.get("missing")
    end
  end

  describe "create/2" do
    test "201 with a JSON object decodes to a Workspace struct" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "POST", path_info: ["api", "workspaces"]} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"name" => "fresh", "branch" => "topic"}
          json(conn, 201, %{"id" => "ws-new", "name" => "fresh", "status" => "queued"})

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:ok, %Workspace{} = ws} = Client.create(%{"name" => "fresh", "branch" => "topic"})
      assert ws.id == "ws-new"
      assert ws.status == :queued
    end

    test "200 with a non-map JSON body returns {:error, {:unexpected, _}}" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "POST", path_info: ["api", "workspaces"]} = conn ->
          json(conn, 200, [1, 2, 3])

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:error, {:unexpected, [1, 2, 3]}} = Client.create(%{"name" => "x"})
    end

    test "422 returns {:error, {:http, 422, body}}" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "POST", path_info: ["api", "workspaces"]} = conn ->
          json(conn, 422, %{"error" => "invalid"})

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:error, {:http, 422, %{"error" => "invalid"}}} = Client.create(%{"name" => ""})
    end
  end

  describe "start/2 and stop/2" do
    test "start/2 returns the raw 200 body (no Workspace wrapping)" do
      ManagerStub.stub_start("ws-1", %{"ok" => true, "status" => "starting"})
      assert {:ok, %{"ok" => true, "status" => "starting"}} = Client.start("ws-1")
    end

    test "stop/2 returns the raw 200 body" do
      ManagerStub.stub_stop("ws-1", %{"ok" => true, "status" => "stopped"})
      assert {:ok, %{"ok" => true, "status" => "stopped"}} = Client.stop("ws-1")
    end

    test "start/2 surfaces an HTTP error tuple" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "POST", path_info: ["api", "workspaces", "ws-1", "start"]} = conn ->
          json(conn, 409, %{"error" => "conflict"})

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:error, {:http, 409, %{"error" => "conflict"}}} = Client.start("ws-1")
    end

    test "stop/2 surfaces a transport error when the manager is down" do
      ManagerStub.transport_error(:econnrefused)
      assert {:error, {:transport, _reason}} = Client.stop("ws-1")
    end
  end

  describe "delete/3" do
    test "200 returns the raw body and forwards opts as query params" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "DELETE", path_info: ["api", "workspaces", "ws-1"]} = conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["purge"] == "true"
          json(conn, 200, %{"deleted" => true})

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:ok, %{"deleted" => true}} = Client.delete("ws-1", purge: true)
    end

    test "404 returns {:error, {:http, 404, body}}" do
      Req.Test.stub(Client, fn
        %Plug.Conn{method: "DELETE", path_info: ["api", "workspaces", "gone"]} = conn ->
          json(conn, 404, %{"error" => "gone"})

        conn ->
          json(conn, 404, %{"error" => "not_found"})
      end)

      assert {:error, {:http, 404, %{"error" => "gone"}}} = Client.delete("gone")
    end
  end

  describe "auth headers" do
    test "explicit email is sent as x-auth-request-email" do
      Req.Test.stub(Client, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-auth-request-email") == ["carol@example.com"]
        json(conn, 200, [])
      end)

      assert {:ok, []} = Client.list([], "carol@example.com")
    end
  end

  describe "stream_logs/3" do
    test "streams SSE 'data:' lines to the caller and signals done" do
      ManagerStub.stub_stream_logs("ws-1", "web", ["hello", "world"])

      {:ok, ref, task} = Client.stream_logs("ws-1", "web", self())

      assert_receive {:source_log, ^ref, "hello"}, 2_000
      assert_receive {:source_log, ^ref, "world"}, 2_000
      assert_receive {:source_log_done, ^ref}, 2_000

      Task.await(task, 2_000)
    end
  end
end
