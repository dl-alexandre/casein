defmodule DevIdeWeb.API.PreviewMCPController do
  @moduledoc """
  HTTP transport for the preview-control MCP server.

  Agents connect here (`POST /api/preview/mcp`) to discover and call
  `DevIDE.Agents.PreviewTools`. Authentication is the same bearer-token gate
  as the rest of the read-only API (`DevIdeWeb.Plugs.ApiAuth`). The protocol
  logic lives in `DevIdeWeb.API.PreviewMCP`; this controller only maps its
  outcomes onto HTTP status codes.
  """

  use DevIdeWeb, :controller

  alias DevIdeWeb.API.PreviewMCP

  # MCP messages are JSON-RPC objects in the request body.
  def rpc(conn, _params) do
    conn = fetch_query_params(conn)

    case PreviewMCP.handle(conn.body_params,
           default_workspace_id: conn.query_params["workspace_id"]
         ) do
      {:reply, response} ->
        conn |> put_status(200) |> json(response)

      :noreply ->
        send_resp(conn, 202, "")

      {:error, response} ->
        conn |> put_status(400) |> json(response)
    end
  end

  # MCP over plain HTTP POST only; no SSE stream on GET.
  def info(conn, _params) do
    conn |> put_status(405) |> json(%{error: "method_not_allowed"})
  end
end
