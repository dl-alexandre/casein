defmodule Casein.Agents.TerminalTools.OrchestrationStatus do
  @moduledoc "orchestration_status."

  use Jido.Action,
    name: "orchestration_status",
    description:
      "Read-only fleet orchestration status for a Casein session: FleetBoard bucket counts, gate queue depth/holder (unknown never free), orphaned queue/claimed leases, and one row per agent window (pane_id, issue, agent_state, needs_you?, fleet_role). No scrollback, no shell, no mutations. M0 discovery only — worker_launch and durable task graphs are out of scope. Requires workspace_id and session.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      caller_pane: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Session}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param()
        }),
        ["workspace_id", "session"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("orchestration_status")

  @impl Jido.Action
  def run(params, _context) do
    Session.orchestration_status(Helpers.to_impl_args(params))
  end
end
