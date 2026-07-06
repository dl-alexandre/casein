defmodule DevIDE.Agents.TerminalTools.WaitAgentState do
  @moduledoc "terminal_wait_agent_state."

  use Jido.Action,
    name: "terminal_wait_agent_state",
    description:
      "Block until the agent pane reaches one of the given semantic states, or until timeout_ms elapses (max 55000). Returns immediately if already in a target state. A timeout is not an error — re-issue the call to keep long-polling. Defaults to the dedicated agent pane.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      pane: [type: :string],
      states: [type: {:list, :string}, required: true],
      timeout_ms: [type: :integer],
      include_answer: [type: :boolean]
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
          pane: Helpers.pane_param(),
          states: Helpers.wait_states_param(),
          timeout_ms: Helpers.timeout_ms_param(),
          include_answer: Helpers.include_answer_param()
        }),
        ["workspace_id", "states"]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_wait_agent_state")

  @impl Jido.Action
  def run(params, _context) do
    Impl.wait_agent_state(Helpers.to_impl_args(params))
  end
end
