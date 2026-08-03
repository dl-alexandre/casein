defmodule Casein.Agents.TerminalTools.RequestHumanInput do
  @moduledoc "terminal_request_human_input."

  use Jido.Action,
    name: "terminal_request_human_input",
    description:
      "Create one durable Needs Me request for this exact role-marked agent pane. Kinds: clarification, direction, blocker. Choices are bounded server-declared labels; use a stable request_id to coalesce retries.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      pane: [type: :string, required: true],
      request_id: [type: :string, required: true],
      agent_session_id: [type: :string, required: true],
      kind: [type: :string, required: true],
      prompt: [type: :string, required: true],
      choices: [type: {:list, :string}]
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
        kind: %{
          type: "string",
          enum: ["clarification", "direction", "blocker"],
          description: "The bounded human-decision contract to project."
        },
        prompt: %{
          type: "string",
          minLength: 1,
          maxLength: 200,
          description: "One bounded prompt; never copied into generic MCP audit."
        },
        choices: %{
          type: "array",
          maxItems: 4,
          items: %{type: "string", minLength: 1, maxLength: 60},
          description: "Optional declared direction or recovery choices."
        }
      }),
      ["workspace_id", "session", "pane", "request_id", "agent_session_id", "kind", "prompt"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_request_human_input")

  @impl Jido.Action
  def run(params, _context), do: Agent.request_human_input(Helpers.to_impl_args(params))
end
