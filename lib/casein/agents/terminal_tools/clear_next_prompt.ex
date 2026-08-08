defmodule Casein.Agents.TerminalTools.ClearNextPrompt do
  @moduledoc "terminal_clear_next_prompt."

  use Jido.Action,
    name: "terminal_clear_next_prompt",
    description:
      "Retract the sticky operator message waiting for an agent pane. Pass coalesce_key to clear only when the pending message is still the one you staged, so you do not discard a different orchestrator's message.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      coalesce_key: [type: :string]
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
          pane: Helpers.pane_param(),
          coalesce_key: Helpers.coalesce_key_param()
        }),
        ["workspace_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_clear_next_prompt")

  @impl Jido.Action
  def run(params, _context) do
    Agent.clear_next_prompt(Helpers.to_impl_args(params))
  end
end
