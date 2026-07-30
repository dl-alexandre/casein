defmodule Casein.Agents.TerminalTools.RequestClarification do
  @moduledoc "terminal_request_clarification."

  use Jido.Action,
    name: "terminal_request_clarification",
    description:
      "Create one durable mobile clarification request for this exact role-marked agent pane. The request is workspace/task/revision bound; clients cannot create it. Use a stable request_id to coalesce retries.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      pane: [type: :string, required: true],
      request_id: [type: :string, required: true],
      agent_session_id: [type: :string, required: true],
      question: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(Helpers.workspace_props(), %{
        session: Helpers.session_param(),
        pane: Helpers.pane_param(),
        request_id: %{
          type: "string",
          minLength: 8,
          maxLength: 240,
          description: "Stable opaque id for idempotent request creation."
        },
        agent_session_id: Helpers.agent_session_id_param(),
        question: %{
          type: "string",
          minLength: 1,
          maxLength: 200,
          description: "One bounded clarification question; never copied into generic MCP audit."
        }
      }),
      ["workspace_id", "session", "pane", "request_id", "agent_session_id", "question"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_request_clarification")

  @impl Jido.Action
  def run(params, _context), do: Agent.request_clarification(Helpers.to_impl_args(params))
end
