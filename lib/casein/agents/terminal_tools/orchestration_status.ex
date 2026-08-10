defmodule Casein.Agents.TerminalTools.OrchestrationStatus do
  @moduledoc "orchestration_status."

  use Jido.Action,
    name: "orchestration_status",
    description:
      "Read-only fleet orchestration status (M1): blocked workers + blocked_on, external liveness per row (unknown never quiet/idle), gate queue depth/holder/positions (unknown never free), optional my_position via gate_pr/gate_run_id/gate_branch/gate_pid, orphaned queue/claimed leases, bucket counts. Liveness observation is on by default. No scrollback, no shell, no mutations. worker_launch and durable task graphs remain out of scope. Requires workspace_id and session.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.1.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      caller_pane: [type: :string],
      include_liveness: [type: :boolean],
      gate_pr: [type: :integer],
      gate_run_id: [type: :string],
      gate_branch: [type: :string],
      gate_pid: [type: :integer]
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
          gate_pr: %{
            type: "integer",
            description:
              "Optional PR number to resolve gate_queue.my_position (1 = holding, 2+ = waiting)."
          },
          gate_run_id: %{
            type: "string",
            description: "Optional GitHub Actions run id for gate_queue.my_position."
          },
          gate_branch: %{
            type: "string",
            description: "Optional branch name for gate_queue.my_position."
          },
          gate_pid: %{
            type: "integer",
            description: "Optional host PID for gate_queue.my_position."
          }
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
