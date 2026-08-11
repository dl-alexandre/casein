defmodule Casein.Agents.TerminalTools.WorkerStatus do
  @moduledoc "worker_status."

  use Jido.Action,
    name: "worker_status",
    description:
      "Read-only single-worker deep status (M2): one pane's agent_state, issue binding, blocked_on (report vs derived), external liveness (unknown never quiet/idle), worktree_path, fleet_role/readiness. Inverse of orchestration_status aggregate. Liveness observation is on by default. No scrollback, no shell, no mutations. worker_launch and durable task graphs remain out of scope. Requires workspace_id, session, and pane.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      pane: [type: :string, required: true],
      caller_pane: [type: :string],
      window_id: [type: :string],
      include_liveness: [type: :boolean]
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
          pane: Helpers.pane_param(),
          caller_pane: Helpers.caller_pane_param(),
          window_id: %{
            type: "string",
            description: "Optional tmux window id to disambiguate the target pane."
          },
          include_liveness: Helpers.include_liveness_param()
        }),
        ["workspace_id", "session", "pane"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("worker_status")

  @impl Jido.Action
  def run(params, _context) do
    Session.worker_status(Helpers.to_impl_args(params))
  end
end
