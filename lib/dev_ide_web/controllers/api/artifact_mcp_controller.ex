defmodule DevIdeWeb.API.ArtifactMCPController do
  @moduledoc """
  HTTP transport for the artifact-project MCP server.
  """

  use DevIdeWeb, :controller

  alias DevIdeWeb.API.{ArtifactMCP, MCPTransport}

  # MCP messages are JSON-RPC objects in the request body.
  def rpc(conn, _params) do
    conn = fetch_query_params(conn)
    workspace_id = default_workspace_id(conn)

    case MCPTransport.ensure_known_session(conn) do
      {:halt, conn} ->
        conn

      {:cont, conn} ->
        case ArtifactMCP.handle(conn.body_params,
               default_workspace_id: workspace_id,
               actor: DevIdeWeb.Plugs.ApiAuth.actor(conn)
             ) do
          {:reply, response} ->
            conn
            |> MCPTransport.maybe_issue_session(:artifact, conn.body_params, workspace_id)
            |> put_status(200)
            |> json(response)

          :noreply ->
            send_resp(conn, 202, "")

          {:error, response} ->
            conn |> put_status(400) |> json(response)
        end
    end
  end

  # Streamable HTTP: open the server->client SSE channel for the session.
  def info(conn, _params), do: MCPTransport.stream(conn, :artifact)

  # Streamable HTTP: tear down the session.
  def delete(conn, _params), do: MCPTransport.terminate(conn)

  defp default_workspace_id(conn) do
    conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]
  end
end
