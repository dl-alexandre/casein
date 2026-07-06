defmodule DevIDE.Agents.TerminalTools.ReportAgentState do
  @moduledoc "terminal_report_agent_state."

  use Jido.Action,
    name: "terminal_report_agent_state",
    description:
      "Report the agent's semantic state so DevIDE and orchestrating agents can react without polling. States: working, blocked (needs input/permission), done (turn complete), idle. Defaults to the dedicated agent pane. Pass an optional short message describing what is blocked or done.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      pane: [type: :string],
      state: [type: :string, required: true],
      message: [type: :string],
      transcript_path: [type: :string],
      source: [type: :string]
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
          state: Helpers.agent_state_param(),
          message: Helpers.agent_state_message_param(),
          transcript_path: Helpers.transcript_path_param(),
          source: Helpers.agent_state_source_param()
        }),
        ["workspace_id", "state"]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_report_agent_state")

  @impl Jido.Action
  def run(params, _context) do
    Impl.report_agent_state(Helpers.to_impl_args(params))
  end
end
