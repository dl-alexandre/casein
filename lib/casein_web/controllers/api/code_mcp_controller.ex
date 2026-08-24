defmodule CaseinWeb.API.CodeMCPController do
  @moduledoc """
  HTTP transport for the worktree-scoped Code MCP server.
  """

  use CaseinWeb, :controller

  alias CaseinWeb.API.{CodeMCP, MCPTransport}
  alias CaseinWeb.Plugs.AgentCapabilityAuthz

  def rpc(conn, _params) do
    conn = fetch_query_params(conn)
    workspace_id = default_workspace_id(conn)

    case MCPTransport.preflight(conn, conn.body_params) do
      {:halt, conn} ->
        conn

      {:cont, conn} ->
        opts =
          [
            default_workspace_id: workspace_id,
            actor: CaseinWeb.Plugs.ApiAuth.actor(conn)
          ] ++ AgentCapabilityAuthz.handler_opts(conn)

        case CodeMCP.handle(conn.body_params, opts) do
          {:reply, response} ->
            conn
            |> MCPTransport.maybe_issue_session(:code, conn.body_params, workspace_id)
            |> put_status(200)
            |> json(response)

          {:stream, subscription} ->
            MCPTransport.subscription_stream(conn, subscription)

          :noreply ->
            send_resp(conn, 202, "")

          {:error, response} ->
            conn |> put_status(400) |> json(response)
        end
    end
  end

  def info(conn, _params), do: MCPTransport.stream(conn, :code)

  def delete(conn, _params), do: MCPTransport.terminate(conn, :code)

  defp default_workspace_id(conn) do
    conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]
  end
end
