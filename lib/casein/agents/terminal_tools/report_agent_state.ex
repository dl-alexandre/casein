defmodule Casein.Agents.TerminalTools.ReportAgentState do
  @moduledoc "terminal_report_agent_state."

  use Jido.Action,
    name: "terminal_report_agent_state",
    description:
      "Report the agent's semantic state so Casein and orchestrating agents can react without polling. States: working, blocked (needs input/permission), done (turn complete), idle. Defaults to the dedicated agent pane. Pass an optional short message describing what is blocked or done.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      state: [type: :string, required: true],
      message: [type: :string],
      transcript_path: [type: :string],
      agent_session_id: [type: :string],
      agent_runtime: [type: :string],
      grok_leader_socket: [type: :string],
      grok_bundle_dir: [type: :string],
      grok_bundle_digest: [type: :string],
      source: [type: :string]
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
          caller_pane: Helpers.caller_pane_param(),
          pane: Helpers.pane_param(),
          state: Helpers.agent_state_param(),
          message: Helpers.agent_state_message_param(),
          transcript_path: Helpers.transcript_path_param(),
          agent_session_id: Helpers.agent_session_id_param(),
          agent_runtime: Helpers.agent_runtime_param(),
          grok_leader_socket: Helpers.grok_leader_socket_param(),
          grok_bundle_dir: Helpers.grok_bundle_dir_param(),
          grok_bundle_digest: Helpers.grok_bundle_digest_param(),
          source: Helpers.agent_state_source_param()
        }),
        ["workspace_id", "state"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_report_agent_state")

  @impl Jido.Action
  def run(params, _context) do
    Impl.report_agent_state(Helpers.to_impl_args(params))
  end
end
