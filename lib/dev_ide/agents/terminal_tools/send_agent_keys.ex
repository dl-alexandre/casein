defmodule DevIDE.Agents.TerminalTools.SendAgentKeys do
  @moduledoc "terminal_send_agent_keys."

  use Jido.Action,
    name: "terminal_send_agent_keys",
    description:
      "Send raw keystrokes to the dedicated agent pane only. Requires the agent_pair marker — does not fall back to agent process detection.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      caller_pane: [type: :string],
      keys: [type: :string, required: true]
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
          caller_pane: Helpers.caller_pane_param(),
          keys: Helpers.keys_param()
        }),
        ["keys"]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_agent_keys")

  @impl Jido.Action
  def run(params, _context) do
    Impl.send_agent_keys(Helpers.to_impl_args(params))
  end
end
