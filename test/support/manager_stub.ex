defmodule Casein.Test.ManagerStub do
  @moduledoc "Req.Test stubs for the Integrations Manager HTTP client."

  alias Casein.Integrations.Manager.Client

  def stub_list(workspaces \\ []) do
    Req.Test.stub(Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(workspaces))
    end)
  end

  def stub_get(workspace) when is_map(workspace) do
    id = Map.get(workspace, "id") || Map.get(workspace, :id)

    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^id, "status"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(workspace))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_get_not_found(id) when is_binary(id) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^id, "status"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_start(id, body \\ %{"ok" => true}) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "POST", path_info: ["api", "workspaces", ^id, "start"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_stop(id, body \\ %{"ok" => true}) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "POST", path_info: ["api", "workspaces", ^id, "stop"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_create(workspace) when is_map(workspace) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "POST", path_info: ["api", "workspaces"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, Jason.encode!(workspace))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_delete(id, body \\ %{"deleted" => true}) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "DELETE", path_info: ["api", "workspaces", ^id]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def stub_stream_logs(id, service, lines) do
    Req.Test.stub(Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^id, "logs", ^service]} = conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(lines, conn, fn line, acc ->
          {:ok, acc} = Plug.Conn.chunk(acc, "data: #{line}\n")
          acc
        end)

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)
  end

  def transport_error(reason) do
    Req.Test.stub(Client, fn conn -> Req.Test.transport_error(conn, reason) end)
  end
end
