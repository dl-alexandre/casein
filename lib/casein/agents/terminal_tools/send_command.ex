defmodule Casein.Agents.TerminalTools.SendCommand do
  @moduledoc "terminal_send_command."

  use Jido.Action,
    name: "terminal_send_command",
    description:
      "Type a shell command into a pane and press Enter. Target the agent pane from terminal_topology — do not use the operator's focused pane. Read the result afterward with terminal_capture.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true],
      command: [type: :string, required: true],
      pane: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          command: Helpers.command_param(),
          pane: Helpers.pane_param()
        }),
        ["session", "command"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_command")

  @impl Jido.Action
  def run(params, _context) do
    Impl.send_command(Helpers.to_impl_args(params))
  end
end
