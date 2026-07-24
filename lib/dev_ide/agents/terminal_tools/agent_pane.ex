defmodule DevIDE.Agents.TerminalTools.AgentPane do
  @moduledoc "terminal_agent_pane."

  use Jido.Action,
    name: "terminal_agent_pane",
    description:
      "Find the dedicated agent pane from the agent_pair template. The MCP URL can pre-scope workspace_id; `session` may be omitted when exactly one workspace session matches. When multiple sessions match, returns ambiguous: true and candidate_sessions. Mutating agent-pane shortcut tools require the agent_pair marker.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      caller_pane: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param()
        })
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_agent_pane")

  @impl Jido.Action
  def run(params, _context) do
    Agent.agent_pane(Helpers.to_impl_args(params))
  end
end
