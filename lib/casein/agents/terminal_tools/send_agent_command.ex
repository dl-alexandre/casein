defmodule Casein.Agents.TerminalTools.SendAgentCommand do
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
      caller_pane: [type: :string],
      command: [type: :string, required: true],
      confirm: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param(),
          command: Helpers.command_param(),
          confirm: Helpers.confirm_param()
        }),
        ["command"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_agent_command")

  @impl Jido.Action
  def run(params, _context) do
    Agent.send_agent_command(Helpers.to_impl_args(params))
  end
end
