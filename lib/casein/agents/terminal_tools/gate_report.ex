defmodule Casein.Agents.TerminalTools.GateReport do
  @moduledoc "gate_report."

  use Jido.Action,
    name: "gate_report",
    description:
      "Record a pre-push gate run verdict as a durable audit row (gate.passed / gate.failed). Called fail-open by scripts/pre-push-check.sh at the end of each run, so gate history survives in the workspace timeline; a missing report never blocks a push. Requires workspace_id and passed; optional branch, sha, duration_s, and failed_step (the gate step that failed).",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      passed: [type: :boolean, required: true],
      branch: [type: :string],
      sha: [type: :string],
      duration_s: [type: {:or, [:integer, :float]}],
      failed_step: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Report}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          passed: Helpers.gate_passed_param(),
          branch: Helpers.branch_param(),
          sha: Helpers.sha_param(),
          duration_s: Helpers.gate_duration_param(),
          failed_step: Helpers.gate_failed_step_param()
        }),
        ["workspace_id", "passed"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("gate_report")

  @impl Jido.Action
  def run(params, _context) do
    Report.gate_report(Helpers.to_impl_args(params))
  end
end
