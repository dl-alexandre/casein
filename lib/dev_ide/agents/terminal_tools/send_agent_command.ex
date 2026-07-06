defmodule DevIDE.Agents.TerminalTools.SendAgentCommand do
  @moduledoc "terminal_send_agent_command."

  use Jido.Action,
    name: "terminal_send_agent_command",
    description:
      "Type a shell command into the dedicated agent pane and press Enter. Requires the agent_pair marker. Use terminal_send_command for explicit pane ids.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      command: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          command: Helpers.command_param()
        }),
        ["command"]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_agent_command")

  @impl Jido.Action
  def run(params, _context) do
    Impl.send_agent_command(Helpers.to_impl_args(params))
  end
end
