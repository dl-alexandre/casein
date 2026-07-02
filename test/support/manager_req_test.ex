defmodule DevIDE.Test.ManagerReqTest do
  @moduledoc false

  alias DevIDE.Integrations.Manager.Client

  def setup(context) do
    Req.Test.set_req_test_from_context(context)
    Req.Test.stub(Client, &default_response/1)

    if pid = Process.whereis(DevIDE.PreviewPanes) do
      Req.Test.allow(Client, self(), pid)
    end

    :ok
  end

  def default_response(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case {conn.method, conn.path_info, conn.query_params} do
      {"GET", ["api", "workspaces"], _} ->
        json(conn, 200, [])

      {"GET", ["api", "workspaces", _id, "status"], _} ->
        json(conn, 404, %{"error" => "not_found"})

      {"POST", ["api", "workspaces", _workspace_id, "start"], _} ->
        json(conn, 200, %{"ok" => true, "status" => "starting"})

      {"POST", ["api", "workspaces", _workspace_id, "stop"], _} ->
        json(conn, 200, %{"ok" => true, "status" => "stopped"})

      {"POST", ["api", "workspaces"], _} ->
        json(conn, 201, %{"id" => "ws-new", "name" => "fresh", "status" => "queued"})

      {"DELETE", ["api", "workspaces", _workspace_id], _} ->
        json(conn, 200, %{"deleted" => true})

      _ ->
        json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(payload))
  end
end
