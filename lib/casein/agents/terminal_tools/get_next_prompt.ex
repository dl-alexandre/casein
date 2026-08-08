defmodule Casein.Agents.TerminalTools.GetNextPrompt do
  @moduledoc "terminal_get_next_prompt."

  use Jido.Action,
    name: "terminal_get_next_prompt",
    description:
      "Read the sticky operator message waiting for an agent pane, if any. terminal_topology also flags panes with pending_next_prompt, so prefer this only when you need the message text or its delivery conditions.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string]
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
          pane: Helpers.pane_param()
        }),
        ["workspace_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_get_next_prompt")

  @impl Jido.Action
  def run(params, _context) do
    Agent.get_next_prompt(Helpers.to_impl_args(params))
  end
end
