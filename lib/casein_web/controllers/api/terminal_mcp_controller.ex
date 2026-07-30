defmodule CaseinWeb.API.TerminalMCPController do
  @moduledoc """
  HTTP transport for the terminal-control MCP server.

  Agents connect here (`POST /api/terminals/mcp`) to discover and call
  `Casein.Agents.TerminalTools`. Authentication is the same bearer-token gate
  as the rest of the read-only API (`CaseinWeb.Plugs.ApiAuth`). The protocol
  logic lives in `CaseinWeb.API.TerminalMCP`; this controller only maps its
  outcomes onto HTTP status codes.
  """

  use CaseinWeb, :controller

  alias CaseinWeb.API.{MCPTransport, TerminalMCP}
  alias CaseinWeb.Plugs.AgentCapabilityAuthz

  # MCP messages are JSON-RPC objects in the request body.
  def rpc(conn, _params) do
    conn = fetch_query_params(conn)
    workspace_id = default_workspace_id(conn)
    caller_pane = default_caller_pane(conn)

    case MCPTransport.preflight(conn, conn.body_params) do
      {:halt, conn} ->
        conn

      {:cont, conn} ->
        opts =
          [
            default_workspace_id: workspace_id,
            default_caller_pane: caller_pane,
            actor: CaseinWeb.Plugs.ApiAuth.actor(conn)
          ] ++ AgentCapabilityAuthz.handler_opts(conn)

        case TerminalMCP.handle(conn.body_params, opts) do
          {:reply, response} ->
            conn
            |> MCPTransport.maybe_issue_session(:terminal, conn.body_params, workspace_id)
            |> put_status(200)
            |> json(response)

          # A `subscriptions/listen` response is itself a long-lived SSE stream.
          {:stream, subscription} ->
            MCPTransport.subscription_stream(conn, subscription)

          :noreply ->
            send_resp(conn, 202, "")

          {:error, response} ->
            conn |> put_status(400) |> json(response)
        end
    end
  end

  # Streamable HTTP: open the server→client SSE channel for the session.
  def info(conn, _params), do: MCPTransport.stream(conn, :terminal)

  # Streamable HTTP: tear down the session.
  def delete(conn, _params), do: MCPTransport.terminate(conn, :terminal)

  defp default_workspace_id(conn) do
    conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]
  end

  # The calling agent's own tmux pane. Casein-launched agents send it via the
  # X-Casein-Caller-Pane header (env-expanded per pane at client startup);
  # hand-built URLs may use a caller_pane query param. Values that are not a
  # tmux pane id (unset/unexpanded env placeholders) are ignored.
  defp default_caller_pane(conn) do
    header = conn |> get_req_header("x-casein-caller-pane") |> List.first()
    value = header || conn.query_params["caller_pane"]

    with value when is_binary(value) <- value,
         value = String.trim(value),
         true <- Regex.match?(~r/^%\d+$/, value) do
      value
    else
      _ -> nil
    end
  end
end
