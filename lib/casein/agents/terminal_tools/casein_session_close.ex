defmodule Casein.Agents.TerminalTools.CaseinSessionClose do
  @moduledoc "Close only the authenticated MCP transport session for this call."

  use Jido.Action,
    name: "casein_session_close",
    description:
      "Close the current authenticated Casein MCP transport session. This ends the protocol session only; it does not stop a Workcell, cancel a worker, or touch tmux.",
    category: "terminal",
    tags: ["terminal", "session"],
    vsn: "1.0.0",
    schema: [workspace_id: [type: :string]]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.MCPSessions
  alias Casein.Agents.TerminalTools.Helpers
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters, do: Tool.object(Helpers.workspace_props())

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("casein_session_close")

  def run(params) when is_map(params), do: run(params, %{})

  @impl Jido.Action
  def run(_params, context) when is_map(context) do
    session_id = Map.get(context, :mcp_session_id)

    if is_binary(session_id) and session_id != "" do
      expected = %{
        server: Map.get(context, :mcp_server, :terminal),
        workspace_id: Map.get(context, :workspace_id),
        auth_scope: Map.get(context, :mcp_auth_scope)
      }

      case MCPSessions.close_authorized(session_id, expected) do
        :ok -> {:ok, %{closed?: true, session_id: session_id, scope: "mcp_transport"}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :mcp_session_required}
    end
  end

  def run(_params, _context), do: {:error, :mcp_session_required}
end
