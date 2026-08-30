defmodule Casein.Agents.TerminalTools.OrchestrationListWorkers do
  @moduledoc "orchestration_list_workers."

  use Jido.Action,
    name: "orchestration_list_workers",
    description:
      "Read-only compact fleet worker list (M3): rows of pane_id, window, issue, agent_state, blocked_on kind, fleet_role, needs_you? from FleetBoard projection (reuses OrchestrationStatus.tabs_from_topology — no second classifier). Optional fleet_role filter and needs_you_only. Liveness unknown never idle. Default reads the cached fleet snapshot (liveness_source=snapshot); include_liveness=true walks liveness now, the same evidence worker_status uses. Every row carries agent_state_resolution (report | derived | expired_report | unreported) plus agent_state_last_reported / agent_state_reported_at / agent_state_age_s, so an absent agent_state is explained rather than silent. No scrollback, no shell, no mutations. worker_launch and durable task graphs remain out of scope. Requires workspace_id and session.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      caller_pane: [type: :string],
      include_liveness: [type: :boolean],
      fleet_role: [type: :string],
      needs_you_only: [type: :boolean]
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
          caller_pane: Helpers.caller_pane_param(),
          include_liveness: Helpers.include_liveness_param(),
          fleet_role: %{
            type: "string",
            description: "Optional fleet role filter: \"manager\" or \"worker\".",
            enum: ["manager", "worker"]
          },
          needs_you_only: %{
            type: "boolean",
            description: "When true, return only rows with needs_you? true."
          }
        }),
        ["workspace_id", "session"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("orchestration_list_workers")

  @impl Jido.Action
  def run(params, _context) do
    Session.orchestration_list_workers(Helpers.to_impl_args(params))
  end
end
