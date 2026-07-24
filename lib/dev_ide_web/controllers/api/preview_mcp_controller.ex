defmodule CaseinWeb.API.PreviewMCPController do
  @moduledoc """
  HTTP transport for the preview-control MCP server.

  Agents connect here (`POST /api/preview/mcp`) to discover and call
  `Casein.Agents.PreviewTools`. Authentication is the same bearer-token gate
  as the rest of the read-only API (`CaseinWeb.Plugs.ApiAuth`). The protocol
  logic lives in `CaseinWeb.API.PreviewMCP`; this controller only maps its
  outcomes onto HTTP status codes.
  """

  use CaseinWeb, :controller

  alias Casein.Terminals
  alias Casein.Workspaces
  alias CaseinWeb.API.{MCPTransport, PreviewMCP}
  alias CaseinWeb.Plugs.AgentCapabilityAuthz

  # MCP messages are JSON-RPC objects in the request body.
  def rpc(conn, _params) do
    conn = fetch_query_params(conn)
    workspace_id = default_workspace_id(conn)
    tmux_session = default_tmux_session(conn)

    with {:cont, conn} <- MCPTransport.ensure_known_session(conn),
         :ok <- validate_tmux_session_scope(workspace_id, tmux_session) do
      opts =
        [
          default_workspace_id: workspace_id,
          default_tmux_session: tmux_session,
          actor: CaseinWeb.Plugs.ApiAuth.actor(conn)
        ] ++
          AgentCapabilityAuthz.handler_opts(conn)

      case PreviewMCP.handle(conn.body_params, opts) do
        {:reply, response} ->
          conn
          |> MCPTransport.maybe_issue_session(:preview, conn.body_params, workspace_id)
          |> put_status(200)
          |> json(response)

        :noreply ->
          send_resp(conn, 202, "")

        {:error, response} ->
          conn |> put_status(400) |> json(response)
      end
    else
      {:halt, conn} ->
        conn

      {:error, response} ->
        conn |> put_status(400) |> json(response)
    end
  end

  # Streamable HTTP: open the server→client SSE channel for the session.
  def info(conn, _params), do: MCPTransport.stream(conn, :preview)

  # Streamable HTTP: tear down the session.
  def delete(conn, _params), do: MCPTransport.terminate(conn, :preview)

  defp default_workspace_id(conn) do
    conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]
  end

  defp default_tmux_session(conn) do
    conn.query_params["tmux_session"]
  end

  defp validate_tmux_session_scope(_workspace_id, nil), do: :ok
  defp validate_tmux_session_scope(_workspace_id, ""), do: :ok

  defp validate_tmux_session_scope(workspace_id, tmux_session)
       when is_binary(workspace_id) and is_binary(tmux_session) do
    prefixes = workspace_session_prefixes(workspace_id)

    if Enum.any?(prefixes, &String.starts_with?(tmux_session, &1)) do
      :ok
    else
      {:error,
       %{
         error: "invalid_tmux_session_scope",
         workspace_id: workspace_id,
         tmux_session: tmux_session,
         allowed_prefixes: prefixes
       }}
    end
  end

  defp validate_tmux_session_scope(_workspace_id, tmux_session) when is_binary(tmux_session) do
    {:error, %{error: "tmux_session_requires_workspace", tmux_session: tmux_session}}
  end

  defp validate_tmux_session_scope(_workspace_id, _tmux_session), do: :ok

  defp workspace_session_prefixes(workspace_id) do
    prefixes = [Terminals.tmux_workspace_session_prefix(workspace_id)]

    case Workspaces.get(workspace_id) do
      {:ok, workspace} ->
        [workspace.name, workspace.id]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&Terminals.tmux_workspace_session_prefix/1)
        |> Enum.concat(prefixes)
        |> Enum.uniq()

      _ ->
        prefixes
    end
  end
end
